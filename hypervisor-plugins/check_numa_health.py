#!/usr/bin/env python3
"""check_numa_health - Nagios/Icinga2 plugin for per-NUMA-node memory health.

Aggregate memory checks are blind to NUMA imbalance: a host can report
45% free memory while a single node sits at 0.2% and its kswapd burns a
core in a busy loop. This plugin looks at the signals that actually
matter on a NUMA hypervisor.

Checks performed
----------------
1. Watermark health (primary)
   Compares each node's free pages against the kernel's own min/low/high
   watermarks from /proc/zoneinfo, rather than against an arbitrary
   percentage. A node holding 0.5% free is perfectly healthy when free is
   above the high watermark - that is the kernel's steady state, not
   starvation. Free below min means allocations are entering direct
   reclaim, which is what actually stalls guests.

2. Watermark boost detection
   vm.watermark_boost_factor inflates min/low/high on nodes that hit
   fragmentation events. On fallback nodes this can set an unreachable
   target, leaving kswapd spinning without reclaiming anything. Detected
   by comparing each node's min against the median across nodes.

3. kswapd CPU time
   One kswapd thread pinned at 100% is 0.78% of a 128-CPU host and will
   never trip a CPU alert. Measured per node as a delta between runs.

4. Reclaim efficiency
   pgsteal_kswapd / pgscan_kswapd. A low ratio under heavy scanning means
   kswapd is looping without freeing anything. With no swap configured
   and mostly anonymous guest memory, scanning can be zero while CPU
   still burns - both conditions are reported.

5. Compaction failure ratio
   compact_fail / compact_stall, gated by a minimum event rate so that a
   handful of failures over a long window does not raise an alert.

6. Memory pressure stall information
   /proc/pressure/memory avg10. On a hypervisor, sustained full pressure
   above ~1% is already visible to tenants as latency.

7. NUMA imbalance
   A node below its low watermark while the host as a whole has ample
   free memory. This is the defining signature of a NUMA problem as
   opposed to genuine memory exhaustion, and it is invisible to every
   aggregate check.

Nodes without local memory (MemTotal == 0) are skipped automatically.
On AMD EPYC with NPS4 plus L3-as-NUMA-domain, half the nodes are
CPU-only and would otherwise alert permanently.

Requires a state file to compute deltas. The first run initialises it
and exits OK. State older than --max-state-age is treated as unusable
rather than producing misleading rates across a stale window.

Usage
-----
    check_numa_health
    check_numa_health --watermark-crit min --watermark-warn low
    check_numa_health --kswapd-warn 20 --kswapd-crit 50
    check_numa_health --free-warn 0.3 --free-crit 0.15
    check_numa_health --state /var/lib/icinga2/numa/state.json

Exit codes: 0 OK, 1 WARNING, 2 CRITICAL, 3 UNKNOWN.
"""

import argparse
import glob
import json
import os
import re
import statistics
import sys
import time

__version__ = "2.0"

OK, WARNING, CRITICAL, UNKNOWN = 0, 1, 2, 3
STATUS = {OK: "OK", WARNING: "WARNING", CRITICAL: "CRITICAL", UNKNOWN: "UNKNOWN"}

HZ = os.sysconf("SC_CLK_TCK")
PAGE_KB = os.sysconf("SC_PAGE_SIZE") // 1024
DEFAULT_STATE = "/var/tmp/check_numa_health.state"

VMSTAT_KEYS = (
    "pgscan_kswapd",
    "pgsteal_kswapd",
    "pgscan_direct",
    "pgsteal_direct",
    "compact_stall",
    "compact_fail",
    "allocstall_dma",
    "allocstall_dma32",
    "allocstall_normal",
    "allocstall_movable",
)

ZONE_FIELD_RE = re.compile(r"^\s+(min|low|high|boost)\s+(\d+)\s*$")
ZONE_FREE_RE = re.compile(r"^\s+pages free\s+(\d+)\s*$")
ZONE_HEADER_RE = re.compile(r"^Node (\d+), zone\s+(\S+)")


# --------------------------------------------------------------------------
# Collection
# --------------------------------------------------------------------------

def read_node_meminfo():
    """Return {node_id: {key: kB}} for every NUMA node that has local memory."""
    nodes = {}
    for path in sorted(glob.glob("/sys/devices/system/node/node[0-9]*")):
        node_id = os.path.basename(path)[4:]
        values = {}
        try:
            with open(os.path.join(path, "meminfo")) as handle:
                for line in handle:
                    # Format: "Node 8 MemFree:    97400 kB"
                    fields = line.split()
                    if len(fields) < 4:
                        continue
                    values[fields[2].rstrip(":")] = int(fields[3])
        except (OSError, ValueError):
            continue
        if values.get("MemTotal", 0) > 0:
            nodes[node_id] = values
    return nodes


def read_zone_watermarks():
    """Return ({node_id: {'free','min','low','high','boost'}}, boost_reported).

    Watermarks are summed across all zones of a node. Node 0 typically
    carries DMA and DMA32 zones in addition to Normal, so a Normal-only
    reading would understate its totals.

    Older kernels do not print the boost line in /proc/zoneinfo. The
    second return value says whether it was seen; when absent, boosting is
    inferred from the min-versus-median comparison instead.
    """
    nodes = {}
    node_id = None
    saw_boost = False
    try:
        with open("/proc/zoneinfo") as handle:
            for line in handle:
                header = ZONE_HEADER_RE.match(line)
                if header:
                    node_id = header.group(1)
                    nodes.setdefault(
                        node_id,
                        {"free": 0, "min": 0, "low": 0, "high": 0, "boost": 0},
                    )
                    continue
                if node_id is None:
                    continue
                free = ZONE_FREE_RE.match(line)
                if free:
                    nodes[node_id]["free"] += int(free.group(1))
                    continue
                field = ZONE_FIELD_RE.match(line)
                if field:
                    name, value = field.group(1), int(field.group(2))
                    nodes[node_id][name] += value
                    if name == "boost":
                        saw_boost = True
    except (OSError, ValueError):
        return {}, False
    return nodes, saw_boost


def read_kswapd_cpu():
    """Return {node_id: cumulative CPU ticks} for each kswapdN kernel thread."""
    threads = {}
    for proc in glob.glob("/proc/[0-9]*"):
        try:
            with open(os.path.join(proc, "comm")) as handle:
                comm = handle.read().strip()
            if not comm.startswith("kswapd"):
                continue
            node_id = comm[6:]
            if not node_id.isdigit():
                continue
            with open(os.path.join(proc, "stat")) as handle:
                raw = handle.read()
            # comm may contain parentheses, so split after the final ") "
            fields = raw.rsplit(") ", 1)[1].split()
            # After comm: state=0 ppid=1 ... utime=11 stime=12
            threads[node_id] = int(fields[11]) + int(fields[12])
        except (OSError, ValueError, IndexError):
            continue
    return threads


def read_vmstat():
    values = {}
    try:
        with open("/proc/vmstat") as handle:
            for line in handle:
                key, _, value = line.partition(" ")
                if key in VMSTAT_KEYS:
                    values[key] = int(value)
    except (OSError, ValueError):
        pass
    return values


def read_psi_memory():
    """Return (some_avg10, full_avg10) as percentages, or (None, None)."""
    some = full = None
    try:
        with open("/proc/pressure/memory") as handle:
            for line in handle:
                pairs = dict(
                    item.split("=", 1) for item in line.split()[1:] if "=" in item
                )
                if line.startswith("some"):
                    some = float(pairs.get("avg10", 0))
                elif line.startswith("full"):
                    full = float(pairs.get("avg10", 0))
    except (OSError, ValueError):
        pass
    return some, full


def read_sysctl(name):
    path = "/proc/sys/" + name.replace(".", "/")
    try:
        with open(path) as handle:
            return int(handle.read().split()[0])
    except (OSError, ValueError, IndexError):
        return None


# --------------------------------------------------------------------------
# State
# --------------------------------------------------------------------------

def load_state(path):
    try:
        with open(path) as handle:
            data = json.load(handle)
        if not isinstance(data, dict) or "ts" not in data:
            return None
        return data
    except (OSError, ValueError):
        return None


def save_state(path, data):
    tmp = path + ".tmp"
    directory = os.path.dirname(path)
    try:
        if directory:
            os.makedirs(directory, exist_ok=True)
        with open(tmp, "w") as handle:
            json.dump(data, handle)
        os.replace(tmp, path)
    except OSError as exc:
        print(f"NUMA UNKNOWN - cannot write state file {path}: {exc}")
        sys.exit(UNKNOWN)


# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------

def parse_args():
    parser = argparse.ArgumentParser(
        description="Per-NUMA-node memory health check",
    )
    parser.add_argument(
        "--watermark-crit", choices=("min", "low", "high", "off"), default="min",
        help="CRITICAL when a node's free pages fall below this watermark "
             "(default: min, i.e. allocations are entering direct reclaim)",
    )
    parser.add_argument(
        "--watermark-warn", choices=("min", "low", "high", "off"), default="low",
        help="WARNING when a node's free pages fall below this watermark "
             "(default: low, i.e. kswapd is being woken)",
    )
    parser.add_argument(
        "--free-warn", type=float, default=0.0,
        help="WARNING below this percent free per node. Off by default: "
             "watermarks are the meaningful threshold, and a healthy "
             "fallback node legitimately sits near zero percent",
    )
    parser.add_argument(
        "--free-crit", type=float, default=0.0,
        help="CRITICAL below this percent free per node (0 disables)",
    )
    parser.add_argument(
        "--kswapd-warn", type=float, default=25.0,
        help="WARNING above this percent CPU for any single kswapd thread",
    )
    parser.add_argument(
        "--kswapd-crit", type=float, default=60.0,
        help="CRITICAL above this percent CPU for any single kswapd thread",
    )
    parser.add_argument(
        "--reclaim-efficiency-warn", type=float, default=30.0,
        help="WARNING when pgsteal/pgscan falls below this percent while "
             "scanning actively",
    )
    parser.add_argument(
        "--scan-rate-floor", type=float, default=1000.0,
        help="Minimum pages/sec scan rate before reclaim efficiency is judged",
    )
    parser.add_argument(
        "--compact-fail-warn", type=float, default=90.0,
        help="WARNING when this percent of compaction attempts fail",
    )
    parser.add_argument(
        "--compact-rate-floor", type=float, default=1.0,
        help="Minimum compaction stalls/sec before the failure ratio is "
             "judged. A high failure ratio at a low event rate is normal "
             "background fragmentation, not a problem worth paging for",
    )
    parser.add_argument(
        "--psi-full-warn", type=float, default=1.0,
        help="WARNING above this percent memory PSI full avg10 (0 disables)",
    )
    parser.add_argument(
        "--boost-ratio-warn", type=float, default=2.0,
        help="WARNING when a node's min watermark exceeds the median across "
             "nodes by this factor, indicating active watermark boosting",
    )
    parser.add_argument(
        "--imbalance-host-free", type=float, default=15.0,
        help="Imbalance is flagged only when the host has at least this "
             "percent free overall (0 disables the imbalance check)",
    )
    parser.add_argument(
        "--max-state-age", type=int, default=900,
        help="Discard state older than this many seconds instead of "
             "computing rates across a stale window (default: 900)",
    )
    parser.add_argument(
        "--min-state-age", type=int, default=5,
        help="Minimum seconds between runs for deltas to be meaningful",
    )
    parser.add_argument("--state", default=DEFAULT_STATE, help="state file path")
    parser.add_argument(
        "--version", action="version",
        version=f"check_numa_health {__version__}",
    )
    return parser.parse_args()


def main():
    args = parse_args()

    meminfo = read_node_meminfo()
    if not meminfo:
        print("NUMA UNKNOWN - no NUMA nodes with local memory found in /sys")
        return UNKNOWN

    watermarks, kernel_reports_boost = read_zone_watermarks()
    kswapd_now = read_kswapd_cpu()
    vmstat_now = read_vmstat()
    now = time.time()

    previous = load_state(args.state)
    save_state(args.state, {
        "ts": now,
        "kswapd": kswapd_now,
        "vmstat": vmstat_now,
    })

    age = now - previous["ts"] if previous else None
    deltas_usable = (
        previous is not None
        and args.min_state_age <= age <= args.max_state_age
    )

    problems, notes, perfdata = [], [], []
    exit_code = OK

    def escalate(code):
        nonlocal exit_code
        exit_code = max(exit_code, code)

    # --- 1. Watermark health per node ------------------------------------
    threshold_order = {"min": 0, "low": 1, "high": 2}
    wm_crit = args.watermark_crit if args.watermark_crit != "off" else None
    wm_warn = args.watermark_warn if args.watermark_warn != "off" else None

    total_free_kb = total_mem_kb = 0
    lowest_node = None
    lowest_headroom = None
    nodes_below_low = []

    for node_id in sorted(meminfo, key=int):
        values = meminfo[node_id]
        free_kb, total_kb = values["MemFree"], values["MemTotal"]
        total_free_kb += free_kb
        total_mem_kb += total_kb
        free_pct = 100.0 * free_kb / total_kb

        perfdata.append(f"node{node_id}_free_pct={free_pct:.2f}%;;;0;100")
        perfdata.append(f"node{node_id}_free_mb={free_kb // 1024}MB")

        wm = watermarks.get(node_id)
        if wm and wm["high"] > 0:
            free_pages = wm["free"]
            # Headroom against the reclaim band: 0% means free has fallen to
            # the min watermark and allocations are stalling, 100% means the
            # node has reached the high watermark and kswapd can sleep.
            span = wm["high"] - wm["min"]
            headroom = (
                100.0 * (free_pages - wm["min"]) / span if span > 0 else 100.0
            )
            # Clamp the reported value: a node sitting 40000% above its
            # reclaim band carries no more information than "comfortable".
            shown = min(headroom, 999.0)
            perfdata.append(f"node{node_id}_wm_headroom={shown:.0f}%")

            if lowest_headroom is None or headroom < lowest_headroom:
                lowest_node, lowest_headroom = node_id, headroom

            if free_pages < wm["low"]:
                nodes_below_low.append(node_id)

            breached = None
            for name in ("min", "low", "high"):
                if free_pages < wm[name]:
                    breached = name
                    break

            if breached:
                free_mb = free_pages * PAGE_KB // 1024
                target_mb = wm[breached] * PAGE_KB // 1024
                message = (
                    f"node{node_id} free {free_mb} MB is below the "
                    f"{breached} watermark ({target_mb} MB)"
                )
                if wm_crit and threshold_order[breached] <= threshold_order[wm_crit]:
                    escalate(CRITICAL)
                    problems.append(message)
                elif wm_warn and threshold_order[breached] <= threshold_order[wm_warn]:
                    escalate(WARNING)
                    problems.append(message)

        # Optional percentage thresholds, disabled by default.
        if args.free_crit > 0 and free_pct < args.free_crit:
            escalate(CRITICAL)
            problems.append(f"node{node_id} at {free_pct:.2f}% free")
        elif args.free_warn > 0 and free_pct < args.free_warn:
            escalate(WARNING)
            problems.append(f"node{node_id} at {free_pct:.2f}% free")

    host_free_pct = 100.0 * total_free_kb / total_mem_kb if total_mem_kb else 0.0
    memoryless = max(
        0, len(glob.glob("/sys/devices/system/node/node[0-9]*")) - len(meminfo)
    )
    perfdata.append(f"host_free_pct={host_free_pct:.1f}%;;;0;100")
    perfdata.append(f"nodes_with_memory={len(meminfo)}")
    perfdata.append(f"nodes_without_memory={memoryless}")
    perfdata.append(f"state_age={age:.0f}s" if age is not None else "state_age=0s")
    perfdata.append(f"rate_checks={1 if deltas_usable else 0}")

    # --- 2. Watermark boost detection ------------------------------------
    boost_factor = read_sysctl("vm.watermark_boost_factor")
    if boost_factor is not None:
        perfdata.append(f"watermark_boost_factor={boost_factor}")

    mins = [
        watermarks[n]["min"] for n in meminfo
        if n in watermarks and watermarks[n]["min"] > 0
    ]
    if len(mins) >= 3:
        median_min = statistics.median(mins)
        for node_id in sorted(meminfo, key=int):
            wm = watermarks.get(node_id)
            if not wm or wm["min"] <= 0 or median_min <= 0:
                continue
            explicit = wm["boost"] if kernel_reports_boost else 0
            ratio = wm["min"] / median_min
            if explicit > 0 or ratio > args.boost_ratio_warn:
                inflated_mb = int((wm["min"] - median_min) * PAGE_KB // 1024)
                escalate(WARNING)
                if boost_factor == 0:
                    # Boost only decays inside balance_pgdat, which runs only
                    # while free is under the low watermark. An inflated
                    # watermark keeps free above low, so kswapd never runs and
                    # the boost never clears - it is stuck until the
                    # watermarks are recalculated.
                    problems.append(
                        f"node{node_id} watermarks still inflated by roughly "
                        f"{inflated_mb} MB (min is {ratio:.1f}x the median) "
                        f"even though watermark_boost_factor is 0 - stuck "
                        f"boost, clear it with: sysctl -w vm.min_free_kbytes="
                        f"$(sysctl -n vm.min_free_kbytes)"
                    )
                else:
                    problems.append(
                        f"node{node_id} watermarks inflated by roughly "
                        f"{inflated_mb} MB (min is {ratio:.1f}x the median) - "
                        f"watermark boosting is active (factor "
                        f"{boost_factor}), which can leave kswapd chasing an "
                        f"unreachable target"
                    )

    # --- 3. kswapd CPU ----------------------------------------------------
    hottest_kswapd = 0.0
    if deltas_usable:
        for node_id in sorted(kswapd_now, key=int):
            ticks = kswapd_now[node_id]
            prior = previous.get("kswapd", {}).get(node_id)
            if prior is None or ticks < prior:
                continue
            pct = 100.0 * (ticks - prior) / HZ / age
            hottest_kswapd = max(hottest_kswapd, pct)
            perfdata.append(
                f"kswapd{node_id}_cpu={pct:.1f}%;"
                f"{args.kswapd_warn};{args.kswapd_crit};0;100"
            )
            if pct > args.kswapd_crit:
                escalate(CRITICAL)
                problems.append(f"kswapd{node_id} burning {pct:.0f}% CPU")
            elif pct > args.kswapd_warn:
                escalate(WARNING)
                problems.append(f"kswapd{node_id} at {pct:.0f}% CPU")

    # --- 4. Reclaim efficiency and compaction -----------------------------
    if deltas_usable:
        prior_vm = previous.get("vmstat", {})

        def delta(key):
            if key in vmstat_now and key in prior_vm:
                return max(0, vmstat_now[key] - prior_vm[key])
            return None

        scan, steal = delta("pgscan_kswapd"), delta("pgsteal_kswapd")
        if scan is not None and steal is not None:
            scan_rate = scan / age
            perfdata.append(f"pgscan_kswapd_rate={scan_rate:.0f}")
            if scan_rate >= args.scan_rate_floor:
                efficiency = 100.0 * steal / scan if scan else 100.0
                perfdata.append(f"reclaim_efficiency={efficiency:.0f}%;;;0;100")
                if efficiency < args.reclaim_efficiency_warn:
                    escalate(WARNING)
                    problems.append(
                        f"kswapd reclaim is ineffective: {efficiency:.0f}% "
                        f"steal/scan at {scan_rate:.0f} pages/sec"
                    )
            elif hottest_kswapd > args.kswapd_warn:
                # Burning CPU without scanning is the signature of a busy
                # loop: with no swap the anonymous LRU gets zero scan
                # priority, so balance_pgdat returns without touching a page
                # and prepare_kswapd_sleep refuses to let it sleep.
                escalate(WARNING)
                problems.append(
                    "kswapd is consuming CPU while scanning nothing - check "
                    "whether swap is absent and watermarks are inflated"
                )

        direct = delta("pgscan_direct")
        if direct is not None:
            perfdata.append(f"pgscan_direct_rate={direct / age:.0f}")

        stall_total = 0
        for key in VMSTAT_KEYS:
            if not key.startswith("allocstall_"):
                continue
            value = delta(key)
            if value:
                stall_total += value
        perfdata.append(f"allocstall_rate={stall_total / age:.2f}")

        stall, fail = delta("compact_stall"), delta("compact_fail")
        if stall is not None and fail is not None:
            stall_rate = stall / age
            perfdata.append(f"compact_stall_rate={stall_rate:.2f}")
            if stall_rate >= args.compact_rate_floor:
                ratio = 100.0 * fail / stall
                perfdata.append(f"compact_fail_pct={ratio:.0f}%;;;0;100")
                if ratio > args.compact_fail_warn:
                    escalate(WARNING)
                    problems.append(
                        f"compaction failing {ratio:.0f}% of "
                        f"{stall_rate:.2f} attempts/sec - check "
                        f"vm.watermark_boost_factor and THP defrag"
                    )

    # --- 5. Pressure stall information ------------------------------------
    psi_some, psi_full = read_psi_memory()
    if psi_full is not None:
        warn_field = args.psi_full_warn if args.psi_full_warn > 0 else ""
        perfdata.append(f"psi_mem_full={psi_full:.2f}%;{warn_field};;0;100")
        perfdata.append(f"psi_mem_some={psi_some:.2f}%;;;0;100")
        if args.psi_full_warn > 0 and psi_full > args.psi_full_warn:
            escalate(WARNING)
            problems.append(f"memory PSI full avg10 at {psi_full:.1f}%")

    # --- 6. NUMA imbalance -------------------------------------------------
    if (
        args.imbalance_host_free > 0
        and nodes_below_low
        and host_free_pct >= args.imbalance_host_free
    ):
        escalate(CRITICAL)
        problems.append(
            f"NUMA imbalance: node(s) {', '.join(nodes_below_low)} below the "
            f"low watermark while the host has {host_free_pct:.0f}% free - "
            f"check strict NUMA pinning and memory-less node fallback"
        )

    # --- Output ------------------------------------------------------------
    # A stale state file means rate-based checks were skipped, which is
    # worth surfacing because it usually indicates the check interval or a
    # gap in scheduling. A fresh first run is not worth mentioning.
    if previous is not None and not deltas_usable and age > args.max_state_age:
        notes.append(
            f"state {age:.0f}s old (limit {args.max_state_age}s), "
            f"rate checks skipped"
        )

    if not problems:
        detail = f"{len(meminfo)} nodes with memory"
        if memoryless:
            detail += f", {memoryless} without"
        if lowest_node is not None:
            if lowest_headroom > 999:
                detail += f"; tightest node{lowest_node} well clear of its watermarks"
            else:
                detail += (
                    f"; tightest node{lowest_node} at {lowest_headroom:.0f}% "
                    f"watermark headroom"
                )
        detail += f"; host {host_free_pct:.0f}% free"
        notes.insert(0, detail)

    summary = "; ".join(problems + notes) if problems else "; ".join(notes)
    print(f"NUMA {STATUS[exit_code]} - {summary} | {' '.join(perfdata)}")
    return exit_code


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(UNKNOWN)
    except BrokenPipeError:
        # Output was truncated by a pipe (head, less). Not a check failure.
        os._exit(OK)
    except Exception as exc:  # noqa: BLE001
        try:
            print(f"NUMA UNKNOWN - unexpected error: {exc}")
        except BrokenPipeError:
            pass
        sys.exit(UNKNOWN)

