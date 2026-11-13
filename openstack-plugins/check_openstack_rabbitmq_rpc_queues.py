#!/usr/bin/python3
# -*- coding: UTF-8 -*-
# OpenStack RPC queues in RabbitMQ: reply, host, fanout.

import sys
sys.dont_write_bytecode = True

import argparse
import re
import subprocess
from typing import Callable, Dict, List, Optional, Sequence, Tuple

OK, WARNING, CRITICAL, UNKNOWN = 0, 1, 2, 3
STATE_NAMES = {OK: 'OK', WARNING: 'WARNING', CRITICAL: 'CRITICAL', UNKNOWN: 'UNKNOWN'}

# name -> (rabbitmqctl args, accepts -p vhost); info key "node" is not supported
COMMANDS = {
    'connections': (['list_connections', 'pid', 'peer_host', 'client_properties'], False),
    'channels': (['list_channels', 'pid', 'connection'], False),
    'queues': (['list_queues', 'name', 'state', 'messages', 'consumers'], True),
    'consumers': (['list_consumers', 'queue_name', 'channel_pid'], True),
}
# 3.13 prints a column header even with -q
HEADERS = dict((a[0], a[1:]) for a, _ in COMMANDS.values())
ABBREV = {'nova-compute': 'nova', 'neutron-openvswitch-agent': 'ovs'}

RE_CONNNAME = re.compile(r'connection_name","([^"]*)"')
RE_FANOUT = re.compile(r'_fanout_[0-9a-f]+$')
DEFAULT_TOPICS = 'compute,neutron-vo-,q-agent-notifier-'
KINDS = ('reply', 'host', 'fanout')
DEFAULT_HOST_REGEX = r'\.compute-[0-9]+\.'


class CheckError(Exception):
    """Any failure that maps to UNKNOWN."""


class Proc(object):
    def __init__(self, ip: str, name: str, host: str) -> None:
        self.ip = ip
        self.name = name
        self.host = host
        self.noproc = False
        self.reply = ''
        self.reply_ok = False
        self.stopped_reply = ''
        self.missing_fanout = []  # type: List[str]
        self.host_queues = []  # type: List[Tuple[str, int]]

    @property
    def status(self) -> str:
        if self.noproc:
            return 'NO-PROCESS'
        if self.reply_ok:
            return 'OK ' + self.reply
        if self.stopped_reply:
            return 'STOPPED ' + self.stopped_reply
        return 'NO-REPLY'

    @property
    def msgs(self) -> int:
        return sum(m for _, m in self.host_queues)


# ---------- data source ----------

def run_rabbitmqctl(container: str, args: List[str], timeout: float,
                    runner: Callable = subprocess.run) -> str:
    cmd = ['docker', 'exec', container, 'rabbitmqctl', '-q'] + args
    try:
        res = runner(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                     universal_newlines=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        raise CheckError('timeout after %ss: %s' % (timeout, ' '.join(cmd[3:])))
    except OSError as exc:
        raise CheckError('cannot run docker: %s' % exc)
    if res.returncode != 0:
        err = (res.stderr or res.stdout or '').strip().splitlines()
        raise CheckError('%s failed rc=%s: %s' % ('rabbitmqctl ' + args[0], res.returncode,
                                                  err[0][:150] if err else 'no output'))
    return res.stdout


def command_args(name: str, vhost: str) -> List[str]:
    args, scoped = COMMANDS[name]
    return args[:1] + (['-p', vhost] if scoped else []) + args[1:]


def fetch_all(container: str, timeout: float, names: Sequence[str], vhost: str = '/',
              runner: Callable = subprocess.run) -> Dict[str, str]:
    return dict((n, run_rabbitmqctl(container, command_args(n, vhost), timeout, runner))
                for n in names)


# ---------- parsing ----------

def rows(text: str, name: str, ncols: int, pid_cols: Tuple[int, ...] = ()) -> List[List[str]]:
    out = []
    for line in text.splitlines():
        if not line.strip():
            continue
        cols = line.split('\t')
        if cols == HEADERS.get(name):
            continue
        if len(cols) < ncols:
            cols += [''] * (ncols - len(cols))
        for i in pid_cols:
            if not cols[i].startswith('<'):
                raise CheckError('cannot parse %s output: %r' % (name, line[:80]))
        out.append(cols)
    if not out:
        raise CheckError('empty %s output' % name)
    return out


def natkey(s: str) -> List:
    return [int(p) if p.isdigit() else p for p in re.split(r'(\d+)', s)]


def to_int(s: str) -> int:
    try:
        return int(s)
    except ValueError:
        return 0


# ---------- logic ----------

def compile_host_regex(pattern: str) -> 're.Pattern':
    try:
        return re.compile(pattern)
    except re.error as exc:
        raise CheckError('bad --host-regex %r: %s' % (pattern, exc))


def parse_topics(text: str) -> Tuple[str, ...]:
    topics = tuple(t.strip() for t in text.split(',') if t.strip())
    if not topics:
        raise CheckError('--topics is empty')
    return topics


def analyze(data: Dict[str, str], ignore_hosts: Tuple[str, ...] = (),
            fanout_warn: bool = True, host_re: Optional['re.Pattern'] = None,
            topic_prefixes: Optional[Tuple[str, ...]] = None) -> List[Proc]:
    host_re = host_re or re.compile(DEFAULT_HOST_REGEX)
    topic_prefixes = topic_prefixes or parse_topics(DEFAULT_TOPICS)
    conn = {}  # type: Dict[str, str]
    proc = {}  # type: Dict[str, str]
    for pid, ip, props in rows(data['connections'], 'list_connections', 3, (0,)):
        m = RE_CONNNAME.search(props)
        parts = (m.group(1) if m else '').split(':')
        conn[pid] = ip
        proc[pid] = parts[0] + ':' + (parts[1] if len(parts) > 1 else '')
    chan = dict((c[0], c[1]) for c in rows(data['channels'], 'list_channels', 2, (0, 1)))

    state = {}  # type: Dict[str, str]
    zq = {}  # type: Dict[str, str]
    for name, st, msgs, cons in rows(data['queues'], 'list_queues', 4):
        state[name] = st
        if host_re.search(name) and cons == '0':
            zq[name] = msgs

    procs = {}  # type: Dict[Tuple[str, str], Proc]
    host = {}  # type: Dict[str, str]
    ipof = {}  # type: Dict[str, str]
    elsewhere = {}  # type: Dict[str, str]
    topics = {}  # type: Dict[Tuple[Tuple[str, str], str], bool]
    fans = {}  # type: Dict[Tuple[Tuple[str, str], str], bool]
    for queue, chpid in rows(data['consumers'], 'list_consumers', 2, (1,)):
        c = chan.get(chpid, '')
        ip = conn.get(c, '')
        if not ip:
            continue
        k = (ip, proc[c])
        p = procs.setdefault(k, Proc(ip, proc[c], ''))
        m = host_re.search(queue)
        if m:
            n = m.group(0).strip('.')
            host[ip] = n
            ipof[n] = ip
            elsewhere[queue[:m.start()]] = proc[c]
        if queue.startswith('reply_'):
            if state.get(queue) == 'running':
                p.reply, p.reply_ok = queue, True
            else:
                p.stopped_reply = queue
        elif RE_FANOUT.search(queue):
            fans[(k, RE_FANOUT.sub('', queue))] = True
        elif not m and queue.startswith(topic_prefixes):
            topics[(k, queue)] = True

    for (k, topic) in topics:
        if (k, topic) not in fans:
            procs[k].missing_fanout.append(topic)

    for q in sorted(zq):
        m = host_re.search(q)
        n = m.group(0).strip('.')
        t = q[:m.start()]
        if t not in elsewhere or n not in ipof:
            continue
        k = (ipof[n], elsewhere[t])
        if k not in procs:
            procs[k] = Proc(k[0], k[1], '')
            procs[k].noproc = True
        procs[k].host_queues.append((t, to_int(zq[q])))

    result = []
    for k, p in procs.items():
        p.host = host.get(p.ip, '-')
        if p.host == '-' or p.host in ignore_hosts:
            continue
        if not fanout_warn:
            p.missing_fanout = []
        result.append(p)
    return result


TABLE_HEAD = ('HOST', 'PROC', 'IP', 'PROBLEM', 'DETAIL')


def table_rows(p: Proc, show_ok: bool = False) -> List[Tuple[str, str, str, str, str]]:
    rows = []  # type: List[Tuple[str, str]]
    if p.noproc:
        rows.append(('NO-PROCESS', ''))
    elif p.status == 'NO-REPLY':
        rows.append(('NO-REPLY', ''))
    elif p.status.startswith('STOPPED'):
        rows.append(('STOPPED', p.stopped_reply))
    elif show_ok and not (p.host_queues or p.missing_fanout):
        rows.append(('OK', p.reply))
    # lists go one item per line
    if p.host_queues:
        rows.append(('HOST-QUEUE', '\n'.join('%s (%d msgs)' % (t, m) for t, m in p.host_queues)))
    if p.missing_fanout:
        rows.append(('NO-FANOUT', '\n'.join(sorted(p.missing_fanout))))
    return [(p.host, abbrev(p), p.ip, prob, det) for prob, det in rows]


def render_table(rows: List[Tuple[str, ...]]) -> List[str]:
    # prettytable-style box, stdlib only; multi-line cells split on "\n"
    if not rows:
        return []
    head = ('#',) + TABLE_HEAD
    body = [(str(i),) + tuple(r) for i, r in enumerate(rows, 1)]
    cells = [[c.split('\n') for c in r] for r in [head] + body]
    w = [max(len(x) for r in cells for x in r[i]) for i in range(len(head))]
    sep = '+' + '+'.join('-' * (x + 2) for x in w) + '+'
    multi = any(len(c) > 1 for r in cells for c in r)

    def fmt(r):
        out = []
        for k in range(max(len(c) for c in r)):
            out.append('|' + '|'.join(' %s ' % (c[k] if k < len(c) else '').center(w[i])
                                      for i, c in enumerate(r)) + '|')
        return out
    lines = [sep] + fmt(cells[0]) + [sep]
    for n, r in enumerate(cells[1:]):
        if multi and n:
            lines.append(sep)
        lines += fmt(r)
    return lines + [sep]


def is_problem(p: Proc) -> bool:
    return (not p.status.startswith('OK')) or bool(p.missing_fanout) or bool(p.host_queues)


def sort_key(p: Proc) -> Tuple:
    return (natkey(p.host), p.name, p.ip)


# ---------- report ----------

def abbrev(p: Proc) -> str:
    base = p.name.split(':')[0]
    return ABBREV.get(base, base)


def category(procs: List[Proc], label: str, with_msgs: bool, limit: int) -> str:
    seen = []  # type: List[str]
    for p in procs:
        e = '%s/%s' % (p.host, abbrev(p))
        if with_msgs and p.msgs > 0:
            e += '(%d msgs)' % p.msgs
        if e not in seen:
            seen.append(e)
    shown = seen[:limit]
    s = '%s: %s' % (label, ', '.join(shown))
    if len(seen) > limit:
        s += ' +%d more' % (len(seen) - limit)
    return s


def evaluate(procs: List[Proc], limit: int = 10, verbose: bool = False,
             show_all: bool = False) -> Tuple[int, str, str, List[str]]:
    procs = sorted(procs, key=sort_key)
    real = [p for p in procs if not p.noproc]
    no_reply = [p for p in real if p.status == 'NO-REPLY']
    stopped = [p for p in real if p.status.startswith('STOPPED')]
    hostq = [p for p in procs if p.host_queues]
    nofan = [p for p in procs if p.missing_fanout]
    hq_msgs = sum(p.msgs for p in hostq)
    hq_cnt = sum(len(p.host_queues) for p in hostq)

    if no_reply or hq_msgs > 0:
        code = CRITICAL
    elif stopped or hostq or nofan:
        code = WARNING
    else:
        code = OK

    cats = []
    for lst, label, wm in ((no_reply, 'NO-REPLY', False), (stopped, 'STOPPED', False),
                           (hostq, 'HOST-QUEUE', True), (nofan, 'NO-FANOUT', False)):
        if lst:
            cats.append(category(lst, label, wm, limit))
    if cats:
        summary = '; '.join(cats)
    else:
        hosts = len(set(p.host for p in real))
        summary = '%d processes on %d compute hosts: reply, host and fanout queues present' % (
            len(real), hosts)
    perf = ('no_reply=%d stopped_reply=%d host_queue_unconsumed=%d host_queue_msgs=%d '
            'no_fanout=%d processes=%d' % (len(no_reply), len(stopped), hq_cnt, hq_msgs,
                                          len(nofan), len(real)))
    lines = []
    if verbose or show_all:
        lines = render_table([r for p in procs if show_all or is_problem(p)
                              for r in table_rows(p, show_all)])
    return code, summary, perf, lines


# ---------- rpc check ----------

def add_rpc_args(g) -> None:
    g.add_argument('--topics', default=DEFAULT_TOPICS,
                   help='Comma list of topic prefixes that need a fanout queue')
    g.add_argument('--host-regex', default=DEFAULT_HOST_REGEX,
                   help='Regex matching the per-host part of a queue name')
    g.add_argument('--ignore-hosts', default='', help='Comma list, e.g. compute-163,compute-278')
    g.add_argument('--queues', default=','.join(KINDS),
                   help='Queue kinds to check: reply,host,fanout (default: all)')
    g.add_argument('--max-hosts', type=int, default=10, help='Hosts listed per category')
    g.add_argument('--verbose', action='store_true', help='One line per affected process')
    g.add_argument('--all', dest='show_all', action='store_true',
                   help='One line per checked process (implies --verbose)')


def rpc_evaluate(data: Dict[str, str], args: argparse.Namespace) -> Tuple[int, str, str, List[str]]:
    host_re = compile_host_regex(args.host_regex)
    topics = parse_topics(args.topics)
    ignore = tuple(h.strip() for h in args.ignore_hosts.split(',') if h.strip())
    kinds = parse_kinds(args.queues)
    procs = analyze(data, ignore, 'fanout' in kinds, host_re, topics)
    procs = filter_kinds(procs, kinds)
    code, summary, perf, lines = evaluate(procs, args.max_hosts, args.verbose, args.show_all)
    if code == OK and kinds != set(KINDS):
        summary = summary.replace('reply, host and fanout queues',
                                  ', '.join(k for k in KINDS if k in kinds) + ' queues')
    return code, summary, perf, lines


def parse_kinds(value: str) -> set:
    kinds = set(k.strip() for k in value.split(',') if k.strip())
    bad = kinds - set(KINDS)
    if not kinds or bad:
        raise CheckError('--queues takes %s, got %r' % (','.join(KINDS), value))
    return kinds


def filter_kinds(procs: List[Proc], kinds: set) -> List[Proc]:
    out = []
    for p in procs:
        if 'host' not in kinds:
            if p.noproc:
                continue
            p.host_queues = []
        if 'reply' not in kinds and not p.noproc:
            p.reply_ok, p.reply = True, p.reply or '-'
        out.append(p)
    return out


# ---------- CLI ----------

class Parser(argparse.ArgumentParser):
    def error(self, message: str) -> None:
        print('UNKNOWN - usage: %s' % message)
        sys.exit(UNKNOWN)


def build_parser() -> argparse.ArgumentParser:
    p = Parser(description='OpenStack RPC queues in RabbitMQ: reply, host, fanout (read-only)',
               formatter_class=argparse.ArgumentDefaultsHelpFormatter, allow_abbrev=False)
    p.add_argument('--container', default='rabbitmq', help='RabbitMQ container name')
    p.add_argument('--vhost', default='/', help='Vhost for list_queues/list_consumers (-p)')
    p.add_argument('--timeout', type=float, default=20, help='Per rabbitmqctl call, seconds')
    add_rpc_args(p)
    return p


def run_check(args: argparse.Namespace,
              fetch: Callable[[Sequence[str]], Dict[str, str]]) -> Tuple[int, str]:
    try:
        code, summary, perf, lines = rpc_evaluate(fetch(list(COMMANDS)), args)
    except CheckError as exc:
        return UNKNOWN, 'UNKNOWN - %s' % exc
    head = '%s - %s | %s' % (STATE_NAMES[code], summary, perf)
    return code, '\n'.join([head] + lines)


def main(argv: Optional[List[str]] = None,
         fetch: Optional[Callable[[Sequence[str]], Dict[str, str]]] = None) -> int:
    args = build_parser().parse_args(argv)
    if fetch is None:
        def fetch(names: Sequence[str]) -> Dict[str, str]:
            return fetch_all(args.container, args.timeout, names, args.vhost)
    code, text = run_check(args, fetch)
    print(text)
    return code


if __name__ == '__main__':
    sys.exit(main())
