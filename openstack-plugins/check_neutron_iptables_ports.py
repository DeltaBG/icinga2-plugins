#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Nagios/Icinga plugin: checks that every port of a running VM on a compute
node has its iptables rules (neutron OVSHybridIptablesFirewallDriver).

How it works (one call per data source, no API requests):
  1. ovs-vsctl list Port      -> all qvo<id> ports on br-int + VLAN tag
  2. ovs-vsctl list Interface -> port id / vm uuid for each qvo
  3. iptables-save -t filter  -> which neutron-openvswi-i/o<id> chains exist
  4. /sys/class/net/tap<id>   -> whether the VM is running (tap exists)

For every qvo port with an existing tap:
  - no VLAN tag or tag=4095 (dead VLAN)           -> CRITICAL
    (the agent never processed the port)
  - no iptables chain (i/o) for the port          -> CRITICAL
    unless port security is disabled on the port; this is checked only for
    the problematic ports, by grepping the agent log. If it cannot be
    determined                                    -> WARNING
    Ports found without port security are stored in the --cache file, so
    the check does not depend on log rotation.

Ports without a tap (stopped VMs) are skipped.

Usage (root is required for iptables-save and docker exec):
  sudo /usr/lib/nagios/plugins/check_neutron_iptables_ports.py

Output: standard Nagios status + perfdata ports/bad/nosec/unknown.
"""

import argparse
import os
import re
import subprocess
import sys

N_OK, N_WARN, N_CRIT, N_UNK = 0, 1, 2, 3
STATUS = {N_OK: "OK", N_WARN: "WARNING", N_CRIT: "CRITICAL", N_UNK: "UNKNOWN"}

AGENT_LOGS = [
    "/var/log/kolla/neutron/neutron-openvswitch-agent.log",
    "/var/log/kolla/neutron/neutron-openvswitch-agent.log.1",
]


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


def port_security_from_logs(port_ids, logs):
    """Return {port_id: True/False} for the ports found in the agent log.
    Reads the logs once and looks only for the given ids."""
    found = {}
    pat = re.compile(r"Port ([0-9a-f-]{36}) updated\. Details: .*?"
                     r"'port_security_enabled': (True|False)")
    wanted = set(port_ids)
    # from the older to the newer log, the last occurrence wins
    for path in reversed(logs):
        try:
            with open(path, "r", errors="ignore") as f:
                for line in f:
                    if "port_security_enabled" not in line:
                        continue
                    m = pat.search(line)
                    if m and m.group(1) in wanted:
                        found[m.group(1)] = (m.group(2) == "True")
        except OSError:
            continue
    return found


def load_cache(path):
    try:
        with open(path) as f:
            return set(f.read().split())
    except OSError:
        return set()


def save_cache(path, port_ids):
    """Keep only the current ports without port security (old ones drop out)."""
    try:
        tmp = path + ".tmp"
        with open(tmp, "w") as f:
            f.write("\n".join(sorted(port_ids)) + "\n")
        os.replace(tmp, path)
    except OSError:
        pass


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--container", default="openvswitch_vswitchd",
                    help="container with ovs-vsctl ('' = ovs-vsctl on the host)")
    ap.add_argument("--bridge", default="br-int")
    ap.add_argument("--timeout", type=int, default=30)
    ap.add_argument("--max-list", type=int, default=5,
                    help="how many problematic ports to list in the output")
    ap.add_argument("--cache", default="/var/tmp/check_neutron_iptables_ports.nosec",
                    help="file with port ids without port security")
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

        # 3. iptables chains (names are truncated to the first 10 chars of the port id)
        chains = set(re.findall(r"^:neutron-openvswi-([io][0-9a-f-]{10})\s",
                                run(["iptables-save", "-t", "filter"], args.timeout),
                                re.M))
    except subprocess.TimeoutExpired:
        print("UNKNOWN - timeout while collecting data")
        return N_UNK
    except (RuntimeError, OSError) as e:
        print("UNKNOWN - %s" % e)
        return N_UNK

    total, no_vlan, no_ipt = 0, [], []
    for qvo, tag in tags.items():
        dev = qvo[3:]                       # e.g. 1a2b3c4d-5e
        if not os.path.exists("/sys/class/net/tap" + dev):
            continue                        # VM is not running
        total += 1
        pid, vm = meta.get(qvo, ("?", "?"))
        if tag in ("", "4095"):
            no_vlan.append((qvo, pid, vm))
            continue
        short = dev[:10]
        if ("i" + short) not in chains or ("o" + short) not in chains:
            no_ipt.append((qvo, pid, vm))

    # Port security is checked only for the problematic ports.
    # The cache keeps ports without port security, so we don't depend on log rotation.
    crit, warn, nosec = list(no_vlan), [], 0
    if no_ipt:
        cache = load_cache(args.cache)
        ids = [p for _, p, _ in no_ipt]
        psec = {p: False for p in ids if p in cache}
        psec.update(port_security_from_logs([p for p in ids if p not in cache], AGENT_LOGS))
        save_cache(args.cache, {p for p, v in psec.items() if v is False})
        for item in no_ipt:
            state = psec.get(item[1])
            if state is False:
                nosec += 1
            elif state is True:
                crit.append(item)
            else:
                warn.append(item)

    def fmt(items, why):
        out = ["%s(port=%s vm=%s)" % (why, p, v) for _, p, v in items[:args.max_list]]
        if len(items) > args.max_list:
            out.append("... +%d" % (len(items) - args.max_list))
        return out

    details = []
    if no_vlan:
        details += fmt(no_vlan, "no-vlan")
    if [c for c in crit if c not in no_vlan]:
        details += fmt([c for c in crit if c not in no_vlan], "no-iptables")
    if warn:
        details += fmt(warn, "no-iptables-portsec-unknown")

    code = N_CRIT if crit else (N_WARN if warn else N_OK)
    perf = "ports=%d bad=%d;;1 nosec=%d unknown=%d;1" % (total, len(crit), nosec, len(warn))
    if code == N_OK:
        msg = "%d VM ports OK (%d without port security)" % (total, nosec)
    else:
        msg = "%d/%d VM ports broken: %s" % (len(crit) + len(warn), total, "; ".join(details))
    print("%s - %s | %s" % (STATUS[code], msg, perf))
    return code


if __name__ == "__main__":
    sys.exit(main())
