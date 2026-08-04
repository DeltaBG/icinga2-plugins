#!/usr/bin/env bash
#
# check_ceph_pool_quota -- Icinga2 / Nagios plugin
#
# Reports how much of a Ceph pool's configured quota (max_bytes / max_objects)
# is currently consumed, and returns WARNING / CRITICAL once the given
# percentage thresholds are crossed.
#
# Requires: ceph CLI, jq, coreutils (numfmt), awk
# Privileges: a cephx user with 'mon allow r' and 'mgr allow r' is sufficient.
#
# Exit codes: 0 OK, 1 WARNING, 2 CRITICAL, 3 UNKNOWN
#
# Perfdata:
#   stored            logical bytes stored (pre-replication) -- the value the
#                     byte quota is enforced against; warn/crit/max are the
#                     absolute byte thresholds and the quota itself
#   quota_max_bytes   the configured byte quota, as its own series
#   quota_bytes_pct   stored as % of the byte quota
#   objects           object count; warn/crit/max as above
#   quota_max_objects the configured object quota
#   quota_objects_pct objects as % of the object quota
#   pool_max_avail    free space still available to the pool
#

OK=0; WARNING=1; CRITICAL=2; UNKNOWN=3

POOL=""; WARN=75; CRIT=85
CLUSTER=""; CONF=""; ID=""; KEYRING=""

usage() {
  cat <<EOF
Usage: $(basename "$0") -p|--pool POOL [options]

  -p, --pool POOL          pool name (required)
  -w, --warning PCT        WARNING threshold, % of quota (default: 75)
  -c, --critical PCT       CRITICAL threshold, % of quota (default: 85)
  -l, --cluster NAME       cluster name; ceph resolves
                           /etc/ceph/<NAME>.conf and
                           /etc/ceph/<NAME>.<client>.keyring from it
  -C, --conf PATH          explicit ceph.conf (overrides --cluster)
  -n, --name, --id NAME    cephx user, e.g. client.monitoring
  -k, --keyring PATH       explicit keyring (overrides --cluster)
  -h, --help               show this help

Examples:
  $(basename "$0") -p rbd-tenant-a -w 75 -c 85
  $(basename "$0") --cluster cluster-a --pool rbd-tenant-a --name client.monitoring
  $(basename "$0") --cluster=cluster-b --pool=rbd-tenant-b -w 80 -c 90
EOF
  exit $UNKNOWN
}

# --- normalise "--opt=value" into "--opt value" ----------------------
ARGV=()
for a in "$@"; do
  case "$a" in
    --*=*) ARGV+=("${a%%=*}" "${a#*=}") ;;
    *)     ARGV+=("$a") ;;
  esac
done
set -- "${ARGV[@]}"

need_val() {
  [ "$2" -lt 2 ] && { echo "UNKNOWN - missing value for $1"; exit $UNKNOWN; }
}

while [ $# -gt 0 ]; do
  case "$1" in
    -p|--pool)      need_val "$1" $#; POOL="$2";    shift 2 ;;
    -w|--warning)   need_val "$1" $#; WARN="$2";    shift 2 ;;
    -c|--critical)  need_val "$1" $#; CRIT="$2";    shift 2 ;;
    -l|--cluster)   need_val "$1" $#; CLUSTER="$2"; shift 2 ;;
    -C|--conf)      need_val "$1" $#; CONF="$2";    shift 2 ;;
    -n|--name|--id) need_val "$1" $#; ID="$2";      shift 2 ;;
    -k|--keyring)   need_val "$1" $#; KEYRING="$2"; shift 2 ;;
    -h|--help)      usage ;;
    *) echo "UNKNOWN - unknown argument: $1"; exit $UNKNOWN ;;
  esac
done

[ -z "$POOL" ] && usage
command -v jq >/dev/null 2>&1 || { echo "UNKNOWN - jq is required but not installed"; exit $UNKNOWN; }

# --cluster goes first so that an explicit --conf / --keyring wins over
# whatever the cluster name would have resolved to.
ARGS=()
[ -n "$CLUSTER" ] && ARGS+=(--cluster "$CLUSTER")
[ -n "$CONF" ]    && ARGS+=(--conf    "$CONF")
[ -n "$ID" ]      && ARGS+=(--name    "$ID")
[ -n "$KEYRING" ] && ARGS+=(--keyring "$KEYRING")

SCOPE="pool '${POOL}'"
[ -n "$CLUSTER" ] && SCOPE="[${CLUSTER}] pool '${POOL}'"

# --- collect data ---------------------------------------------------
DF=$(ceph "${ARGS[@]}" df detail -f json 2>/dev/null)
[ -z "$DF" ] && { echo "UNKNOWN - 'ceph df' returned no data for ${SCOPE} (permissions / ceph.conf / cluster name?)"; exit $UNKNOWN; }

QJ=$(ceph "${ARGS[@]}" osd pool get-quota "$POOL" -f json 2>/dev/null)
[ -z "$QJ" ] && { echo "UNKNOWN - ${SCOPE} not found"; exit $UNKNOWN; }

STATS=$(jq -r --arg p "$POOL" \
  '.pools[] | select(.name==$p) | "\(.stats.stored // 0) \(.stats.objects // 0) \(.stats.max_avail // 0)"' <<<"$DF")
[ -z "$STATS" ] && { echo "UNKNOWN - no stats available for ${SCOPE}"; exit $UNKNOWN; }

read -r STORED OBJECTS MAXAVAIL <<<"$STATS"
read -r QBYTES QOBJ <<<"$(jq -r '"\(.quota_max_bytes // 0) \(.quota_max_objects // 0)"' <<<"$QJ")"

if [ "$QBYTES" -le 0 ] && [ "$QOBJ" -le 0 ]; then
  echo "UNKNOWN - no quota configured for ${SCOPE} (max_bytes=0, max_objects=0) | 'stored'=${STORED}B 'objects'=${OBJECTS} 'pool_max_avail'=${MAXAVAIL}B"
  exit $UNKNOWN
fi

# --- helpers --------------------------------------------------------
# Note: quota is enforced against logical stored bytes (pre-replication),
# not raw usage, so 'stored' is the correct field to compare here.
hr()   { numfmt --to=iec-i --suffix=B --format='%.1f' --round=nearest "${1:-0}" 2>/dev/null || echo "${1}B"; }
hrn()  { numfmt --to=si --format='%.1f' --round=nearest "${1:-0}" 2>/dev/null || echo "${1}"; }
pct()  { awk -v u="$1" -v m="$2" 'BEGIN{printf "%.1f", (m>0 ? u*100/m : 0)}'; }
thr()  { awk -v m="$1" -v p="$2" 'BEGIN{printf "%d", m*p/100}'; }
eval_state() { awk -v p="$1" -v w="$WARN" -v c="$CRIT" 'BEGIN{print (p>=c ? 2 : (p>=w ? 1 : 0))}'; }

STATE=$OK; TXT=""; PERF=""
HAVE_BYTES=0; HAVE_OBJ=0

# --- byte quota -----------------------------------------------------
if [ "$QBYTES" -gt 0 ]; then
  HAVE_BYTES=1
  PB=$(pct "$STORED" "$QBYTES")
  WB=$(thr "$QBYTES" "$WARN"); CB=$(thr "$QBYTES" "$CRIT")
  S=$(eval_state "$PB"); [ "$S" -gt "$STATE" ] && STATE=$S
  TXT="${TXT}bytes ${PB}% used ($(hr "$STORED") of $(hr "$QBYTES") quota) "
  PERF="${PERF}'stored'=${STORED}B;${WB};${CB};0;${QBYTES} "
  PERF="${PERF}'quota_max_bytes'=${QBYTES}B "
  PERF="${PERF}'quota_bytes_pct'=${PB}%;${WARN};${CRIT};0;100 "
fi

# --- object quota ---------------------------------------------------
if [ "$QOBJ" -gt 0 ]; then
  HAVE_OBJ=1
  PO=$(pct "$OBJECTS" "$QOBJ")
  WO=$(thr "$QOBJ" "$WARN"); CO=$(thr "$QOBJ" "$CRIT")
  S=$(eval_state "$PO"); [ "$S" -gt "$STATE" ] && STATE=$S
  TXT="${TXT}objects ${PO}% used ($(hrn "$OBJECTS") of $(hrn "$QOBJ") quota) "
  PERF="${PERF}'objects'=${OBJECTS};${WO};${CO};0;${QOBJ} "
  PERF="${PERF}'quota_max_objects'=${QOBJ} "
  PERF="${PERF}'quota_objects_pct'=${PO}%;${WARN};${CRIT};0;100 "
fi

# emit the raw counters unconditionally, so each series stays continuous
# even when only one of the two quotas is configured
[ "$HAVE_BYTES" -eq 0 ] && PERF="${PERF}'stored'=${STORED}B "
[ "$HAVE_OBJ"   -eq 0 ] && PERF="${PERF}'objects'=${OBJECTS} "
PERF="${PERF}'pool_max_avail'=${MAXAVAIL}B"

case $STATE in
  0) L="OK" ;;
  1) L="WARNING" ;;
  2) L="CRITICAL" ;;
  *) L="UNKNOWN" ;;
esac

echo "${L} - ${SCOPE}: ${TXT}| ${PERF}"
exit $STATE
