#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Nagios plugin: Auto-discover QEMU VMs on host and check VMA (memory mappings) usage.

- Автоматично намира всички qemu-system-* процеси (без virsh).
- Извлича името на VM от "-name guest=<name>,..." в cmdline (или от "-name <name>,...").
- Брои редовете в /proc/<pid>/maps = брой VMA (memory mappings).
- Сравнява спрямо vm.max_map_count (от /proc/sys/vm/max_map_count или --max-map-count).
- Връща най-лошия статус за всички VM.
- Извежда perfdata за графики:
    <vm>_maps=<value>;<warn_abs>;<crit_abs>;0;<max_map_count>
    <vm>_pct=<pct>;<warn_pct>;<crit_pct>;0;100

Опции за филтриране:
- --include REGEX : следи само VM имена, които мачват REGEX
- --exclude REGEX : изключва VM имена, които мачват REGEX

Забележка: Нужни са права да се чете /proc/<pid>/maps (обикновено root).
"""

import argparse
import os
import re
import sys
from typing import Dict, List, Optional, Tuple

N_OK, N_WARN, N_CRIT, N_UNK = 0, 1, 2, 3

def read_file(path: str) -> Optional[bytes]:
    try:
        with open(path, "rb") as f:
            return f.read()
    except Exception:
        return None

def read_max_map_count(override: Optional[int]) -> int:
    if override and override > 0:
        return override
    data = read_file("/proc/sys/vm/max_map_count")
    if not data:
        return 65530
    try:
        return int(data.decode().strip())
    except Exception:
        return 65530

def iter_qemu_pids(proc_regex: re.Pattern) -> List[int]:
    pids: List[int] = []
    for entry in os.scandir("/proc"):
        if not entry.name.isdigit() or not entry.is_dir():
            continue
        pid = int(entry.name)
        # /proc/<pid>/comm е по-надеждно от ps
        comm_b = read_file(f"/proc/{pid}/comm")
        if not comm_b:
            continue
        comm = comm_b.decode(errors="ignore").strip()
        if not proc_regex.match(comm):
            # fallback: проверка на exe basename, ако comm не мачне
            exe_path = None
            try:
                exe_path = os.readlink(f"/proc/{pid}/exe")
            except Exception:
                exe_path = None
            if not exe_path:
                continue
            base = os.path.basename(exe_path)
            if not proc_regex.match(base):
                continue
        pids.append(pid)
    return pids

def parse_vm_name_from_cmdline(args: List[str]) -> Optional[str]:
    """
    Търси:
      - ... -name guest=<NAME>,debug-threads=on ...
      - ... -name <NAME>,debug-threads=on ...
    Връща NAME без суфикса след първата запетая.
    """
    for i, a in enumerate(args):
        if a == "-name" and i + 1 < len(args):
            val = args[i + 1]
            # Опит 1: guest=<name>,...
            m = re.search(r'(?:^|,)guest=([^,]+)', val)
            if m:
                return m.group(1)
            # Опит 2: директно име до първата запетая
            return val.split(",", 1)[0]
    # fallback: опитай да откриеш комбиниран аргумент "-name=<...>"
    for a in args:
        if a.startswith("-name="):
            val = a.split("=", 1)[1]
            m = re.search(r'(?:^|,)guest=([^,]+)', val)
            if m:
                return m.group(1)
            return val.split(",", 1)[0]
    return None

def get_cmdline_args(pid: int) -> List[str]:
    data = read_file(f"/proc/{pid}/cmdline")
    if not data:
        return []
    # cmdline е \0 разделен
    parts = data.split(b"\x00")
    out = []
    for b in parts:
        if not b:
            continue
        out.append(b.decode(errors="ignore"))
    return out

def count_maps(pid: int) -> Optional[int]:
    try:
        cnt = 0
        with open(f"/proc/{pid}/maps", "r", encoding="utf-8", errors="ignore") as f:
            for _ in f:
                cnt += 1
        return cnt
    except Exception:
        return None

def eval_status(pct: float, warn: float, crit: float) -> int:
    if pct >= crit:
        return N_CRIT
    if pct >= warn:
        return N_WARN
    return N_OK

def worst(s1: int, s2: int) -> int:
    return max(s1, s2)

def sanitize_label(label: str) -> str:
    # Перфометриките е добре да се цитират, ако има интервали/спец. символи
    if re.search(r"[^a-zA-Z0-9_.-]", label):
        return f"'{label}'"
    return label

def main():
    ap = argparse.ArgumentParser(description="Auto-discover QEMU VMs and check VMA usage.")
    ap.add_argument("--warn", type=float, default=80.0, help="Warning threshold in percent of vm.max_map_count (default 80).")
    ap.add_argument("--crit", type=float, default=90.0, help="Critical threshold in percent of vm.max_map_count (default 90).")
    ap.add_argument("--max-map-count", type=int, help="Override vm.max_map_count (default: read from /proc).")
    ap.add_argument("--proc-regex", default=r"^qemu-system-.*$", help="Regex to match process name/comm (default: ^qemu-system-.*$).")
    ap.add_argument("--include", help="Regex to include only VM names matching this pattern.")
    ap.add_argument("--exclude", help="Regex to exclude VM names matching this pattern.")
    ap.add_argument("--ok-if-none", action="store_true", help="Return OK if no QEMU processes found (default: UNKNOWN).")
    args = ap.parse_args()

    if args.warn >= args.crit:
        print("UNKNOWN - --warn must be less than --crit")
        sys.exit(N_UNK)

    try:
        proc_re = re.compile(args.proc_regex)
    except re.error as e:
        print(f"UNKNOWN - Invalid --proc-regex: {e}")
        sys.exit(N_UNK)

    inc_re = None
    exc_re = None
    try:
        if args.include:
            inc_re = re.compile(args.include)
        if args.exclude:
            exc_re = re.compile(args.exclude)
    except re.error as e:
        print(f"UNKNOWN - Invalid include/exclude regex: {e}")
        sys.exit(N_UNK)

    max_map = read_max_map_count(args.max_map_count)
    if max_map <= 0:
        print("UNKNOWN - invalid vm.max_map_count")
        sys.exit(N_UNK)

    pids = iter_qemu_pids(proc_re)
    if not pids:
        msg = "No QEMU processes found"
        if args.ok_if_none:
            print(f"OK - {msg} |")
            sys.exit(N_OK)
        else:
            print(f"UNKNOWN - {msg}")
            sys.exit(N_UNK)

    results: List[Tuple[str, int, float, int]] = []  # (name, maps, pct, pid)
    unknowns: List[str] = []

    for pid in pids:
        args_list = get_cmdline_args(pid)
        vm_name = parse_vm_name_from_cmdline(args_list)
        if not vm_name:
            # fallback – ползвай pid като име
            vm_name = f"pid-{pid}"

        if inc_re and not inc_re.search(vm_name):
            continue
        if exc_re and exc_re.search(vm_name):
            continue

        maps = count_maps(pid)
        if maps is None:
            unknowns.append(f"{vm_name}=NO_MAPS")
            continue

        pct = (maps / max_map) * 100.0
        results.append((vm_name, maps, pct, pid))

    if not results and not unknowns:
        msg = "No matching VMs after include/exclude filters"
        if args.ok_if_none:
            print(f"OK - {msg} |")
            sys.exit(N_OK)
        else:
            print(f"UNKNOWN - {msg}")
            sys.exit(N_UNK)

    overall = N_OK
    msgs_human: List[str] = []
    perf: List[str] = []

    warn_abs = int(max_map * (args.warn / 100.0))
    crit_abs = int(max_map * (args.crit / 100.0))

    for name, maps, pct, pid in sorted(results, key=lambda x: x[0]):
        st = eval_status(pct, args.warn, args.crit)
        overall = worst(overall, st)
        msgs_human.append(f"{name}:{maps}/{max_map} ({pct:.1f}%)")

        # perfdata
        label_maps = sanitize_label(f"{name}_maps")
        perf.append(f"{label_maps}={maps};{warn_abs};{crit_abs};0;{max_map}")

        label_pct = sanitize_label(f"{name}_pct")
        perf.append(f"{label_pct}={pct:.2f}%;{args.warn:.2f};{args.crit:.2f};0;100")

    # добави unknown-и (без perfdata)
    if unknowns:
        overall = worst(overall, N_UNK)
        msgs_human.extend(unknowns)

    status_txt = {N_OK: "OK", N_WARN: "WARNING", N_CRIT: "CRITICAL", N_UNK: "UNKNOWN"}[overall]
    print(f"{status_txt} - QEMU VMA usage | {' '.join(perf)} :: {'; '.join(msgs_human)}")
    sys.exit(overall)

if __name__ == "__main__":
    main()

