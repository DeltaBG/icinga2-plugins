#!/usr/bin/env python3
# check_ksm.py - Icinga/Nagios plugin for Linux KSM
#
# Exit codes: 0 OK, 1 WARNING, 2 CRITICAL, 3 UNKNOWN

import argparse
import os
import sys
from typing import Optional, Dict


OK = 0
WARNING = 1
CRITICAL = 2
UNKNOWN = 3


def read_int(path: str) -> Optional[int]:
    try:
        with open(path, "r", encoding="utf-8") as f:
            return int(f.read().strip())
    except FileNotFoundError:
        return None
    except Exception:
        return None


def read_memtotal_bytes() -> Optional[int]:
    try:
        with open("/proc/meminfo", "r", encoding="utf-8") as f:
            for line in f:
                if line.startswith("MemTotal:"):
                    # MemTotal:      263975640 kB
                    parts = line.split()
                    if len(parts) >= 2:
                        kb = int(parts[1])
                        return kb * 1024
        return None
    except Exception:
        return None


def human_bytes(n: int) -> str:
    # simple IEC-ish formatting
    units = ["B", "KiB", "MiB", "GiB", "TiB", "PiB"]
    v = float(n)
    for u in units:
        if v < 1024.0 or u == units[-1]:
            if u == "B":
                return f"{int(v)}{u}"
            return f"{v:.2f}{u}"
        v /= 1024.0
    return f"{n}B"


def main() -> int:
    p = argparse.ArgumentParser(description="Check Linux KSM status and key metrics")
    p.add_argument("--ksm-path", default="/sys/kernel/mm/ksm", help="Path to KSM sysfs dir (default: /sys/kernel/mm/ksm)")
    p.add_argument("--warn-if-off", action="store_true", default=True, help="Return WARNING if KSM is not enabled (default: true)")
    p.add_argument("--ok-if-off", action="store_true", default=False, help="Override: return OK even if KSM is off")
    args = p.parse_args()

    ksm_path = args.ksm_path

    run = read_int(os.path.join(ksm_path, "run"))
    if run is None:
        print("UNKNOWN - KSM sysfs not found or unreadable: " + ksm_path)
        return UNKNOWN

    # Core metrics (some may not exist on older kernels)
    metrics: Dict[str, Optional[int]] = {}
    for name in [
        "pages_shared",
        "pages_sharing",
        "pages_unshared",
        "pages_volatile",
        "pages_scanned",
        "pages_skipped",
        "full_scans",
        "ksm_zero_pages",
        "general_profit",
        "max_page_sharing",
        "merge_across_nodes",
        "pages_to_scan",
        "sleep_millisecs",
        "use_zero_pages",
        "stable_node_chains",
        "stable_node_dups",
    ]:
        metrics[name] = read_int(os.path.join(ksm_path, name))

    page_size = os.sysconf("SC_PAGE_SIZE")  # bytes
    mem_total = read_memtotal_bytes()

    pages_sharing = metrics.get("pages_sharing") or 0
    ksm_zero_pages = metrics.get("ksm_zero_pages") or 0

    # Per kernel docs: pages_sharing + ksm_zero_pages = actual pages saved (when zero-page feature used; otherwise ksm_zero_pages==0)
    saved_pages = pages_sharing + ksm_zero_pages
    saved_bytes = saved_pages * page_size

    saved_pct = None
    if mem_total and mem_total > 0:
        saved_pct = (saved_bytes / mem_total) * 100.0

    # Status logic
    is_on = (run == 1)
    if args.ok_if_off:
        status = OK
        status_txt = "OK"
    else:
        if is_on:
            status = OK
            status_txt = "OK"
        else:
            status = WARNING if args.warn_if_off else OK
            status_txt = "WARNING" if status == WARNING else "OK"

    # Compose message
    parts = []
    parts.append(f"run={run}")
    if mem_total:
        if saved_pct is not None:
            parts.append(f"saved={human_bytes(saved_bytes)} ({saved_pct:.2f}% of MemTotal)")
        else:
            parts.append(f"saved={human_bytes(saved_bytes)}")
    else:
        parts.append(f"saved={human_bytes(saved_bytes)} (MemTotal unknown)")

    # Add "most important" counters
    def add_if(name: str, label: Optional[str] = None):
        v = metrics.get(name)
        if v is not None:
            parts.append(f"{label or name}={v}")

    add_if("pages_shared")
    add_if("pages_sharing")
    add_if("ksm_zero_pages")
    add_if("pages_unshared")
    add_if("pages_volatile")
    add_if("pages_scanned")
    add_if("full_scans")
    add_if("general_profit", "general_profit~")
    add_if("max_page_sharing")
    add_if("merge_across_nodes")
    add_if("stable_node_chains")

    message = f"{status_txt} - KSM {'ON' if is_on else 'OFF'}; " + " ".join(parts)

    # Perfdata (good for graphs)
    perf = []
    perf.append(f"ksm_run={run}")
    perf.append(f"saved_bytes={saved_bytes}B")
    if saved_pct is not None:
        perf.append(f"saved_pct={saved_pct:.2f}%")
    if mem_total:
        perf.append(f"memtotal_bytes={mem_total}B")

    for k in ["pages_shared", "pages_sharing", "ksm_zero_pages", "pages_unshared", "pages_volatile", "pages_scanned", "pages_skipped", "full_scans", "stable_node_chains"]:
        v = metrics.get(k)
        if v is not None:
            perf.append(f"{k}={v}")

    gp = metrics.get("general_profit")
    if gp is not None:
        # units are approximate per kernel docs formula; keep as raw counter with B suffix for consistency
        perf.append(f"general_profit={gp}B")

    print(message + " | " + " ".join(perf))
    return status


if __name__ == "__main__":
    sys.exit(main())
