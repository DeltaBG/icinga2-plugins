#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Nagios/Icinga plugin: checks that every port of a running VM on a compute
node has its iptables rules (neutron OVSHybridIptablesFirewallDriver).

How it works (one call per data source, no API requests):
  1. ovs-vsctl list Port      -> all qvo<id> ports on br-int + VLAN tag
  2. ovs-vsctl list Interface -> port id / vm uuid for each qvo
  3. iptables-save -t filter  -> which neutron-openvswi-i/o<id> chains exist,
                                 and which taps have the "port security is
                                 disabled" ACCEPT rules
  4. /sys/class/net/tap<id>   -> whether the VM is running (tap exists)

For every qvo port with an existing tap:
  - no VLAN tag or tag=4095 (dead VLAN)             -> CRITICAL
    (the agent never processed the port)
  - per-port i/o chains exist                       -> OK
  - no chains, but "Accept all packets when port
    security is disabled." rules for the tap exist  -> OK (counted as nosec)
  - neither                                         -> CRITICAL

Ports without a tap (stopped VMs) are skipped.

Usage (root is required for iptables-save and docker exec):
  sudo /usr/lib/nagios/plugins/check_neutron_iptables_ports.py

Output: standard Nagios status + perfdata ports/bad/nosec.
"""

import argparse
import os
import re
import subprocess
import sys

N_OK, N_WARN, N_CRIT, N_UNK = 0, 1, 2, 3
STATUS = {N_OK: "OK", N_WARN: "WARNING", N_CRIT: "CRITICAL", N_UNK: "UNKNOWN"}

# Rule comment neutron uses for ports with port_security_enabled=False
NOSEC_RE = re.compile(r"--physdev-(?:in|out) tap([0-9a-f-]{11})\b.*"
                      r"port security is disabled", re.M)
CHAIN_RE = re.compile(r"^:neutron-openvswi-([io][0-9a-f-]{10})\s", re.M)


def run(cmd, timeout):
    res = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                         timeout=timeout, check=False)
    if res.returncode != 0:
        raise RuntimeError("%s: %s" % (" ".join(cmd[:4]),
                                       res.stderr.decode(errors="ignore").strip()[:200]))
    return res.stdout.decode(errors="ignore")


def ovs(args, container, timeout):
    base = ["ovs-vsctl", "--format=csv", "--data=bare", "--no-headings"]
    if container:
        base = ["docker", "exec", container] + base
    return run(base + args, timeout)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--container", default="openvswitch_vswitchd",
                    help="container with ovs-vsctl ('' = ovs-vsctl on the host)")
    ap.add_argument("--bridge", default="br-int")
    ap.add_argument("--timeout", type=int, default=30)
    ap.add_argument("--max-list", type=int, default=5,
                    help="how many problematic ports to list in the output")
    ap.add_argument("--cache", help=argparse.SUPPRESS)  # deprecated, ignored
    args = ap.parse_args()

    try:
        # 1. qvo ports on br-int
        br_ports = set(ovs(["list-ports", args.bridge], args.container, args.timeout).split())
        tags = {}
        for line in ovs(["--columns=name,tag", "list", "Port"], args.container,
                        args.timeout).splitlines():
            name, _, tag = line.partition(",")
            if name.startswith("qvo") and name in br_ports:
                tags[name] = tag.strip()

        # 2. port id / vm uuid
        meta = {}
        for line in ovs(["--columns=name,external_ids", "list", "Interface"],
                        args.container, args.timeout).splitlines():
            name, _, ext = line.partition(",")
            if name in tags:
                kv = dict(x.split("=", 1) for x in ext.split() if "=" in x)
                meta[name] = (kv.get("iface-id", "?"), kv.get("vm-uuid", "?"))

        # 3. iptables: per-port chains (names truncated to the first 10 chars
        #    of the port id) and taps with port security disabled
        ipt = run(["iptables-save", "-t", "filter"], args.timeout)
        chains = set(CHAIN_RE.findall(ipt))
        nosec_devs = set(NOSEC_RE.findall(ipt))
    except subprocess.TimeoutExpired:
        print("UNKNOWN - timeout while collecting data")
        return N_UNK
    except (RuntimeError, OSError) as e:
        print("UNKNOWN - %s" % e)
        return N_UNK

    total, nosec, no_vlan, no_ipt = 0, 0, [], []
    for qvo, tag in tags.items():
        dev = qvo[3:]                       # e.g. 1a2b3c4d-5e
        if not os.path.exists("/sys/class/net/tap" + dev):
            continue                        # VM is not running
        total += 1
        pid, vm = meta.get(qvo, ("?", "?"))
        if tag in ("", "4095"):
            no_vlan.append((pid, vm))
            continue
        short = dev[:10]
        if ("i" + short) in chains and ("o" + short) in chains:
            continue
        if dev in nosec_devs:
            nosec += 1
        else:
            no_ipt.append((pid, vm))

    def fmt(items, why):
        out = ["%s(port=%s vm=%s)" % (why, p, v) for p, v in items[:args.max_list]]
        if len(items) > args.max_list:
            out.append("... +%d" % (len(items) - args.max_list))
        return out

    bad = len(no_vlan) + len(no_ipt)
    perf = "ports=%d bad=%d;;1 nosec=%d" % (total, bad, nosec)
    if not bad:
        print("OK - %d VM ports OK (%d without port security) | %s" % (total, nosec, perf))
        return N_OK
    details = fmt(no_vlan, "no-vlan") + fmt(no_ipt, "no-iptables")
    print("CRITICAL - %d/%d VM ports broken: %s | %s"
          % (bad, total, "; ".join(details), perf))
    return N_CRIT


if __name__ == "__main__":
    sys.exit(main())
