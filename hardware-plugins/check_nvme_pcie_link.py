#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Nagios/Icinga plugin: checks that every NVMe drive negotiated its PCIe link
with the expected number of lanes (and speed).

A drive that is badly seated, or sits behind a bad backplane port/cable, still
comes up, but with fewer lanes (e.g. x2 or x1 instead of x4). It keeps working,
only slower, so nothing else alerts on it.

How it works (sysfs only, no root, no external tools):
  /sys/class/nvme/nvmeX/address           -> PCI address of the controller
  /sys/bus/pci/devices/<addr>/max_link_*  -> what the drive supports
  /sys/bus/pci/devices/<addr>/current_link_* -> what is negotiated now
  same files on the parent (upstream) port -> what the slot supports

Expected link = min(drive capability, slot capability), so:
  - a Gen5 drive in a Gen4 slot is OK at Gen4
  - a Gen4 M.2 drive on a Gen3 port is OK at Gen3
Width lower than expected  -> CRITICAL (WARNING with --width-warn)
Speed lower than expected  -> WARNING  (ignored with --ignore-speed)

Fabrics controllers (nvme-tcp/rdma/fc) have no PCI link and are skipped.
Partitioning a drive or splitting it into several namespaces (e.g. several
Ceph OSDs per drive) does not matter: the link belongs to the controller,
which is checked once.

Usage:
  /usr/lib/nagios/plugins/check_nvme_pcie_link.py [--min-drives N]
      [--ignore nvme1,0000:01:00.0] [--ignore-speed] [--width-warn] [-v]

Output: standard Nagios status + perfdata drives/degraded_width/degraded_speed.
"""

import argparse
import os
import sys

N_OK, N_WARN, N_CRIT, N_UNK = 0, 1, 2, 3
STATUS = {N_OK: "OK", N_WARN: "WARNING", N_CRIT: "CRITICAL", N_UNK: "UNKNOWN"}

NVME_CLASS = "/sys/class/nvme"
PCI_DEVS = "/sys/bus/pci/devices"
# GT/s -> PCIe generation, for readable output
GEN = {2.5: 1, 5.0: 2, 8.0: 3, 16.0: 4, 32.0: 5, 64.0: 6}


def read(path):
    try:
        with open(path) as f:
            return f.read().strip()
    except OSError:
        return None


def parse_width(val):
    # "4" (or "x4" on some kernels); 0 / 255 mean unknown/link down
    if not val:
        return None
    try:
        w = int(val.lstrip("x"))
    except ValueError:
        return None
    return w if 0 < w <= 32 else None


def parse_speed(val):
    # "16.0 GT/s PCIe", "8.0 GT/s", "2.5 GT/s"; "Unknown" -> None
    if not val:
        return None
    try:
        return float(val.split()[0])
    except (ValueError, IndexError):
        return None


def link(pci_path):
    return {
        "max_w": parse_width(read(os.path.join(pci_path, "max_link_width"))),
        "cur_w": parse_width(read(os.path.join(pci_path, "current_link_width"))),
        "max_s": parse_speed(read(os.path.join(pci_path, "max_link_speed"))),
        "cur_s": parse_speed(read(os.path.join(pci_path, "current_link_speed"))),
    }


def fmt(speed, width):
    g = GEN.get(speed)
    s = ("Gen%d" % g) if g else ("%sGT/s" % speed if speed else "?")
    return "%s x%s" % (s, width if width else "?")


def emin(a, b):
    vals = [v for v in (a, b) if v]
    return min(vals) if vals else None


def collect():
    drives = []
    for name in sorted(os.listdir(NVME_CLASS),
                       key=lambda n: int(n[4:]) if n[4:].isdigit() else 0):
        if not name.startswith("nvme") or not name[4:].isdigit():
            continue
        base = os.path.join(NVME_CLASS, name)
        transport = read(os.path.join(base, "transport")) or "pcie"
        if transport != "pcie":
            continue
        addr = read(os.path.join(base, "address"))
        pci = os.path.join(PCI_DEVS, addr or "")
        if not addr or not os.path.isdir(pci):
            drives.append({"name": name, "addr": addr, "error": "no PCI device"})
            continue
        real = os.path.realpath(pci)
        up = os.path.dirname(real)
        dev = link(real)
        port = link(up) if os.path.exists(os.path.join(up, "max_link_width")) else {}
        drives.append({
            "name": name,
            "addr": addr,
            "model": " ".join((read(os.path.join(base, "model")) or "?").split()),
            "dev": dev,
            "port": port,
            "exp_w": emin(dev["max_w"], port.get("max_w")),
            "exp_s": emin(dev["max_s"], port.get("max_s")),
        })
    return drives


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--min-drives", type=int, default=0,
                    help="CRITICAL if fewer PCIe NVMe controllers are found")
    ap.add_argument("--ignore", default="",
                    help="comma separated controller names or PCI addresses")
    ap.add_argument("--ignore-speed", action="store_true",
                    help="do not alert on reduced link speed")
    ap.add_argument("--width-warn", action="store_true",
                    help="reduced width is WARNING instead of CRITICAL")
    ap.add_argument("-v", "--verbose", action="store_true",
                    help="list every drive in the long output")
    args = ap.parse_args()

    if not os.path.isdir(NVME_CLASS):
        if args.min_drives:
            print("CRITICAL - no NVMe controllers (%s missing)" % NVME_CLASS)
            return N_CRIT
        print("OK - no NVMe controllers | drives=0 degraded_width=0 degraded_speed=0")
        return N_OK

    try:
        drives = collect()
    except Exception as e:  # pragma: no cover
        print("UNKNOWN - %s" % e)
        return N_UNK

    ignore = {x.strip() for x in args.ignore.split(",") if x.strip()}
    drives = [d for d in drives if d["name"] not in ignore and d["addr"] not in ignore]

    rc = N_OK
    bad_w, bad_s, unknown, lines = [], [], [], []
    for d in drives:
        if "error" in d or not d["dev"]["cur_w"] or not d["exp_w"]:
            unknown.append(d)
            lines.append("%s %s: link state unreadable (link down?)"
                         % (d["name"], d.get("addr")))
            continue
        cur = fmt(d["dev"]["cur_s"], d["dev"]["cur_w"])
        exp = fmt(d["exp_s"], d["exp_w"])
        desc = "%s %s (%s): %s, expected %s" % (d["name"], d["addr"], d["model"], cur, exp)
        if d["dev"]["cur_w"] < d["exp_w"]:
            bad_w.append(d)
            lines.append("[%s] %s" % ("WARNING" if args.width_warn else "CRITICAL", desc))
        elif (not args.ignore_speed and d["exp_s"] and d["dev"]["cur_s"]
              and d["dev"]["cur_s"] < d["exp_s"]):
            bad_s.append(d)
            lines.append("[WARNING] %s" % desc)
        elif args.verbose:
            lines.append("[OK] %s" % desc)

    if bad_w:
        rc = max(rc, N_WARN if args.width_warn else N_CRIT)
    if bad_s or unknown:
        rc = max(rc, N_WARN)
    if args.min_drives and len(drives) < args.min_drives:
        rc = N_CRIT

    def short(lst):
        return ", ".join("%s x%s/x%s" % (d["name"], d["dev"]["cur_w"], d["exp_w"]) for d in lst)

    parts = []
    if bad_w:
        parts.append("%d with fewer PCIe lanes: %s" % (len(bad_w), short(bad_w)))
    if bad_s:
        parts.append("%d with lower PCIe speed: %s" % (
            len(bad_s), ", ".join("%s %s/%s" % (d["name"], fmt(d["dev"]["cur_s"], d["dev"]["cur_w"]),
                                                fmt(d["exp_s"], d["exp_w"])) for d in bad_s)))
    if unknown:
        parts.append("%d unreadable: %s" % (len(unknown), ", ".join(d["name"] for d in unknown)))
    if args.min_drives and len(drives) < args.min_drives:
        parts.append("only %d NVMe drives, expected >= %d" % (len(drives), args.min_drives))
    if not parts:
        parts.append("all %d NVMe drives at full PCIe link" % len(drives))

    perf = "drives=%d;;%s degraded_width=%d degraded_speed=%d" % (
        len(drives), args.min_drives or "", len(bad_w), len(bad_s))
    print("%s - %s | %s" % (STATUS[rc], "; ".join(parts), perf))
    if lines:
        print("\n".join(lines))
    return rc


if __name__ == "__main__":
    sys.exit(main())
