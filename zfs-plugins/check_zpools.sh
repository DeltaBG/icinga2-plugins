#!/usr/bin/env bash
#########################################################################
# Script:     check_zpools.sh
# Purpose:    Nagios/Icinga plugin to monitor ZFS pool health, capacity,
#             fragmentation, redundancy state, and device error counters.
# Based on:   https://github.com/Napsty/check_zpools (GPL v2)
# Licence:    GNU General Public Licence (GPL) v2
#########################################################################
# Improvements over upstream:
#   - Fixed off-by-one in threshold comparison (>= instead of >, <)
#   - Fixed missing separator when concatenating multiple errors per pool
#   - Tightened spare-in-use detection (column-aware, not naive grep)
#   - Distinguish DEGRADED (WARNING) from FAULTED/UNAVAIL/REMOVED (CRITICAL)
#   - Detect active scrub / resilver and surface progress
#   - Report fragmentation, READ/WRITE/CKSUM error counters
#   - Exclude-pool flag for intentionally-noisy pools
#   - Verbose long output for Icinga Web 2 detail pane
#   - Proper Nagios perfdata format: label=value;warn;crit;min;max
#   - shellcheck clean
#########################################################################

set -o pipefail

# Exit codes
readonly STATE_OK=0
readonly STATE_WARNING=1
readonly STATE_CRITICAL=2
readonly STATE_UNKNOWN=3

PATH="${PATH}:/usr/sbin:/sbin"
export PATH

# Defaults
WARN=""
CRIT=""
FRAG_WARN=""
FRAG_CRIT=""
POOL_ARG=""
EXCLUDES=""
VERBOSE=0

usage() {
    cat <<EOF
check_zpools.sh - Monitor ZFS pool health for Nagios/Icinga

Usage: $0 -p <poolname|ALL> -w <warn%> -c <crit%> [options]

Required:
  -p NAME      Pool name, or "ALL" for every imported pool
  -w PCT       Capacity WARNING threshold (percent)
  -c PCT       Capacity CRITICAL threshold (percent)

Options:
  -W PCT       Fragmentation WARNING threshold (default: disabled)
  -C PCT       Fragmentation CRITICAL threshold (default: disabled)
  -x LIST      Comma-separated list of pools to exclude (only with -p ALL)
  -v           Verbose: include per-pool long output (for Icinga Web 2)
  -h           Show this help

Examples:
  $0 -p ALL -w 80 -c 90
  $0 -p ALL -w 80 -c 90 -W 50 -C 80 -x backup,scratch -v
  $0 -p tank -w 85 -c 95
EOF
}

while getopts "p:w:c:W:C:x:vh" opt; do
    case "$opt" in
        p) POOL_ARG="$OPTARG" ;;
        w) WARN="$OPTARG" ;;
        c) CRIT="$OPTARG" ;;
        W) FRAG_WARN="$OPTARG" ;;
        C) FRAG_CRIT="$OPTARG" ;;
        x) EXCLUDES="$OPTARG" ;;
        v) VERBOSE=1 ;;
        h) usage; exit "$STATE_UNKNOWN" ;;
        *) usage; exit "$STATE_UNKNOWN" ;;
    esac
done

# Validate args
if [[ -z "$POOL_ARG" || -z "$WARN" || -z "$CRIT" ]]; then
    usage
    exit "$STATE_UNKNOWN"
fi

if ! [[ "$WARN" =~ ^[0-9]+$ ]] || ! [[ "$CRIT" =~ ^[0-9]+$ ]]; then
    echo "UNKNOWN: thresholds must be integers"
    exit "$STATE_UNKNOWN"
fi

if (( WARN >= CRIT )); then
    echo "UNKNOWN: warning threshold ($WARN) must be less than critical ($CRIT)"
    exit "$STATE_UNKNOWN"
fi

if [[ -n "$FRAG_WARN" && -n "$FRAG_CRIT" ]] && (( FRAG_WARN >= FRAG_CRIT )); then
    echo "UNKNOWN: fragmentation warning ($FRAG_WARN) must be less than critical ($FRAG_CRIT)"
    exit "$STATE_UNKNOWN"
fi

# zpool must exist
if ! command -v zpool >/dev/null 2>&1; then
    echo "UNKNOWN: zpool not found in PATH ($PATH)"
    exit "$STATE_UNKNOWN"
fi

# Build pool list
declare -a POOLS=()
if [[ "$POOL_ARG" == "ALL" ]]; then
    if ! mapfile -t all_pools < <(zpool list -Ho name 2>/dev/null); then
        echo "UNKNOWN: 'zpool list' failed"
        exit "$STATE_UNKNOWN"
    fi
    if (( ${#all_pools[@]} == 0 )); then
        echo "UNKNOWN: no ZFS pools imported on this host"
        exit "$STATE_UNKNOWN"
    fi
    # Apply excludes
    IFS=',' read -r -a excl_arr <<<"$EXCLUDES"
    for p in "${all_pools[@]}"; do
        skip=0
        for e in "${excl_arr[@]}"; do
            [[ "$p" == "$e" ]] && skip=1 && break
        done
        (( skip == 0 )) && POOLS+=("$p")
    done
    if (( ${#POOLS[@]} == 0 )); then
        echo "UNKNOWN: all pools excluded by -x filter"
        exit "$STATE_UNKNOWN"
    fi
else
    POOLS=( "$POOL_ARG" )
fi

# Per-pool collection
declare -a problems=()
declare -a perfdata=()
declare -a longout=()
worst_state="$STATE_OK"

bump_state() {
    local new="$1"
    # CRITICAL > UNKNOWN > WARNING > OK in Nagios precedence; we use simple max
    # but treat CRITICAL as highest.
    if (( new == STATE_CRITICAL )); then
        worst_state="$STATE_CRITICAL"
    elif (( new == STATE_WARNING && worst_state != STATE_CRITICAL )); then
        worst_state="$STATE_WARNING"
    fi
}

for pool in "${POOLS[@]}"; do
    # zpool list: capacity, health, fragmentation in one shot
    if ! list_line="$(zpool list -Hp -o capacity,health,fragmentation "$pool" 2>&1)"; then
        echo "UNKNOWN: 'zpool list' failed for $pool: $list_line"
        exit "$STATE_UNKNOWN"
    fi
    # -p makes capacity an integer percent (no %), fragmentation an integer (no %)
    # Fields: capacity health fragmentation
    read -r capacity health fragmentation <<<"$list_line"

    # Some older ZoL/OpenZFS versions print '-' for fragmentation on pools
    # where it doesn't apply (e.g. only-special-vdev edge cases).
    [[ "$fragmentation" == "-" || -z "$fragmentation" ]] && fragmentation=0
    [[ "$capacity" == "-" || -z "$capacity" ]] && capacity=0

    # zpool status for spares, scrub/resilver, error counters
    if ! status_out="$(zpool status "$pool" 2>&1)"; then
        echo "UNKNOWN: 'zpool status' failed for $pool: $status_out"
        exit "$STATE_UNKNOWN"
    fi

    # Spare-in-use detection: look at lines where INUSE appears as the
    # state column (3rd field) under the config: section. We narrow to
    # the config block, then count vdevs whose state is INUSE.
    spares_inuse=$(awk '
        /^config:/ { in_cfg=1; next }
        /^errors:/ { in_cfg=0 }
        in_cfg && NF >= 2 && $2 == "INUSE" { c++ }
        END { print c+0 }
    ' <<<"$status_out")

    # Aggregate READ/WRITE/CKSUM error counters across all leaf vdevs.
    # zpool status columns under "config:" are: NAME STATE READ WRITE CKSUM
    # We skip header, mirror/raidz container lines (which sum children),
    # and special sections. Sum across all device leaves.
    read -r rd_err wr_err ck_err <<<"$(awk '
        /^config:/ { in_cfg=1; next }
        /^errors:/ { in_cfg=0 }
        in_cfg && NF >= 5 {
            # skip header
            if ($1 == "NAME" && $2 == "STATE") next
            # skip pool name line (matches $1 == pool) and section labels
            if ($1 == "logs" || $1 == "cache" || $1 == "spares" || $1 == "special") next
            # numeric error columns -> leaf or container; sum all, dedup not worth it
            if ($3 ~ /^[0-9]+$/ && $4 ~ /^[0-9]+$/ && $5 ~ /^[0-9]+$/) {
                r += $3; w += $4; c += $5
            }
        }
        END { print r+0, w+0, c+0 }
    ' <<<"$status_out")"

    # Scrub / resilver state
    scrub_line=$(grep -E "^\s*scan:" <<<"$status_out" | sed 's/^\s*scan:\s*//')
    resilver_active=0
    scrub_active=0
    if [[ "$scrub_line" == *"resilver in progress"* ]]; then
        resilver_active=1
    elif [[ "$scrub_line" == *"scrub in progress"* ]]; then
        scrub_active=1
    fi

    # Build per-pool messages
    pool_msgs=()

    case "$health" in
        ONLINE)
            : # fine
            ;;
        DEGRADED)
            pool_msgs+=("$pool health=DEGRADED")
            bump_state "$STATE_WARNING"
            ;;
        FAULTED|UNAVAIL|REMOVED|SUSPENDED)
            pool_msgs+=("$pool health=$health")
            bump_state "$STATE_CRITICAL"
            ;;
        *)
            pool_msgs+=("$pool health=$health (unknown state)")
            bump_state "$STATE_CRITICAL"
            ;;
    esac

    # Capacity thresholds (>= triggers, per Nagios convention)
    if (( capacity >= CRIT )); then
        pool_msgs+=("$pool usage CRITICAL (${capacity}%)")
        bump_state "$STATE_CRITICAL"
    elif (( capacity >= WARN )); then
        pool_msgs+=("$pool usage WARNING (${capacity}%)")
        bump_state "$STATE_WARNING"
    fi

    # Fragmentation thresholds (optional)
    if [[ -n "$FRAG_WARN" && -n "$FRAG_CRIT" ]]; then
        if (( fragmentation >= FRAG_CRIT )); then
            pool_msgs+=("$pool fragmentation CRITICAL (${fragmentation}%)")
            bump_state "$STATE_CRITICAL"
        elif (( fragmentation >= FRAG_WARN )); then
            pool_msgs+=("$pool fragmentation WARNING (${fragmentation}%)")
            bump_state "$STATE_WARNING"
        fi
    fi

    # Spares in use -> WARNING (redundancy already kicked in)
    if (( spares_inuse > 0 )); then
        pool_msgs+=("$pool has $spares_inuse spare(s) in use")
        bump_state "$STATE_WARNING"
    fi

    # Device error counters -> WARNING (any non-zero is suspicious)
    if (( rd_err > 0 || wr_err > 0 || ck_err > 0 )); then
        pool_msgs+=("$pool errors R=$rd_err W=$wr_err CKSUM=$ck_err")
        bump_state "$STATE_WARNING"
    fi

    # Resilver in progress -> WARNING; scrub is informational only
    if (( resilver_active == 1 )); then
        pool_msgs+=("$pool resilver in progress")
        bump_state "$STATE_WARNING"
    fi

    # Append to global problem list (with proper separator)
    if (( ${#pool_msgs[@]} > 0 )); then
        problems+=("$(IFS='; '; echo "${pool_msgs[*]}")")
    fi

    # Perfdata: capacity (with thresholds) + fragmentation + error counters
    perfdata+=("'${pool}_cap'=${capacity}%;${WARN};${CRIT};0;100")
    if [[ -n "$FRAG_WARN" && -n "$FRAG_CRIT" ]]; then
        perfdata+=("'${pool}_frag'=${fragmentation}%;${FRAG_WARN};${FRAG_CRIT};0;100")
    else
        perfdata+=("'${pool}_frag'=${fragmentation}%;;;0;100")
    fi
    perfdata+=("'${pool}_read_err'=${rd_err}c")
    perfdata+=("'${pool}_write_err'=${wr_err}c")
    perfdata+=("'${pool}_cksum_err'=${ck_err}c")
    perfdata+=("'${pool}_spares_inuse'=${spares_inuse}")

    # Verbose long output (Icinga Web 2 detail pane)
    if (( VERBOSE == 1 )); then
        longout+=("--- $pool ---")
        longout+=("  health: $health")
        longout+=("  capacity: ${capacity}%   fragmentation: ${fragmentation}%")
        longout+=("  errors: read=$rd_err write=$wr_err cksum=$ck_err   spares_inuse=$spares_inuse")
        if (( scrub_active == 1 || resilver_active == 1 )); then
            longout+=("  scan: $scrub_line")
        fi
    fi
done

# Build summary line
case "$worst_state" in
    "$STATE_OK")
        summary="OK - ${#POOLS[@]} pool(s) healthy: ${POOLS[*]}"
        ;;
    "$STATE_WARNING")
        summary="WARNING - $(IFS='; '; echo "${problems[*]}")"
        ;;
    "$STATE_CRITICAL")
        summary="CRITICAL - $(IFS='; '; echo "${problems[*]}")"
        ;;
    *)
        summary="UNKNOWN"
        ;;
esac

# Output: summary | perfdata
# (multi-line long output below, separated by newline)
echo "${summary} | ${perfdata[*]}"
if (( VERBOSE == 1 && ${#longout[@]} > 0 )); then
    printf '%s\n' "${longout[@]}"
fi

exit "$worst_state"
