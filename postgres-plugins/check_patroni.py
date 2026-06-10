#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
check_patroni - Nagios/Icinga2 plugin for monitoring a Patroni cluster.

Queries the Patroni REST API '/cluster' endpoint (any reachable node returns
the full topology) and evaluates overall cluster health:

  * Presence of exactly one leader (CRITICAL if none -> no failover target).
  * Split-brain detection (more than one leader / standby_leader).
  * Member states (running / streaming vs. stopped / crashed / starting).
  * Replication lag against WARNING / CRITICAL byte thresholds.
  * Minimum number of healthy replicas (redundancy).
  * Patroni maintenance/pause mode (autofailover disabled).

Exit codes follow the Nagios plugin API: 0=OK 1=WARNING 2=CRITICAL 3=UNKNOWN
Only the Python 3 standard library is used (no external dependencies).
"""

import sys
import json
import argparse
import urllib.request
import urllib.error
import ssl
import base64

OK, WARNING, CRITICAL, UNKNOWN = 0, 1, 2, 3
STATUS_TEXT = {OK: "OK", WARNING: "WARNING", CRITICAL: "CRITICAL", UNKNOWN: "UNKNOWN"}

# Member states considered healthy / online.
HEALTHY_STATES = {"running", "streaming"}
# Transient states -> WARNING (node is moving, not yet broken).
TRANSIENT_STATES = {"starting", "stopping", "restarting", "creating replica",
                    "initializing new cluster", "in archive recovery"}
# Roles that satisfy the "has leader" requirement.
LEADER_ROLES = {"leader", "standby_leader"}


def parse_args():
    p = argparse.ArgumentParser(
        prog="check_patroni",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        description="Nagios/Icinga2 plugin: monitor overall Patroni cluster "
                    "health and detect a missing/duplicate leader.",
        epilog="""\
Exit codes:
  0 OK        1 WARNING        2 CRITICAL       3 UNKNOWN

Examples:
  # Basic check against a node's Patroni API (default port 8008)
  ./check_patroni.py -H 10.0.0.11

  # Through a VIP / HAProxy, require at least 1 healthy replica
  ./check_patroni.py -H pg-vip.internal --min-replicas 1

  # Custom lag thresholds (warn 5 MiB, crit 50 MiB) with REST basic auth
  ./check_patroni.py -H 10.0.0.11 --lag-warning 5242880 --lag-critical 52428800 \\
      -u monitor --password secret

  # HTTPS API with self-signed certificate
  ./check_patroni.py -H 10.0.0.11 -S https -k

Note: /cluster returns the full topology, so the plugin can be pointed at any
single node, a VIP, or HAProxy. Pointing it at one fixed node only fails the
check if that exact node's REST API is unreachable.
""")

    p.add_argument("-H", "--host", required=True,
                   help="Patroni node hostname or IP (or VIP/HAProxy).")
    p.add_argument("-p", "--port", type=int, default=8008,
                   help="Patroni REST API port (default: 8008).")
    p.add_argument("-S", "--scheme", choices=["http", "https"], default="http",
                   help="REST API scheme (default: http).")
    p.add_argument("-t", "--timeout", type=float, default=10.0,
                   help="Connection/read timeout in seconds (default: 10).")

    p.add_argument("-u", "--user", default=None,
                   help="Username for Patroni REST basic auth (optional).")
    p.add_argument("--password", default=None,
                   help="Password for Patroni REST basic auth (optional).")
    p.add_argument("-k", "--insecure", action="store_true",
                   help="Do not verify TLS certificate (self-signed certs).")

    p.add_argument("--lag-warning", type=int, default=1048576,
                   help="Replication lag WARNING threshold in bytes "
                        "(default: 1048576 = 1 MiB).")
    p.add_argument("--lag-critical", type=int, default=10485760,
                   help="Replication lag CRITICAL threshold in bytes "
                        "(default: 10485760 = 10 MiB).")

    p.add_argument("--min-replicas", type=int, default=0,
                   help="Minimum number of healthy replicas expected. "
                        "Below this -> WARNING (default: 0 = disabled).")
    p.add_argument("--pause-ok", action="store_true",
                   help="Treat Patroni maintenance/pause mode as OK instead "
                        "of WARNING.")
    p.add_argument("-v", "--verbose", action="store_true",
                   help="Append a per-member breakdown to the output.")
    return p.parse_args()


def fetch_cluster(args):
    url = "%s://%s:%d/cluster" % (args.scheme, args.host, args.port)
    req = urllib.request.Request(url, headers={"Accept": "application/json"})

    if args.user is not None and args.password is not None:
        token = base64.b64encode(
            ("%s:%s" % (args.user, args.password)).encode()).decode()
        req.add_header("Authorization", "Basic %s" % token)

    ctx = None
    if args.scheme == "https":
        ctx = ssl.create_default_context()
        if args.insecure:
            ctx.check_hostname = False
            ctx.verify_mode = ssl.CERT_NONE

    try:
        with urllib.request.urlopen(req, timeout=args.timeout, context=ctx) as r:
            return json.loads(r.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        # 503 from Patroni health endpoints can be normal, but /cluster should
        # answer 200; any HTTP error here means we cannot read the topology.
        finish(CRITICAL, "Patroni API HTTP %d from %s" % (e.code, url))
    except urllib.error.URLError as e:
        finish(CRITICAL, "Cannot reach Patroni API at %s (%s)" % (url, e.reason))
    except (ValueError, OSError) as e:
        finish(UNKNOWN, "Invalid response from %s (%s)" % (url, e))


def human_bytes(n):
    if n is None:
        return "unknown"
    units = ["B", "KiB", "MiB", "GiB", "TiB"]
    f = float(n)
    for u in units:
        if f < 1024.0 or u == units[-1]:
            return "%.0f%s" % (f, u) if u == "B" else "%.1f%s" % (f, u)
        f /= 1024.0


def finish(code, summary, perfdata=None, detail=None):
    line = "PATRONI %s - %s" % (STATUS_TEXT[code], summary)
    if perfdata:
        line += " | " + " ".join(perfdata)
    print(line)
    if detail:
        print("\n".join(detail))
    sys.exit(code)


def main():
    args = parse_args()

    if args.lag_critical < args.lag_warning:
        finish(UNKNOWN, "--lag-critical must be >= --lag-warning")

    data = fetch_cluster(args)
    members = data.get("members", [])
    if not members:
        finish(CRITICAL, "Cluster reports no members")

    leaders, replicas, problems = [], [], []
    worst = OK
    max_lag = 0
    healthy_replicas = 0

    for m in members:
        role = (m.get("role") or "").lower()
        state = (m.get("state") or "").lower()
        name = m.get("name", "?")

        if role in LEADER_ROLES:
            leaders.append(m)
            if state not in HEALTHY_STATES:
                worst = max(worst, CRITICAL)
                problems.append("leader %s state=%s" % (name, state or "?"))
            continue

        # Anything else is a follower (replica / sync_standby).
        replicas.append(m)
        if state in HEALTHY_STATES:
            healthy_replicas += 1
        elif state in TRANSIENT_STATES:
            worst = max(worst, WARNING)
            problems.append("%s state=%s" % (name, state or "?"))
        else:
            worst = max(worst, CRITICAL)
            problems.append("%s state=%s" % (name, state or "?"))

        # Replication lag (can be an int in bytes, or "unknown").
        lag = m.get("lag")
        if lag == "unknown" or lag is None:
            worst = max(worst, WARNING)
            problems.append("%s lag=unknown" % name)
        else:
            try:
                lag = int(lag)
                max_lag = max(max_lag, lag)
                if lag >= args.lag_critical:
                    worst = max(worst, CRITICAL)
                    problems.append("%s lag=%s" % (name, human_bytes(lag)))
                elif lag >= args.lag_warning:
                    worst = max(worst, WARNING)
                    problems.append("%s lag=%s" % (name, human_bytes(lag)))
            except (TypeError, ValueError):
                worst = max(worst, WARNING)
                problems.append("%s lag=%r" % (name, lag))

    # --- Leader / split-brain checks (the core of the request) ---
    if len(leaders) == 0:
        worst = CRITICAL
        problems.insert(0, "NO LEADER in cluster")
    elif len(leaders) > 1:
        worst = CRITICAL
        problems.insert(0, "SPLIT-BRAIN: %d leaders (%s)"
                        % (len(leaders), ", ".join(l.get("name", "?")
                                                   for l in leaders)))

    # --- Minimum replica redundancy ---
    if args.min_replicas > 0 and healthy_replicas < args.min_replicas:
        worst = max(worst, WARNING)
        problems.append("only %d/%d healthy replicas"
                        % (healthy_replicas, args.min_replicas))

    # --- Maintenance / pause mode ---
    if data.get("pause"):
        if not args.pause_ok:
            worst = max(worst, WARNING)
        problems.append("cluster PAUSED (autofailover disabled)")

    # --- Build summary ---
    leader_name = leaders[0].get("name") if leaders else "NONE"
    if worst == OK:
        summary = ("cluster healthy: leader=%s, %d/%d members running, "
                   "max lag=%s"
                   % (leader_name, healthy_replicas + len(leaders),
                      len(members), human_bytes(max_lag)))
    else:
        summary = ("leader=%s, %d members; issues: %s"
                   % (leader_name, len(members), "; ".join(problems)))

    perfdata = [
        "members=%d" % len(members),
        "replicas=%d" % len(replicas),
        "healthy_replicas=%d" % healthy_replicas,
        "leaders=%d" % len(leaders),
        "max_lag=%dB;%d;%d;0" % (max_lag, args.lag_warning, args.lag_critical),
    ]

    detail = None
    if args.verbose:
        detail = []
        for m in members:
            detail.append("  %-20s role=%-13s state=%-10s lag=%s"
                          % (m.get("name", "?"),
                             m.get("role", "?"),
                             m.get("state", "?"),
                             human_bytes(m.get("lag"))
                             if isinstance(m.get("lag"), int)
                             else m.get("lag", "n/a")))

    finish(worst, summary, perfdata, detail)


if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except Exception as e:  # noqa: BLE001 - last resort for Nagios safety
        print("PATRONI UNKNOWN - unexpected error: %s" % e)
        sys.exit(UNKNOWN)
