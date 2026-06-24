#!/usr/bin/env python3
# check_cpufreq.py - Icinga/Nagios plugin for Linux CPU frequency and governor
#
# Exit codes: 0 OK, 1 WARNING, 2 CRITICAL, 3 UNKNOWN

import argparse
import os
import re
import sys
from dataclasses import dataclass
from typing import List, Optional, Tuple


OK = 0
WARNING = 1
CRITICAL = 2
UNKNOWN = 3

CPU_RE = re.compile(r"^cpu([0-9]+)$")


@dataclass
class CpuFreq:
    cpu: str
    current_khz: int
    reference_khz: int
    warn_khz: int
    crit_khz: int
    governor: Optional[str]


def read_text(path: str) -> Optional[str]:
    try:
        with open(path, "r", encoding="utf-8") as f:
            return f.read().strip()
    except OSError:
        return None


def read_int(path: str) -> Optional[int]:
    text = read_text(path)
    if text is None:
        return None
    try:
        value = int(text)
    except ValueError:
        return None
    if value <= 0:
        return None
    return value


def first_int(paths: List[str]) -> Optional[int]:
    for path in paths:
        value = read_int(path)
        if value is not None:
            return value
    return None


def khz_to_mhz(khz: int) -> float:
    return khz / 1000.0


def fmt_mhz(khz: int) -> str:
    return f"{khz_to_mhz(khz):.1f}MHz"


def perf_float(value: float) -> str:
    return f"{value:.2f}".rstrip("0").rstrip(".")


def is_cpu_online(cpu_path: str) -> bool:
    online = read_text(os.path.join(cpu_path, "online"))
    return online != "0"


def list_cpu_paths(sysfs_root: str) -> List[Tuple[int, str, str]]:
    cpus = []
    try:
        entries = os.listdir(sysfs_root)
    except OSError:
        return cpus

    for entry in entries:
        match = CPU_RE.match(entry)
        if not match:
            continue
        cpu_num = int(match.group(1))
        cpu_path = os.path.join(sysfs_root, entry)
        if os.path.isdir(cpu_path) and is_cpu_online(cpu_path):
            cpus.append((cpu_num, entry, cpu_path))

    return sorted(cpus, key=lambda item: item[0])


def collect_cpu_freqs(args: argparse.Namespace) -> Tuple[List[CpuFreq], List[str]]:
    cpus = []
    unknown = []

    for _, cpu, cpu_path in list_cpu_paths(args.sysfs_root):
        cpufreq = os.path.join(cpu_path, "cpufreq")
        if not os.path.isdir(cpufreq):
            unknown.append(f"{cpu}: missing cpufreq")
            continue

        current_khz = first_int(
            [
                os.path.join(cpufreq, "scaling_cur_freq"),
                os.path.join(cpufreq, "cpuinfo_cur_freq"),
            ]
        )
        if current_khz is None:
            unknown.append(f"{cpu}: missing current frequency")
            continue

        reference_khz = first_int(
            [
                os.path.join(cpufreq, "cpuinfo_max_freq"),
                os.path.join(cpufreq, "scaling_max_freq"),
                os.path.join(cpufreq, "base_frequency"),
            ]
        )
        if reference_khz is None and (args.warn_mhz is None or args.crit_mhz is None):
            unknown.append(f"{cpu}: missing max frequency for automatic thresholds")
            continue

        if reference_khz is None:
            reference_khz = current_khz

        warn_khz = int(args.warn_mhz * 1000) if args.warn_mhz is not None else int(reference_khz * args.warn_percent / 100.0)
        crit_khz = int(args.crit_mhz * 1000) if args.crit_mhz is not None else int(reference_khz * args.crit_percent / 100.0)

        if warn_khz < crit_khz:
            unknown.append(f"{cpu}: warning threshold is below critical threshold")
            continue

        governor = None if args.no_governor_check else read_text(os.path.join(cpufreq, "scaling_governor"))
        cpus.append(CpuFreq(cpu, current_khz, reference_khz, warn_khz, crit_khz, governor))

    return cpus, unknown


def status_name(code: int) -> str:
    return {
        OK: "OK",
        WARNING: "WARNING",
        CRITICAL: "CRITICAL",
        UNKNOWN: "UNKNOWN",
    }[code]


def determine_status(
    cpus: List[CpuFreq],
    unknown: List[str],
    expected_governor: str,
    governor_state: int,
    show_cpus: int,
) -> Tuple[int, str]:
    below_crit = [c for c in cpus if c.current_khz < c.crit_khz]
    below_warn = [c for c in cpus if c.crit_khz <= c.current_khz < c.warn_khz]
    bad_governor = [
        c
        for c in cpus
        if c.governor is not None and c.governor != expected_governor
    ]
    missing_governor = [
        c.cpu for c in cpus if c.governor is None and expected_governor
    ]

    if below_crit or (bad_governor and governor_state == CRITICAL):
        status = CRITICAL
    elif below_warn or (bad_governor and governor_state == WARNING):
        status = WARNING
    elif unknown or missing_governor:
        status = UNKNOWN
    else:
        status = OK

    if not cpus:
        details = "; ".join(unknown[:show_cpus]) if unknown else "no online CPUs found"
        return UNKNOWN, f"no usable cpufreq data ({details})"

    current_values = [c.current_khz for c in cpus]
    min_cpu = min(cpus, key=lambda c: c.current_khz)
    avg_khz = sum(current_values) / len(current_values)
    min_pct = (min_cpu.current_khz / min_cpu.reference_khz) * 100.0

    summary = [
        f"{len(cpus)} CPU(s) checked",
        f"min={fmt_mhz(min_cpu.current_khz)} ({min_pct:.1f}% of {fmt_mhz(min_cpu.reference_khz)})",
        f"avg={khz_to_mhz(int(avg_khz)):.1f}MHz",
    ]

    problems = []
    if below_crit:
        examples = ", ".join(
            f"{c.cpu} {fmt_mhz(c.current_khz)} < crit {fmt_mhz(c.crit_khz)}"
            for c in below_crit[:show_cpus]
        )
        problems.append(f"{len(below_crit)} below critical frequency: {examples}")
    if below_warn:
        examples = ", ".join(
            f"{c.cpu} {fmt_mhz(c.current_khz)} < warn {fmt_mhz(c.warn_khz)}"
            for c in below_warn[:show_cpus]
        )
        problems.append(f"{len(below_warn)} below warning frequency: {examples}")
    if bad_governor:
        examples = ", ".join(
            f"{c.cpu}={c.governor}" for c in bad_governor[:show_cpus]
        )
        problems.append(f"{len(bad_governor)} governor mismatch (expected {expected_governor}): {examples}")
    if missing_governor:
        problems.append(
            f"{len(missing_governor)} missing scaling_governor: {', '.join(missing_governor[:show_cpus])}"
        )
    if unknown:
        problems.append(f"{len(unknown)} unknown: {', '.join(unknown[:show_cpus])}")

    if problems:
        message = "; ".join(problems + summary)
    else:
        governor_text = "governor check disabled"
        if expected_governor:
            governor_text = f"all governors are {expected_governor}"
        message = "; ".join([governor_text] + summary)

    return status, message


def performance_data(cpus: List[CpuFreq], args: argparse.Namespace) -> str:
    if not cpus:
        return ""

    current_values = [c.current_khz for c in cpus]
    min_cpu = min(cpus, key=lambda c: c.current_khz)
    max_cpu = max(cpus, key=lambda c: c.current_khz)
    avg_khz = sum(current_values) / len(current_values)
    min_pct = (min_cpu.current_khz / min_cpu.reference_khz) * 100.0
    warn_pct = (min_cpu.warn_khz / min_cpu.reference_khz) * 100.0
    crit_pct = (min_cpu.crit_khz / min_cpu.reference_khz) * 100.0
    below_warn = len([c for c in cpus if c.crit_khz <= c.current_khz < c.warn_khz])
    below_crit = len([c for c in cpus if c.current_khz < c.crit_khz])
    bad_governor = len(
        [
            c
            for c in cpus
            if c.governor is not None and c.governor != args.governor
        ]
    )

    perf = [
        f"freq_min_mhz={perf_float(khz_to_mhz(min_cpu.current_khz))}MHz;{perf_float(khz_to_mhz(min_cpu.warn_khz))}:;{perf_float(khz_to_mhz(min_cpu.crit_khz))}:;0;{perf_float(khz_to_mhz(min_cpu.reference_khz))}",
        f"freq_avg_mhz={perf_float(khz_to_mhz(avg_khz))}MHz;;;0;",
        f"freq_max_mhz={perf_float(khz_to_mhz(max_cpu.current_khz))}MHz;;;0;{perf_float(khz_to_mhz(max_cpu.reference_khz))}",
        f"freq_min_pct={perf_float(min_pct)}%;{perf_float(warn_pct)}:;{perf_float(crit_pct)}:;0;100",
        f"freq_below_warn={below_warn}",
        f"freq_below_crit={below_crit}",
        f"governor_bad={bad_governor}",
    ]

    if args.per_cpu_perfdata:
        for cpu in cpus:
            pct = (cpu.current_khz / cpu.reference_khz) * 100.0
            perf.append(
                f"{cpu.cpu}_freq_mhz={perf_float(khz_to_mhz(cpu.current_khz))}MHz;{perf_float(khz_to_mhz(cpu.warn_khz))}:;{perf_float(khz_to_mhz(cpu.crit_khz))}:;0;{perf_float(khz_to_mhz(cpu.reference_khz))}"
            )
            perf.append(f"{cpu.cpu}_freq_pct={perf_float(pct)}%;;;0;100")

    return " ".join(perf)


def parse_governor_state(value: str) -> int:
    states = {
        "warning": WARNING,
        "critical": CRITICAL,
    }
    if value not in states:
        raise argparse.ArgumentTypeError("must be warning or critical")
    return states[value]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Check Linux CPU frequency drop and cpufreq scaling governor",
        usage=(
            "%(prog)s [options] "
            "[--warn-mhz-percent PERCENT] [--crit-mhz-percent PERCENT] "
            "[--warn-mhz MHZ] [--crit-mhz MHZ]"
        ),
        epilog=(
            "Examples:\n"
            "  %(prog)s --warn-mhz-percent 70 --crit-mhz-percent 50\n"
            "  %(prog)s --warn-mhz 1800 --crit-mhz 1000"
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.set_defaults(warn_percent=70.0, crit_percent=50.0)
    parser.add_argument(
        "--sysfs-root",
        default="/sys/devices/system/cpu",
        help="CPU sysfs root (default: /sys/devices/system/cpu)",
    )
    parser.add_argument(
        "-w",
        "--warn-percent",
        dest="warn_percent",
        type=float,
        metavar="PERCENT",
        help="Alias for --warn-mhz-percent (default: 70)",
    )
    parser.add_argument(
        "--warn-mhz-percent",
        dest="warn_percent",
        type=float,
        metavar="PERCENT",
        help="Warning threshold as percent of max CPU frequency (default: 70)",
    )
    parser.add_argument(
        "-c",
        "--crit-percent",
        dest="crit_percent",
        type=float,
        metavar="PERCENT",
        help="Alias for --crit-mhz-percent (default: 50)",
    )
    parser.add_argument(
        "--crit-mhz-percent",
        dest="crit_percent",
        type=float,
        metavar="PERCENT",
        help="Critical threshold as percent of max CPU frequency (default: 50)",
    )
    parser.add_argument(
        "--warn-mhz",
        type=float,
        default=None,
        help="Fixed warning threshold in MHz; overrides --warn-percent/--warn-mhz-percent",
    )
    parser.add_argument(
        "--crit-mhz",
        type=float,
        default=None,
        help="Fixed critical threshold in MHz; overrides --crit-percent/--crit-mhz-percent",
    )
    parser.add_argument(
        "-g",
        "--governor",
        default="performance",
        help="Expected scaling_governor value (default: performance)",
    )
    parser.add_argument(
        "--governor-state",
        type=parse_governor_state,
        default=CRITICAL,
        help="State for governor mismatch: warning or critical (default: critical)",
    )
    parser.add_argument(
        "--no-governor-check",
        action="store_true",
        help="Disable scaling_governor check",
    )
    parser.add_argument(
        "--show-cpus",
        type=int,
        default=6,
        help="Maximum CPU examples in plugin output (default: 6)",
    )
    parser.add_argument(
        "--per-cpu-perfdata",
        action="store_true",
        help="Include per-CPU frequency metrics in performance data",
    )
    args = parser.parse_args()

    if args.warn_percent <= 0 or args.crit_percent <= 0:
        parser.error("--warn-percent/--warn-mhz-percent and --crit-percent/--crit-mhz-percent must be positive")
    if args.warn_percent < args.crit_percent:
        parser.error("--warn-percent/--warn-mhz-percent must be greater than or equal to --crit-percent/--crit-mhz-percent")
    if args.warn_mhz is not None and args.warn_mhz <= 0:
        parser.error("--warn-mhz must be positive")
    if args.crit_mhz is not None and args.crit_mhz <= 0:
        parser.error("--crit-mhz must be positive")
    if args.warn_mhz is not None and args.crit_mhz is not None and args.warn_mhz < args.crit_mhz:
        parser.error("--warn-mhz must be greater than or equal to --crit-mhz")
    if args.show_cpus < 1:
        parser.error("--show-cpus must be at least 1")
    if args.no_governor_check:
        args.governor = ""

    return args


def main() -> int:
    args = parse_args()
    cpus, unknown = collect_cpu_freqs(args)
    status, message = determine_status(
        cpus,
        unknown,
        args.governor,
        args.governor_state,
        args.show_cpus,
    )
    perf = performance_data(cpus, args)

    output = f"{status_name(status)}: {message}"
    if perf:
        output += f" | {perf}"
    print(output)
    return status


if __name__ == "__main__":
    sys.exit(main())
