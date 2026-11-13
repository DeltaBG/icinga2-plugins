#!/usr/bin/env python3
# -*- coding: UTF-8 -*-

import sys
sys.dont_write_bytecode = True

import argparse
import re
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from munch import munchify, Munch
import openstack
from prettytable import PrettyTable

# Resources checked by --monitor quota. 'source' picks which per-project API call
# supplies the pair: 'compute' = Nova absolute limits, 'disk' = Cinder quota-set,
# 'network' = Neutron quota details (one call covers every network resource below).
# unit_div only affects DISPLAY (RAM comes from Nova in MB); perfdata keeps MB.
# in_default=False keeps a resource out of the default sweep but fully checkable
# via --quota-resources — see the security-group note below.
QUOTA_RESOURCES = (
    # 'vcpu' is this tool's name for it (as in --monitor cpu); 'total_cores' is Nova's.
    Munch({'key': 'vcpu', 'label': 'vcpu', 'source': 'compute', 'in_default': True,
           'quota_attr': 'total_cores', 'used_attr': 'total_cores_used', 'unit_div': 1}),
    Munch({'key': 'ram', 'label': 'ram (GB)', 'source': 'compute', 'in_default': True,
           'quota_attr': 'total_ram', 'used_attr': 'total_ram_used', 'unit_div': 1024}),
    Munch({'key': 'instances', 'label': 'instances', 'source': 'compute', 'in_default': True,
           'quota_attr': 'instances', 'used_attr': 'instances_used', 'unit_div': 1}),
    Munch({'key': 'disk', 'label': 'disk (GB)', 'source': 'disk', 'in_default': True,
           'quota_attr': 'gigabytes', 'used_attr': 'gigabytes', 'unit_div': 1}),
    # Neutron: quota_attr is the SDK attribute, whose value is a dict carrying both
    # 'limit' and 'used', so used_attr repeats it rather than naming a second field.
    Munch({'key': 'networks', 'label': 'networks', 'source': 'network', 'in_default': True,
           'quota_attr': 'networks', 'used_attr': 'networks', 'unit_div': 1}),
    Munch({'key': 'subnets', 'label': 'subnets', 'source': 'network', 'in_default': True,
           'quota_attr': 'subnets', 'used_attr': 'subnets', 'unit_div': 1}),
    Munch({'key': 'ports', 'label': 'ports', 'source': 'network', 'in_default': True,
           'quota_attr': 'ports', 'used_attr': 'ports', 'unit_div': 1}),
    Munch({'key': 'routers', 'label': 'routers', 'source': 'network', 'in_default': True,
           'quota_attr': 'routers', 'used_attr': 'routers', 'unit_div': 1}),
    Munch({'key': 'floating_ips', 'label': 'floating ips', 'source': 'network', 'in_default': True,
           'quota_attr': 'floating_ips', 'used_attr': 'floating_ips', 'unit_div': 1}),
    # Security group quota is usually a flat administrative default, never
    # provisioned to usage: out of the default sweep so it can't drown real drift.
    Munch({'key': 'security_groups', 'label': 'sec groups', 'source': 'network',
           'in_default': False, 'quota_attr': 'security_groups',
           'used_attr': 'security_groups', 'unit_div': 1}),
    Munch({'key': 'security_group_rules', 'label': 'sec group rules', 'source': 'network',
           'in_default': False, 'quota_attr': 'security_group_rules',
           'used_attr': 'security_group_rules', 'unit_div': 1}),
)


def short_host(name, keep_labels=2):
    '''
    Perfdata-safe label: first `keep_labels` dot-components, unsafe chars -> '_'.
    E.g. compute-1.zone1.example.net -> compute-1.zone1
    '''
    base = '.'.join(str(name or 'unknown').split('.')[:keep_labels])
    return re.sub(r'[^A-Za-z0-9_.-]', '_', base)


def host_key(name):
    '''
    Bare host label (first dot-component), for joining a hypervisor to the
    short-or-FQDN host lists carried on Nova aggregates.
    '''
    return str(name or '').split('.')[0]


def fmt_date(val):
    if not val:
        return ''
    try:
        dt = datetime.fromisoformat(str(val).replace('Z', '+00:00'))
        return dt.strftime('%Y-%m-%d %H:%M:%S')
    except (ValueError, AttributeError, TypeError):
        return str(val)


def format_perfdata(metrics):
    '''
    Build a Nagios/Icinga perfdata string from (label, value, warn, crit, min, max)
    tuples; None fields and trailing empty fields are dropped.
    '''
    parts = []
    for label, value, warn, crit, min_v, max_v in metrics:
        tail = ['' if f is None else str(f) for f in (warn, crit, min_v, max_v)]
        while tail and tail[-1] == '':
            tail.pop()
        metric = f"{label}={value}"
        if tail:
            metric += ";" + ";".join(tail)
        parts.append(metric)
    return " ".join(parts)


def selected_quota_resources(args):
    '''
    QUOTA_RESOURCES narrowed to --quota-resources. Without the flag only the
    in_default ones are checked; naming a resource explicitly always selects it.
    '''
    if not args.quota_resources:
        return tuple(res for res in QUOTA_RESOURCES if res.in_default)
    return tuple(res for res in QUOTA_RESOURCES if res.key in args.quota_resources)


def is_unlimited(quota):
    '''A quota of -1 means unlimited; None means the API did not report it.'''
    return quota is not None and int(quota) < 0


def quota_free(pair):
    '''
    Free capacity for one {quota, used} pair, or None when it cannot be computed
    (missing data, or an unlimited quota where "free" is meaningless).
    '''
    if pair.quota is None or pair.used is None or is_unlimited(pair.quota):
        return None
    return int(pair.quota) - int(pair.used)


def fmt_amount(val, unit_div=1):
    '''Scale a raw quota amount into its display unit (RAM arrives in MB).'''
    if val is None:
        return '?'
    return f"{val / unit_div:.1f}" if unit_div != 1 else str(val)


def fmt_quota_cell(pair, unit_div=1):
    '''Render one {quota, used} pair as 'used/quota (free)' for the report table.'''
    if pair.quota is None and pair.used is None:
        return 'n/a'
    if is_unlimited(pair.quota):
        return f"{fmt_amount(pair.used, unit_div)}/unlimited"
    return (f"{fmt_amount(pair.used, unit_div)}/{fmt_amount(pair.quota, unit_div)}"
            f" ({fmt_amount(quota_free(pair), unit_div)})")


def load_thresholds_file(path):
    '''
    Load the per-project warning/critical allocation % file (YAML, defaults:/
    projects: keys) for --monitor ram|cpu. Returns {} if no path given; any
    read/parse error is UNKNOWN(3), not a traceback. yaml imported lazily.
    '''
    if not path:
        return {}
    try:
        import yaml
    except ImportError:
        print("UNKNOWN - --thresholds-file needs PyYAML (pip install pyyaml)", file=sys.stderr)
        sys.exit(3)
    try:
        with open(path) as fh:
            data = yaml.safe_load(fh) or {}
    except (OSError, yaml.YAMLError) as err:
        print(f"UNKNOWN - cannot read --thresholds-file '{path}': {err}", file=sys.stderr)
        sys.exit(3)
    if not isinstance(data, dict):
        print(f"UNKNOWN - --thresholds-file '{path}' must be a mapping (defaults:/projects:)", file=sys.stderr)
        sys.exit(3)
    return data


config = {}
config['prog_name'] = str(sys.argv[0])
config['delimeter'] = "="

config = munchify(config)

EPILOG = """
MONITORS AND ALERT CONDITIONS
==============================

  --monitor volumes
    WARNING  : unattached volumes > --warning threshold, or volumes with no associated project
    CRITICAL : volumes in error/error_deleting/error_restoring/error_backing-up/error_extending status, or unknown status

  --monitor ports
    WARNING  : ports with admin_state=DOWN while attached to a resource > --warning threshold
               detached ports (have fixed IPs but no device_owner) > --warning threshold
    CRITICAL : ports with admin_state=UP but status=DOWN while attached (expected to work, but don't) > --critical threshold
               ports with unknown status

  --monitor servers
    WARNING  : servers in stopped/paused/suspended/shelved/soft_deleted state > --warning threshold
    CRITICAL : servers in 'error' or 'rescued' state, or unknown vm_state

  --monitor snapshots
    WARNING  : available snapshots > --warning threshold
    CRITICAL : snapshots in error/error_deleting status, or unknown status

  --monitor ram   (memory allocation per hypervisor)
  --monitor cpu   (vCPU allocation per hypervisor)
    Here --warning and --critical are ALLOCATION PERCENTAGES, not counts:
    WARNING  : any hypervisor whose allocation % exceeds --warning; or an admin-disabled
               hypervisor (intentionally out of service — WARNING even if also down)
    CRITICAL : any hypervisor whose allocation % exceeds --critical; a hypervisor that is
               down WITHOUT being disabled (an unexpected failure); or one that reports
               no usage data
    A threshold of 0 disables the percentage check for that level (so with no thresholds
    the check is OK and just emits/graphs allocation). Allocation can exceed 100%
    (overcommit). Recommended: --warning 85 --critical 95. Requires admin and a Nova
    hypervisor API that still exposes usage (microversion <= 2.87, which this tool pins).
    If compute hosts are dedicated to projects via host aggregates
    (AggregateMultiTenancyIsolation / filter_tenant_id metadata), the --show-all/
    --show-filtered table tags each host's aggregate as 'dedicated: <project>' (one
    tenant), 'shared' (several) or '-' (open); the status line lists affected hosts by
    name only.
    This costs ONE extra API call (aggregate list), not per-project calls.
    Per-project thresholds: pass --thresholds-file FILE (YAML with defaults: and
    projects: sections of ram/cpu warning/critical %). A hypervisor then uses the
    thresholds of the project(s) its aggregate is dedicated to (strictest wins);
    hosts with no dedicated project use defaults:, then the CLI --warning/--critical.
    Projects are auto-discovered from the aggregates — the file only carries numbers.

  --monitor quota   (per-project quota vs actual usage)
    Projects whose NAME matches --quota-strict-pattern (no default: without it no project is strict) must be
    provisioned 1:1 — quota == usage, nothing left free:
    WARNING  : a strict project has quota ABOVE usage (reserved but unused capacity);
               a non-strict project exceeds --warning usage %; or a quota query failed
               or returned no number for some project (a partial failure, and a
               missing value, must not read as "all clear")
    CRITICAL : a strict project is OVER its quota (usage > quota); ANY project has an
               unlimited (-1) quota; a non-strict project exceeds --critical usage %
    Resources checked by default: compute (vcpu, ram, instances), disk (Cinder
    gigabytes) and network (networks, subnets, ports, routers, floating_ips).
    security_groups and security_group_rules are also supported but are NOT in the
    default set — their quota is a flat administrative default rather than something
    provisioned per tenant, so under the 1:1 rule they breach wherever the default
    is left in place; name them in --quota-resources to check them.
    Every resource obeys the same 1:1 rule. Non-strict projects use --warning/
    --critical as usage PERCENTAGES; 0 disables that level.
    An unlimited quota is never expected on ANY project — a strict one can never be
    1:1, and a project without a ceiling can consume the cloud while staying under
    every percentage threshold. It is therefore checked cloud-wide, not just on strict.
    COST: quota has no bulk API, so this is up to 3 API calls per FETCHED project
    (Nova absolute limits + Cinder quota-set with usage + Neutron quota details), run
    --jobs at a time. Two levers cut it: --quota-scope strict|threshold fetches only
    one side of the pattern, and --quota-resources drops a whole call per service it
    no longer needs — the seven network resources share ONE Neutron call, so checking
    all of them costs no more than checking one.
    Give this check a LONG Icinga interval (30-60 min) — it detects provisioning
    drift, not live load. Perfdata is a bounded summary (violation counts + total
    drift per resource), NOT one metric per project.

FILTERING WHAT A MONITOR LOOKS AT
=================================
  --exclude-ids IDS   Skip these (marked ignored instead of classified).
  --include-ids IDS   The mirror: consider ONLY these. --exclude-ids wins on conflict.
                      Applies to every monitor, so a change can be tried on a subset
                      before the full run. Matching is EXACT: a resource UUID, a
                      project name/id, or a hypervisor FULL name (compute-1.zone.
                      example.net — NOT the shortened label used in perfdata). An
                      --include-ids that matches nothing exits UNKNOWN, never a green
                      check watching an empty set.
  --quota-scope       For --monitor quota, chooses which projects are fetched relative
                      to --quota-strict-pattern: all (default) / strict (only the 1:1
                      ones) / threshold (only the rest). This is the API-cost lever.
  --quota-resources   For --monitor quota, which resources to check (compute, disk
                      and network — see --help for the full list). Also an API-cost
                      lever: a resource nobody selected costs no call.

  Each monitor fetches only what it reads. The cloud-wide server list is by far the
  most expensive call, so only servers and ports always pay for it; ram|cpu pull it
  ONLY for the 'projects' column of --show-all/--show-filtered, and volumes, snapshots
  and quota never do. Adding --show-all to ram|cpu is therefore much slower than the
  plain alerting run — keep it for interactive use, not for the scheduled check.

  Note: error/critical-status counts escalate to WARNING once they exceed --warning,
  and to CRITICAL once they exceed --critical (a non-zero --critical no longer hides
  a smaller batch of errors as OK).

AGE FILTERING (--days)
======================
  Only resources whose 'updated_at' field is older than --days days are considered for classification.
  Resources updated more recently than the threshold are silently skipped.
  Default: 14 days. Set to 0 to disable age filtering (consider all resources regardless of age).

PERFORMANCE DATA (Icinga/Nagios graphing)
==========================================
  Every monitor appends Nagios-format performance data after a '|' on the status line,
  e.g.:  CRITICAL - error: 2 ... | errors=2;0;0;0 unattached=5;0;;0 other=0;;0;0 ...
  Each metric is 'label=value;warn;crit;min' (counts, no unit, min 0). Icinga/PNP4Nagios/
  Graphite parse this automatically to graph each category over time. The aggregate
  'errors' / 'down_active' metric carries the --warning and --critical thresholds.

EXAMPLES
========
  # Check servers, alert if any have been in a non-active state for more than 30 days
  {prog} --monitor servers --days 30 --warning 0 --critical 0

  # Show all volumes (no filtering by age)
  {prog} --monitor volumes --show-all --days 0

  # Show only problematic ports updated more than 30 days ago
  {prog} --monitor ports --show-filtered --days 30

  # RAM / vCPU allocation per hypervisor (alert above 85% / 95%)
  {prog} --monitor ram --warning 85 --critical 95
  {prog} --monitor cpu --warning 85 --critical 95

  # fixed-* projects must be 1:1; every other project alerts above 85% / 95% usage
  {prog} --monitor quota --quota-strict-pattern '^fixed-' --warning 85 --critical 95 --show-filtered

  # Two separate Icinga services, so 1:1 drift is not masked by usage alerts:
  #   only the 1:1 projects (thresholds off), then only the rest (thresholds on)
  {prog} --monitor quota --quota-strict-pattern '^fixed-' --quota-scope strict --warning 0 --critical 0
  {prog} --monitor quota --quota-strict-pattern '^fixed-' --quota-scope threshold --warning 85 --critical 95

  # Compute-only 1:1 check — skips the Cinder and Neutron calls, 1 API call per project
  {prog} --monitor quota --quota-strict-pattern '^fixed-' --quota-scope strict --quota-resources vcpu,ram,instances

  # ALL network resources in ONE check, sharing one table — deliberately not split
  # per resource the way vcpu/ram/disk are, and it costs ONE Neutron call per project
  {prog} --monitor quota --quota-strict-pattern '^fixed-' --quota-scope strict --warning 0 --critical 0 \\
      --quota-resources networks,subnets,ports,routers,floating_ips

  # Security groups are off by default (flat quota, never 1:1) — ask for them explicitly
  {prog} --monitor quota --quota-strict-pattern '^fixed-' --quota-scope strict --warning 0 --critical 0 \\
      --quota-resources security_groups,security_group_rules

  # Try any monitor on a subset first
  {prog} --monitor quota --include-ids fixed-alpha,fixed-beta --show-all
""".format(prog=config.prog_name)

# Define command line arguments
parser = argparse.ArgumentParser(prog=config.prog_name,
                                 description='OpenStack Provisions checks - monitors volumes, ports, servers and snapshots for anomalies.',
                                 formatter_class=argparse.RawDescriptionHelpFormatter,
                                 add_help=True,
                                 allow_abbrev=False,
                                 epilog=EPILOG
                                 )


parser.add_argument('--debug', action='store_true', dest='debug', required=False,
                    help='Debug mode'
                    )

parser.add_argument('--cloud', action='store', dest='openstack_cloud', required=False, type=str,
                    default=None,
                    help='clouds.yaml cloud name (default: OS_CLOUD / OS_* environment)')

parser.add_argument('--show-all', action='store_true', dest='show_all', required=False,
                    default=False,
                    help='Show all resources for current monitor selection')

parser.add_argument('--show-filtered', action='store_true', dest='show_filtered', required=False,
                    default=False,
                    help='Show only warning/critical resources for current monitor selection')

parser.add_argument('--monitor', action='store', dest='monitor',
                    choices=['volumes', 'ports', 'servers', 'snapshots', 'ram', 'cpu', 'quota'],
                    help='Select which resource type to monitor')

parser.add_argument('--exclude-ids', action='store', dest='exclude_ids',
                    help='Exclude IDs (comma separated)')

parser.add_argument('--include-ids', action='store', dest='include_ids',
                    help='Only consider these IDs (comma separated) — the mirror of '
                         '--exclude-ids, applied by every monitor. Anything not listed is '
                         'marked ignored instead of being classified. --exclude-ids wins on '
                         'conflict. Useful to try a monitor on a subset before the full run. '
                         'Matching is EXACT, on the same identifiers --exclude-ids uses: a '
                         'resource UUID, a project name/id, or a hypervisor FULL name (e.g. '
                         'compute-1.zone.example.net, not the shortened perfdata label). If it '
                         'matches nothing the check exits UNKNOWN rather than reporting an '
                         'empty OK.')

parser.add_argument('--warning', action='store', dest='level_warning', type=int,
                    default=0,
                    help='Warning threshold (resource count). See monitor descriptions below for what is counted.')

parser.add_argument('--critical', action='store', dest='level_critical', type=int,
                    default=0,
                    help='Critical threshold (resource count). See monitor descriptions below for what is counted.')

parser.add_argument('--days', action='store', dest='days', type=int,
                    default=14,
                    help='Only consider resources whose updated_at is older than this many days. Use 0 to disable age filtering.')

parser.add_argument('--thresholds-file', action='store', dest='thresholds_file', default=None,
                    help='For --monitor ram|cpu only: YAML file with per-project warning/critical '
                         'allocation %% thresholds (defaults: and projects: sections). Each hypervisor '
                         'uses the thresholds of the project(s) its host aggregate is dedicated to '
                         '(filter_tenant_id); projects are auto-discovered, the file only carries '
                         'thresholds. Priority: projects:<name> > defaults: > CLI --warning/--critical.')

parser.add_argument('--quota-strict-pattern', action='store', dest='quota_strict_pattern',
                    default=None,
                    help='For --monitor quota only: regex matched against the PROJECT NAME. '
                         'Matching projects must be provisioned 1:1 (quota == usage, nothing left '
                         'free); non-matching projects are checked against the CLI --warning/'
                         '--critical usage %% instead. Not set: no project is strict.')

parser.add_argument('--quota-scope', action='store', dest='quota_scope',
                    choices=['all', 'strict', 'threshold'], default='all',
                    help='For --monitor quota only: WHICH projects to fetch, expressed against '
                         '--quota-strict-pattern. all = every project; strict = only projects '
                         'matching the pattern (the 1:1 ones); threshold = only projects NOT '
                         'matching it. This is the API-cost lever — up to 3 calls per fetched '
                         'project. Default: %(default)s')

parser.add_argument('--quota-resources', action='store', dest='quota_resources', default=None,
                    help='For --monitor quota only: comma separated subset of '
                         + ','.join(r.key for r in QUOTA_RESOURCES)
                         + '. Default: all except security_groups and security_group_rules, '
                           'whose quota is a flat administrative default and so is never 1:1. '
                           'Also the API-cost lever: Nova, Cinder and Neutron are each called '
                           'only if some selected resource needs it, and ONE Neutron call '
                           'covers every network resource.')

parser.add_argument('--jobs', action='store', dest='jobs', type=int, default=8,
                    help='For --monitor quota only: how many per-project quota API calls to run '
                         'concurrently. Quota has no bulk API, so cost is 1 call per project per '
                         'service the selected --quota-resources need (Nova, Cinder, Neutron). '
                         'Default: %(default)s')

args = parser.parse_args(args=None if sys.argv[1:] else ['--help'])

if args.exclude_ids: args.exclude_ids = args.exclude_ids.split(',')
if args.include_ids: args.include_ids = args.include_ids.split(',')
if args.quota_resources: args.quota_resources = args.quota_resources.split(',')


class OpenStackProvisions():

    def __init__(self,config, args):
        self.config = config
        self.args = args
        self.connect()

        self.all_projects = self.get_all_projects()
        self.all_servers = munchify({})
        self.all_servers_ids = munchify({})
        if self.needs_servers():
            self.all_servers = self.get_servers()

        if 'volumes' == self.args.monitor:
            self.all_volumes = self.get_volumes()
        # elif 'servers' == self.args.monitor:
        # self.all_floating_ips = self.get_floating_ips()
        # self.all_routers = self.get_routers()
        elif 'ports' == self.args.monitor:
            self.all_ports = self.get_ports()
        elif 'snapshots' == self.args.monitor:
            self.all_snapshots = self.get_snapshots()
        elif self.args.monitor in ('ram', 'cpu'):
            self.all_compute = self.get_compute()
            self.host_aggregates = self.get_aggregates()
            self.project_thresholds = load_thresholds_file(self.args.thresholds_file)
        elif 'quota' == self.args.monitor:
            self.project_quotas = self.get_project_quotas()

        if self.args.include_ids:
            self.verify_include_scope()

    def needs_servers(self):
        '''
        Whether this run must pay for the cloud-wide, paginated server list — by far
        the most expensive fetch here, so only the monitors that actually read it pull
        it. 'servers' is its subject; 'ports' needs each device's vm_state and
        hostname; ram|cpu need it ONLY to count projects per hypervisor in the
        --show-all/--show-filtered table. volumes, snapshots and quota never read it.
        '''
        if self.args.monitor in ('servers', 'ports'):
            return True
        if self.args.monitor in ('ram', 'cpu'):
            return bool(self.args.show_all or self.args.show_filtered)
        return False

    def verify_include_scope(self):
        '''
        An --include-ids that matches nothing would leave the check watching an EMPTY
        set and happily reporting OK — the failure mode that silently hides problems.
        Fail loudly as UNKNOWN(3) instead. Note ids must be exact: hypervisors carry
        their FULL name (compute-1.zone.example.net), not the shortened perfdata form.
        '''
        collections = {
            'volumes': 'all_volumes',
            'ports': 'all_ports',
            'servers': 'all_servers',
            'snapshots': 'all_snapshots',
            'ram': 'all_compute',
            'cpu': 'all_compute',
        }
        if 'quota' == self.args.monitor:
            in_scope = len(self.project_quotas)
        else:
            attr = collections.get(self.args.monitor)
            if attr is None:
                return
            in_scope = sum(1 for item in getattr(self, attr).values()
                           if not item['ignored'])
        if in_scope == 0:
            print(f"UNKNOWN - --include-ids matched no {self.args.monitor}, so nothing "
                  f"would be checked (ids must match exactly): "
                  f"{','.join(self.args.include_ids)}", file=sys.stderr)
            sys.exit(3)

    def is_ignored(self, *identifiers):
        '''
        Whether a resource is out of scope. --exclude-ids always wins; --include-ids,
        when given, acts as an allow-list so anything unlisted is ignored too. Each
        monitor passes the identifiers it matches on (id, and name where meaningful).
        '''
        ids = [i for i in identifiers if i]
        if self.args.exclude_ids and any(i in self.args.exclude_ids for i in ids):
            return True
        if self.args.include_ids and not any(i in self.args.include_ids for i in ids):
            return True
        return False

    def connect(self):
        '''
        OpenStack connection
        '''
        try:
            self.conn = openstack.connect(cloud=self.args.openstack_cloud)
        except openstack.exceptions.ConfigException:
            print(f"UNKNOWN - OpenStack config error (check cloud '{self.args.openstack_cloud or 'OS_CLOUD/env'}' / credentials)", file=sys.stderr)
            sys.exit(3)

    def get_all_projects(self):
        projects_list = {}
        for project in self.conn.list_projects():
            projects_list[project.id] = {}
            projects_list[project.id]['name'] = project.name
            projects_list[project.id]['id'] = project.id
        projects_list_sorted = dict(sorted(projects_list.items(), key = lambda x: (x[1]['name'], x[1]['id'])))
        return munchify(projects_list_sorted)

    def get_volumes(self):
        volumes_list = munchify(self.conn.block_storage.volumes(details=True, all_projects=True))
        volumes = {}
        for volume_data in volumes_list:
            volumes[volume_data.id] = munchify(volume_data)
            volumes[volume_data.id]['ignored'] = self.is_ignored(volume_data.id)

        return munchify(volumes)

    def get_servers(self):
        servers = {}
        all_servers_ids = {}
        for server in self.conn.compute.servers(details=True, all_projects=True):
            servers[server.id] = server.to_dict()
            servers[server.id]['ignored'] = self.is_ignored(server.id)
            all_servers_ids[server.id] = Munch({
                'id': server.id,
                'hostname': server.hostname,
            })
        self.all_servers_ids = munchify(all_servers_ids)

        return munchify(servers)

    def get_servers_count(self):
        count = len(list(self.all_servers))
        return count

    def get_ports(self):
        ports_grouped = {}
        ports = self.conn.network.ports()
        for port in ports:
            ports_grouped[port.id] = port
            ports_grouped[port.id]['ignored'] = self.is_ignored(port.id)
        return ports_grouped

    def get_floating_ips(self):
        floating_ips_grouped = {}
        floating_ips = self.conn.network.ips()
        for ip in floating_ips:
            if ip.floating_ip_address not in floating_ips_grouped.keys():
                floating_ips_grouped[ip.floating_ip_address] = ip
            else:
                print(f"Duplicated floating IP: {ip.floating_ip_address}")
        return munchify(floating_ips_grouped)

    def get_subnets(self):
        subnets = self.conn.network.subnets()
        for subnet in subnets:
            print(subnet, "\n")

    def get_routers(self):
        routers_grouped = {}
        routers = self.conn.network.routers()
        for router_data in routers:
            for ip_data in router_data['external_gateway_info']['external_fixed_ips']:
                if '.' in ip_data['ip_address']:
                    if ip_data['ip_address'] not in routers_grouped.keys():
                        routers_grouped[ip_data['ip_address']] = router_data
                    else:
                        print(f"Duplicated router IP: {ip_data['ip_address']}")
        return munchify(routers_grouped)

    def get_snapshots(self):
        snapshots_grouped = {}
        snapshots = self.conn.block_storage.snapshots(details=True, all_projects=True)
        for snapshot in snapshots:
            snapshots_grouped[snapshot.id] = snapshot.to_dict()
            snapshots_grouped[snapshot.id]['ignored'] = self.is_ignored(snapshot.id)
        # return munchify({snapshot.id:snapshot for snapshot in snapshots})
        return munchify(snapshots_grouped)

    def get_compute(self):
        '''
        Per-hypervisor CPU/RAM usage. Pin microversion <= 2.87: Nova dropped the
        usage fields (vcpus_used, memory_mb_used, ...) at 2.88.
        '''
        try:
            self.conn.compute.default_microversion = '2.87'
        except Exception:
            pass
        compute = {}
        no_service_block = False
        for hv in self.conn.compute.hypervisors(details=True):
            data = hv.to_dict()
            key = data.get('id') or data.get('name')
            compute[key] = munchify(data)
            compute[key]['ignored'] = self.is_ignored(key, data.get('name'))
            # Nova nests the admin disable reason in the hypervisor 'service' block,
            # so it costs no extra call. None = disabled without a reason given.
            service = data.get('service_details') or {}
            compute[key]['disabled_reason'] = service.get('disabled_reason')
            if not service:
                no_service_block = True
        if no_service_block:
            self._fill_disabled_reasons(compute)
        return munchify(compute)

    def _fill_disabled_reasons(self, compute):
        '''
        Fallback for clouds whose hypervisor payload carries no 'service' block:
        ONE os-services call, joined to hypervisors by bare host name.
        '''
        try:
            reasons = {host_key(svc.host): svc.disabled_reason
                       for svc in self.conn.compute.services(binary='nova-compute')}
        except openstack.exceptions.SDKException:
            return
        for hv in compute.values():
            if hv.get('disabled_reason') is None:
                hv['disabled_reason'] = reasons.get(host_key(hv.get('name')))

    def get_aggregates(self):
        '''
        Map each compute host to its aggregate(s) and the project(s) dedicated to
        it (Nova AggregateMultiTenancyIsolation: metadata keys 'filter_tenant_id*'
        hold project IDs). One API call; any SDK error yields an empty map.
        '''
        host_map = {}
        try:
            aggregates = list(self.conn.compute.aggregates())
        except openstack.exceptions.SDKException:
            return munchify(host_map)
        for agg in aggregates:
            meta = getattr(agg, 'metadata', None) or {}
            pids = [v for k, v in meta.items()
                    if k.startswith('filter_tenant_id') and v]
            pnames = sorted(
                self.all_projects[p].name if p in self.all_projects.keys() else str(p)
                for p in pids
            )
            for host in (getattr(agg, 'hosts', None) or []):
                entry = host_map.setdefault(
                    host_key(host), {'aggregates': set(), 'projects': set()})
                entry['aggregates'].add(agg.name)
                entry['projects'].update(pnames)
        return munchify({h: {'aggregates': sorted(v['aggregates']),
                             'projects': sorted(v['projects'])}
                         for h, v in host_map.items()})

    def _fetch_project_quota(self, project_id):
        '''
        Quota + usage for ONE project, via the PROXY layer, which takes a raw project
        id. (The conn.get_compute_limits/get_volume_quotas shade helpers would add a
        find_project lookup per project — 4 calls instead of 2.) Nova absolute limits
        carry limit AND used together; Cinder needs usage=True; Neutron details=True
        returns every network resource at once. Only the services the selected
        resources need are called, so narrowing --quota-resources drops whole calls.
        Returns a Munch of {resource: {quota, used}} plus 'error' on failure.
        '''
        resources = selected_quota_resources(self.args)
        sources = {res.source for res in resources}
        entry = Munch({'error': None})

        def note_error(text):
            entry.error = f"{entry.error}; {text}" if entry.error else text

        absolute = None
        if 'compute' in sources:
            try:
                absolute = self.conn.compute.get_limits(tenant_id=project_id).absolute
            except openstack.exceptions.SDKException as err:
                note_error(f"compute limits: {err}")

        quota_set = None
        if 'disk' in sources:
            try:
                quota_set = self.conn.block_storage.get_quota_set(project_id, usage=True)
            except openstack.exceptions.SDKException as err:
                note_error(f"volume quota: {err}")

        net_quota = None
        if 'network' in sources:
            try:
                net_quota = self.conn.network.get_quota(project_id, details=True)
            except openstack.exceptions.SDKException as err:
                note_error(f"network quota: {err}")

        for res in resources:
            quota = used = None
            if res.source == 'compute' and absolute is not None:
                quota = getattr(absolute, res.quota_attr, None)
                used = getattr(absolute, res.used_attr, None)
            elif res.source == 'disk' and quota_set is not None:
                quota = getattr(quota_set, res.quota_attr, None)
                used = (getattr(quota_set, 'usage', None) or {}).get(res.used_attr)
            elif res.source == 'network' and net_quota is not None:
                # Each Neutron detail is {'limit', 'used', 'reserved'}. 'reserved' is
                # transient in-flight allocation and is left out: counting it as used
                # could hide real free quota, and a missed alert is the worse failure.
                detail = getattr(net_quota, res.quota_attr, None) or {}
                quota = detail.get('limit')
                used = detail.get('used')
            entry[res.key] = Munch({'quota': quota, 'used': used})
        return entry

    def get_project_quotas(self):
        '''
        Quota + usage per project, fetched concurrently (--jobs). Quota has no bulk
        API, so cost is 1-2 calls per FETCHED project — narrow the set with
        --quota-scope / --include-ids, and give the check a long Icinga interval; it
        detects provisioning drift, not live load.
        Returns {project_id: Munch(name=..., strict=bool, <resource>={quota,used})}.
        '''
        pattern = re.compile(self.args.quota_strict_pattern) if self.args.quota_strict_pattern else None
        targets = []
        # Excluded projects are never fetched (that would cost API calls), but they
        # are remembered so the status line can report an ignored count.
        self.quota_ignored = []
        for pid, pdata in self.all_projects.items():
            if self.is_ignored(pid, pdata.name):
                self.quota_ignored.append(pid)
                continue
            strict = bool(pattern and pattern.match(pdata.name or ''))
            # --quota-scope narrows WHICH projects are fetched at all, relative to
            # the same strict pattern, so the API cost follows the intent.
            if self.args.quota_scope == 'strict' and not strict:
                continue
            if self.args.quota_scope == 'threshold' and strict:
                continue
            targets.append(pid)
        workers = max(1, min(self.args.jobs, len(targets) or 1))
        with ThreadPoolExecutor(max_workers=workers) as pool:
            fetched = list(pool.map(self._fetch_project_quota, targets))

        quotas = {}
        for pid, entry in zip(targets, fetched):
            name = self.all_projects[pid].name
            entry.name = name
            entry.id = pid
            entry.strict = bool(pattern and pattern.match(name or ''))
            quotas[pid] = entry
        return munchify(quotas)

    def show_all_servers(self, filter_ids=None, days_suffix=None):
        '''
        Print list of all servers
        '''
        rows = {k: v for k, v in self.all_servers.items() if filter_ids is None or k in filter_ids}
        label = f"Filtered servers ({len(rows)}):" if filter_ids is not None else f"All servers ({self.get_servers_count()}):"
        if days_suffix:
            label = label.rstrip(':') + f" — {days_suffix}:"
        self.header = label
        self.print_header()
        table = PrettyTable()
        # U+2502 avoids ASCII '|': Icinga2 treats text after '|=' as perfdata.
        table.vertical_char = '│'
        table.field_names = ['#','compute_host','hostname','status','host_status','vm_state','updated_at','id','project','project_id']
        table.align["#"] = "l"
        for i, (server_key, server_data) in enumerate(rows.items(), start=1):
            project_name = self.all_projects[server_data['project_id']].name if server_data['project_id'] in self.all_projects.keys() else "UNDEFINED"
            table.add_row([
                i,
                server_data.compute_host,
                server_data.hostname,
                server_data.status,
                server_data.host_status,
                server_data.vm_state,
                fmt_date(server_data.get('updated_at')),
                server_data.id,
                project_name,
                server_data.project_id,
            ])
        print(table.get_string())

    def show_all_volumes(self, filter_ids=None, days_suffix=None):
        '''
        Print list of all volumes
        '''
        rows = {k: v for k, v in self.all_volumes.items() if filter_ids is None or k in filter_ids}
        label = f"Filtered volumes ({len(rows)}):" if filter_ids is not None else f"All volumes ({len(self.all_volumes)}):"
        if days_suffix:
            label = label.rstrip(':') + f" — {days_suffix}:"
        self.header = label
        self.print_header()
        table = PrettyTable()
        # U+2502 avoids ASCII '|': Icinga2 treats text after '|=' as perfdata.
        table.vertical_char = '│'
        table.field_names = ['#','id','size','status','attached','attachments','bootable','volume_type','updated_at','project','project_id','ignored']
        table.align["#"] = "l"
        for i, (volume_key, volume_data) in enumerate(rows.items(), start=1):
            project_name = self.all_projects[volume_data.project_id].name if volume_data.project_id in self.all_projects.keys() else "UNDEFINED"
            attachment_count = len(volume_data.attachments)
            table.add_row([
                i,
                str(volume_data.id),
                str(volume_data.size),
                str(volume_data.status),
                "yes" if attachment_count > 0 else "no",
                str(attachment_count),
                str(volume_data.is_bootable),
                str(volume_data.volume_type),
                fmt_date(volume_data.get('updated_at')),
                project_name,
                str(volume_data.project_id),
                str(volume_data.ignored),
            ])
        print(table.get_string())

    def show_all_floating_ips(self):
        '''
        Print list of all floating ips
        '''
        self.header = f"All floating IPs ({len(self.all_floating_ips)}):"
        self.print_header()
        lines = []
        for floating_ip_key, floating_ip_data in self.all_floating_ips.items():
            try:
                state = "up" if floating_ip_data.port_details.admin_state_up else "down"
            except Exception:
                state = "N/A"
            project_name = self.all_projects[floating_ip_data.project_id].name if floating_ip_data.project_id in self.all_projects.keys() else "UNDEFINED"
            lines.append(f"id: {floating_ip_data.id} | IP: {floating_ip_data.floating_ip_address} | status: {floating_ip_data.status} | state: {state} | project: {project_name} | project_id: {floating_ip_data.project_id}")
        print("\n".join(lines))

    def show_all_ports(self, filter_ids=None, days_suffix=None):
        '''
        Print list of all ports
        '''
        rows = {k: v for k, v in self.all_ports.items() if filter_ids is None or k in filter_ids}
        label = f"Filtered ports ({len(rows)}):" if filter_ids is not None else f"All ports ({len(self.all_ports)}):"
        if days_suffix:
            label = label.rstrip(':') + f" — {days_suffix}:"
        self.header = label
        self.print_header()
        table = PrettyTable()
        # U+2502 avoids ASCII '|': Icinga2 treats text after '|=' as perfdata.
        table.vertical_char = '│'
        table.field_names = ['#','id','status','state','attached','fixed_ips','device_owner','server_hostname','updated_at','project','project_id','ignored']
        table.align["#"] = "l"
        table.align["fixed_ips"] = "l"
        table.align["device_owner"] = "l"
        for i, (port_key, port_data) in enumerate(rows.items(), start=1):
            state = "up" if port_data.is_admin_state_up else "down"
            attached = "yes" if port_data.device_owner else "no"
            addr_data = "\n".join(fixed_ip_data['ip_address'] for fixed_ip_data in port_data.fixed_ips)
            try:
                server_hostname = self.all_servers_ids[port_data.device_id].hostname
            except KeyError:
                server_hostname = "None"
            project_name = self.all_projects[port_data.project_id].name if port_data.project_id in self.all_projects.keys() else "UNDEFINED"
            table.add_row([
                i,
                port_data.id,
                port_data.status,
                state,
                attached,
                addr_data,
                port_data.device_owner or "",
                server_hostname,
                fmt_date(port_data.get('updated_at')),
                project_name,
                port_data.project_id,
                port_data.ignored,
            ])
        print(table.get_string())

    def show_all_snapshots(self, filter_ids=None, days_suffix=None):
        '''
        Print list of all snapshots
        '''
        rows = {k: v for k, v in self.all_snapshots.items() if filter_ids is None or k in filter_ids}
        label = f"Filtered snapshots ({len(rows)}):" if filter_ids is not None else f"All snapshots ({len(self.all_snapshots)}):"
        if days_suffix:
            label = label.rstrip(':') + f" — {days_suffix}:"
        self.header = label
        self.print_header()
        table = PrettyTable()
        # U+2502 avoids ASCII '|': Icinga2 treats text after '|=' as perfdata.
        table.vertical_char = '│'
        table.field_names = ['#','name','id','status','size (GB)','last update','forced', 'project', 'project_id', 'ignored']
        table.align["#"] = "l"
        table.align["name"] = "l"
        for i, (snapshot_key, snapshot_data) in enumerate(rows.items(), start=1):
            project_name = self.all_projects[snapshot_data.project_id].name if snapshot_data.project_id in self.all_projects.keys() else "UNDEFINED"
            table.add_row([
                i,
                snapshot_data.name,
                snapshot_data.id,
                snapshot_data.status,
                snapshot_data.size,
                fmt_date(snapshot_data.updated_at),
                snapshot_data.is_forced,
                project_name,
                snapshot_data.project_id,
                snapshot_data.ignored,
            ])
        print(table.get_string())

    def show_all_allocation(self, kind, filter_ids=None, days_suffix=None):
        '''
        Print per-hypervisor RAM or vCPU allocation (kind = 'ram' or 'cpu').
        '''
        rows = {
            k: v for k, v in self.all_compute.items()
            if filter_ids is None or (v.get('name') or k) in filter_ids
        }
        noun = "RAM" if kind == 'ram' else "vCPU"
        label = f"Filtered {noun} allocation ({len(rows)}):" if filter_ids is not None else f"All {noun} allocation ({len(self.all_compute)}):"
        if days_suffix:
            label = label.rstrip(':') + f" — {days_suffix}:"
        self.header = label
        self.print_header()
        table = PrettyTable()
        # U+2502 avoids ASCII '|': Icinga2 treats text after '|=' as perfdata.
        table.vertical_char = '│'
        usage_col = 'ram used/total (GB)' if kind == 'ram' else 'vcpu used/total'
        pct_col = 'ram %' if kind == 'ram' else 'vcpu %'
        table.field_names = ['#','hypervisor','state','status',usage_col,pct_col,'instances','projects','aggregate','disable reason','ignored']
        table.align["#"] = "l"
        table.align["hypervisor"] = "l"
        table.align["aggregate"] = "l"
        table.align["disable reason"] = "l"
        # Wrap instead of widening the table; free-text reasons can be long.
        table.max_width["disable reason"] = 40

        host_aggregates = getattr(self, 'host_aggregates', munchify({}))

        # Map each hypervisor (by short host id) to the projects that have
        # instances running on it, taken from the live server placement.
        host_projects = {}
        for srv in self.all_servers.values():
            h = short_host(srv.get('compute_host'))
            host_projects.setdefault(h, set()).add(srv.get('project_id'))

        for i, (compute_key, hv) in enumerate(rows.items(), start=1):
            name = hv.get('name') or compute_key
            if kind == 'ram':
                used = (hv.get('memory_used') or 0) / 1024.0
                total = (hv.get('memory_size') or 0) / 1024.0
                used_total = f"{used:.1f}/{total:.1f}"
            else:
                used = hv.get('vcpus_used') or 0
                total = hv.get('vcpus') or 0
                used_total = f"{used}/{total}"
            if total:
                pct = used / total * 100
                pct_label = f"{pct:.1f}%" + (" (OC)" if pct > 100 else "")
            else:
                used_total += " (n/a)"
                pct_label = "n/a"
            # Distinct projects with instances running here (count only — names get
            # huge on busy hosts and add little here).
            proj_count = len(host_projects.get(short_host(name), set()))
            # Aggregate dedication type from filter_tenant_id: exactly one tenant =
            # 'dedicated: <project>' (named for quick reference, it's just one short
            # name), several = 'shared', none = '-' (open / general pool).
            agg_info = host_aggregates.get(host_key(name))
            ded_projects = list(agg_info.projects) if agg_info else []
            if len(ded_projects) == 1:
                agg_type = f"dedicated: {ded_projects[0]}"
            elif len(ded_projects) > 1:
                agg_type = "shared"
            else:
                agg_type = "-"
            table.add_row([
                i,
                name,
                hv.get('state'),
                hv.get('status'),
                used_total,
                pct_label,
                hv.get('running_vms'),
                proj_count,
                agg_type,
                hv.get('disabled_reason') or '-',
                hv.get('ignored'),
            ])
        print(table.get_string())

    def show_all_quota(self, filter_ids=None, deviations=None):
        '''
        Print per-project quota vs usage. Each resource cell is 'used/quota (free)';
        'unlimited' means quota -1, which a strict 1:1 project can never satisfy.
        '''
        resources = selected_quota_resources(self.args)
        rows = {k: v for k, v in self.project_quotas.items()
                if filter_ids is None or k in filter_ids}
        label = (f"Filtered project quotas ({len(rows)}):" if filter_ids is not None
                 else f"All project quotas ({len(self.project_quotas)}):")
        self.header = label
        self.print_header()
        table = PrettyTable()
        # U+2502 avoids ASCII '|': Icinga2 treats text after '|=' as perfdata.
        table.vertical_char = '│'
        table.field_names = (['#', 'project', 'project_id', 'mode']
                             + [res.label for res in resources] + ['deviation'])
        for col in ('#', 'project', 'project_id', 'mode', 'deviation'):
            table.align[col] = 'l'

        ordered = sorted(rows.items(), key=lambda kv: (not kv[1].strict, kv[1].name or ''))
        for i, (pid, entry) in enumerate(ordered, start=1):
            cells = []
            for res in resources:
                cells.append(fmt_quota_cell(entry[res.key], res.unit_div))
            table.add_row([
                i,
                entry.name,
                pid,
                '1:1 strict' if entry.strict else 'threshold',
                *cells,
                (deviations or {}).get(pid, '-'),
            ])
        print(table.get_string())

    def show_thresholds_config(self):
        '''
        Print the loaded --thresholds-file config. No-op if no file given;
        '-' means "not set here" (inherits defaults:, then CLI).
        '''
        tf = getattr(self, 'project_thresholds', {}) or {}
        if not tf:
            return
        defaults = tf.get('defaults') or {}
        projects = tf.get('projects') or {}
        self.header = f"Threshold config ({self.args.thresholds_file}):"
        self.print_header()
        table = PrettyTable()
        table.vertical_char = '│'
        table.field_names = ['project', 'ram warn', 'ram crit', 'cpu warn', 'cpu crit']
        table.align['project'] = 'l'

        def cell(cfg, kind, level):
            val = ((cfg.get(kind) or {}).get(level))
            return '-' if val is None else val

        table.add_row(['defaults',
                       cell(defaults, 'ram', 'warning'), cell(defaults, 'ram', 'critical'),
                       cell(defaults, 'cpu', 'warning'), cell(defaults, 'cpu', 'critical')])
        for pname in sorted(projects.keys()):
            pcfg = projects[pname] or {}
            table.add_row([pname,
                           cell(pcfg, 'ram', 'warning'), cell(pcfg, 'ram', 'critical'),
                           cell(pcfg, 'cpu', 'warning'), cell(pcfg, 'cpu', 'critical')])
        print(table.get_string())

    # Print header/title section for data output
    def print_header(self):
        print(f"\n{self.header}\n{self.config.delimeter*(len(self.header)+3)}")


class OpenStackProvisionsMonitoring:

    def __init__(self,config, args, provisions):
        self.config = config
        self.args = args
        self.provisions = provisions

    def get_exit_code(self, level):
        exit_code = munchify({
            'ok': {
                'description': f"{ 'ok'.upper() } - { self.exit_code_stats }",
                'code': 0
            },
            'warning': {
                'description': f"{ 'warning'.upper() } - { self.exit_code_stats }",
                'code': 1
            },
            'critical': {
                'description': f"{ 'critical'.upper() } - { self.exit_code_stats }",
                'code': 2
            },
            'unknown': {
                'description': f"{ 'unknown'.upper() } - { self.exit_code_stats }",
                'code': 3
            }
        })

        return munchify(exit_code[level])

    def is_older_than_days(self, updated_at_str):
        '''
        Returns True if updated_at_str is older than self.args.days days.
        If --days is 0, always returns True (age filtering disabled).
        '''
        if self.args.days == 0:
            return True
        if not updated_at_str:
            return True
        try:
            dt = datetime.fromisoformat(str(updated_at_str).replace('Z', '+00:00'))
            if dt.tzinfo is None:
                dt = dt.replace(tzinfo=timezone.utc)
            age = (datetime.now(timezone.utc) - dt).days
            return age >= self.args.days
        except (ValueError, AttributeError, TypeError):
            return True


    volume_error_statuses = {'error', 'error_deleting', 'error_restoring', 'error_backing-up', 'error_extending'}
    volume_known_statuses = {
        'available', 'in-use', 'error', 'creating', 'deleting',
        'error_deleting', 'error_restoring', 'error_backing-up', 'error_extending',
        'backing-up', 'restoring-backup', 'maintenance', 'reserved',
        'attaching', 'detaching', 'awaiting-transfer',
        'downloading', 'uploading', 'retyping', 'extending',
    }

    def get_classified_volumes(self):
        classified_volumes = Munch({
            'error': [],
            'error_deleting': [],
            'error_restoring': [],
            'error_backing_up': [],
            'error_extending': [],
            'unattached': [],
            'noproject': [],
            'other': [],
            'ignored': [],
        })
        for volume_key, volume_data in self.provisions.all_volumes.items():
            if volume_data.ignored == True:
                classified_volumes.ignored.append(volume_data.id)
            elif not self.is_older_than_days(volume_data.get('updated_at')):
                pass
            else:
                status = volume_data.status.lower() if volume_data.status else None
                if status == 'error':
                    classified_volumes.error.append(volume_data.id)
                elif status == 'error_deleting':
                    classified_volumes.error_deleting.append(volume_data.id)
                elif status == 'error_restoring':
                    classified_volumes.error_restoring.append(volume_data.id)
                elif status == 'error_backing-up':
                    classified_volumes.error_backing_up.append(volume_data.id)
                elif status == 'error_extending':
                    classified_volumes.error_extending.append(volume_data.id)
                elif not status or status not in self.volume_known_statuses:
                    classified_volumes.other.append(volume_data.id)
                if len(volume_data.attachments) == 0:
                    classified_volumes.unattached.append(volume_data.id)
                if volume_data.project_id not in self.provisions.all_projects.keys():
                    classified_volumes.noproject.append(volume_data.id)
        classified_volumes['stats'] = Munch({
            'error': len(classified_volumes.error),
            'error_deleting': len(classified_volumes.error_deleting),
            'error_restoring': len(classified_volumes.error_restoring),
            'error_backing_up': len(classified_volumes.error_backing_up),
            'error_extending': len(classified_volumes.error_extending),
            'unattached': len(classified_volumes.unattached),
            'noproject': len(classified_volumes.noproject),
            'other': len(classified_volumes.other),
            'ignored': len(classified_volumes.ignored),
        })

        return munchify(classified_volumes)


    port_known_statuses = {'active', 'down'}
    port_network_owners = {
        'network:floatingip',
        'network:floatingip_agent_gateway',
        'network:router_interface',
        'network:router_interface_distributed',
        'network:router_gateway',
        'network:router_ha_interface',
        'network:dhcp',
        'network:ha_router_replicated_interface',
    }

    server_non_active_states = {
        'stopped', 'paused', 'suspended', 'shelved', 'shelved_offloaded',
        'soft_deleted', 'deleted',
    }

    def get_classified_ports(self):
        classified_ports = Munch({
            'down_active': [],       # admin=up, status=DOWN, attached to active/unknown server (Critical)
            'admin_down_attached': [],  # admin=down, attached — intentionally disabled but still bound (Warning)
            'detached': [],          # has fixed_ips but no device_owner (Warning)
            'other': [],             # unknown status (Critical)
            'ignored': []
        })

        for port_key, port_data in self.provisions.all_ports.items():
            if port_data.ignored == True:
                classified_ports.ignored.append(port_data.id)
            elif not self.is_older_than_days(port_data.get('updated_at')):
                pass
            else:
                port_status = port_data.status.lower() if port_data.status else None
                is_network_owned = port_data.device_owner in self.port_network_owners
                is_attached = bool(port_data.device_owner) and not is_network_owned

                # Buckets are mutually exclusive, evaluated by severity priority so a
                # single port is never counted in more than one category.
                if not is_network_owned and (not port_status or port_status not in self.port_known_statuses):
                    # Unknown status (Critical) — takes precedence over everything else
                    classified_ports.other.append(port_data.id)
                elif port_data.is_admin_state_up == True and port_status == 'down' and is_attached:
                    # admin=UP but link DOWN while attached — expected only if the
                    # backing server is intentionally not running.
                    if port_data.device_owner == 'compute:nova':
                        server = self.provisions.all_servers.get(port_data.device_id)
                        if server and server.vm_state in self.server_non_active_states:
                            pass  # expected, server is not running
                        else:
                            # server is active or not found (orphan port) — port should be UP
                            classified_ports.down_active.append(port_data.id)
                    else:
                        classified_ports.down_active.append(port_data.id)
                elif port_data.is_admin_state_up == False and is_attached:
                    # Administratively disabled but still bound to a resource (Warning)
                    classified_ports.admin_down_attached.append(port_data.id)
                elif port_data.fixed_ips and not port_data.device_owner:
                    # Has fixed IPs but nothing owns it (Warning)
                    classified_ports.detached.append(port_data.id)

        classified_ports['stats'] = Munch({
            'down_active': len(classified_ports.down_active),
            'admin_down_attached': len(classified_ports.admin_down_attached),
            'detached': len(classified_ports.detached),
            'other': len(classified_ports.other),
            'ignored': len(classified_ports.ignored)
        })

        return classified_ports


    server_known_states = {
        'active', 'stopped', 'error', 'paused', 'suspended',
        'rescued', 'resized', 'deleted', 'soft_deleted',
        'shelved', 'shelved_offloaded', 'building',
    }

    def get_classified_servers(self):
        classified_servers = Munch({
            'error': [],
            'rescued': [],
            'stopped': [],
            'paused': [],
            'suspended': [],
            'shelved': [],
            'soft_deleted': [],
            'other': [],
            'ignored': []
        })
        for server_key, server_data in self.provisions.all_servers.items():
            if server_data.ignored == True:
                classified_servers.ignored.append(server_data.id)
            elif not self.is_older_than_days(server_data.get('updated_at')):
                pass
            else:
                state = server_data.vm_state
                if state == 'error':
                    classified_servers.error.append(server_data.id)
                elif state == 'rescued':
                    classified_servers.rescued.append(server_data.id)
                elif state == 'stopped':
                    classified_servers.stopped.append(server_data.id)
                elif state == 'paused':
                    classified_servers.paused.append(server_data.id)
                elif state == 'suspended':
                    classified_servers.suspended.append(server_data.id)
                elif state in ('shelved', 'shelved_offloaded'):
                    classified_servers.shelved.append(server_data.id)
                elif state == 'soft_deleted':
                    classified_servers.soft_deleted.append(server_data.id)
                elif not state or state not in self.server_known_states:
                    classified_servers.other.append(server_data.id)
        classified_servers['stats'] = Munch({
            'error': len(classified_servers.error),
            'rescued': len(classified_servers.rescued),
            'stopped': len(classified_servers.stopped),
            'paused': len(classified_servers.paused),
            'suspended': len(classified_servers.suspended),
            'shelved': len(classified_servers.shelved),
            'soft_deleted': len(classified_servers.soft_deleted),
            'other': len(classified_servers.other),
            'ignored': len(classified_servers.ignored)
        })

        return classified_servers


    snapshot_known_statuses = {'available', 'creating', 'deleting', 'error', 'error_deleting', 'restoring'}

    def get_classified_snapshots(self):
        classified_snapshots = Munch({
            'error': [],
            'error_deleting': [],
            'available': [],
            'other': [],
            'ignored': [],
        })
        for snapshot_key, snapshot_data in self.provisions.all_snapshots.items():
            if snapshot_data.ignored == True:
                classified_snapshots.ignored.append(snapshot_data.id)
            elif not self.is_older_than_days(snapshot_data.get('updated_at')):
                pass
            else:
                status = snapshot_data.status.lower() if snapshot_data.status else None
                if status == 'error':
                    classified_snapshots.error.append(snapshot_data.id)
                elif status == 'error_deleting':
                    classified_snapshots.error_deleting.append(snapshot_data.id)
                elif status == 'available':
                    classified_snapshots.available.append(snapshot_data.id)
                elif not status or status not in self.snapshot_known_statuses:
                    classified_snapshots.other.append(snapshot_data.id)
        classified_snapshots['stats'] = Munch({
            'error': len(classified_snapshots.error),
            'error_deleting': len(classified_snapshots.error_deleting),
            'available': len(classified_snapshots.available),
            'other': len(classified_snapshots.other),
            'ignored': len(classified_snapshots.ignored),
        })

        return classified_snapshots

    def get_monitor_status_volumes(self):
        v = self.get_classified_volumes()
        self.classified_volumes = v

        error_count = v.stats.error + v.stats.error_deleting + v.stats.error_restoring + v.stats.error_backing_up + v.stats.error_extending
        if error_count > self.args.level_critical or v.stats.other > 0:
            level = "critical"
        elif error_count > self.args.level_warning or v.stats.unattached > self.args.level_warning or v.stats.noproject > 0:
            level = "warning"
        else:
            level = "ok"

        self.exit_code_stats = " ".join([
            f"error: {v.stats.error}",
            f"error_deleting: {v.stats.error_deleting}",
            f"error_restoring: {v.stats.error_restoring}",
            f"error_backing_up: {v.stats.error_backing_up}",
            f"error_extending: {v.stats.error_extending}",
            f"unattached: {v.stats.unattached}",
            f"noproject: {v.stats.noproject}",
            f"other: {v.stats.other}",
            f"ignored: {v.stats.ignored}",
        ])
        perfdata = format_perfdata([
            ('errors', error_count, self.args.level_warning, self.args.level_critical, 0, None),
            ('error', v.stats.error, None, None, 0, None),
            ('error_deleting', v.stats.error_deleting, None, None, 0, None),
            ('error_restoring', v.stats.error_restoring, None, None, 0, None),
            ('error_backing_up', v.stats.error_backing_up, None, None, 0, None),
            ('error_extending', v.stats.error_extending, None, None, 0, None),
            ('unattached', v.stats.unattached, self.args.level_warning, None, 0, None),
            ('noproject', v.stats.noproject, 0, None, 0, None),
            ('other', v.stats.other, None, 0, 0, None),
            ('ignored', v.stats.ignored, None, None, 0, None),
        ])
        result = self.get_exit_code(level)
        print(f"{result.description} | {perfdata}")
        days_suffix = f"older than {self.args.days} days" if self.args.days > 0 else "all ages"
        if self.args.show_all:
            self.provisions.show_all_volumes(days_suffix=days_suffix)
        elif self.args.show_filtered:
            problem_ids = set(v.error + v.error_deleting + v.error_restoring + v.error_backing_up + v.error_extending + v.unattached + v.noproject + v.other)
            self.provisions.show_all_volumes(filter_ids=problem_ids, days_suffix=days_suffix)
        sys.exit(result.code)

    def get_monitor_status_ports(self):
        self.classified_ports = self.get_classified_ports()
        p = self.classified_ports
        if p.stats.down_active > self.args.level_critical or p.stats.other > 0:
            level = "critical"
        elif p.stats.down_active > self.args.level_warning or p.stats.admin_down_attached > self.args.level_warning or p.stats.detached > self.args.level_warning:
            level = "warning"
        else:
            level = "ok"

        self.exit_code_stats = " ".join([
            f"down_active: {p.stats.down_active}",
            f"admin_down_attached: {p.stats.admin_down_attached}",
            f"detached: {p.stats.detached}",
            f"other: {p.stats.other}",
            f"ignored: {p.stats.ignored}",
        ])
        perfdata = format_perfdata([
            ('down_active', p.stats.down_active, self.args.level_warning, self.args.level_critical, 0, None),
            ('admin_down_attached', p.stats.admin_down_attached, self.args.level_warning, None, 0, None),
            ('detached', p.stats.detached, self.args.level_warning, None, 0, None),
            ('other', p.stats.other, None, 0, 0, None),
            ('ignored', p.stats.ignored, None, None, 0, None),
        ])
        result = self.get_exit_code(level)
        print(f"{result.description} | {perfdata}")
        days_suffix = f"older than {self.args.days} days" if self.args.days > 0 else "all ages"
        if self.args.show_all:
            self.provisions.show_all_ports(days_suffix=days_suffix)
        elif self.args.show_filtered:
            problem_ids = set(p.down_active + p.admin_down_attached + p.detached + p.other)
            self.provisions.show_all_ports(filter_ids=problem_ids, days_suffix=days_suffix)
        sys.exit(result.code)

    def get_monitor_status_servers(self):
        s = self.get_classified_servers()
        self.classified_servers = s

        not_running = s.stats.stopped + s.stats.paused + s.stats.suspended + s.stats.shelved + s.stats.soft_deleted
        if s.stats.error > self.args.level_critical or s.stats.rescued > 0 or s.stats.other > 0:
            level = "critical"
        elif s.stats.error > self.args.level_warning or not_running > self.args.level_warning:
            level = "warning"
        else:
            level = "ok"

        self.exit_code_stats = " ".join([
            f"error: {s.stats.error}",
            f"rescued: {s.stats.rescued}",
            f"stopped: {s.stats.stopped}",
            f"paused: {s.stats.paused}",
            f"suspended: {s.stats.suspended}",
            f"shelved: {s.stats.shelved}",
            f"soft_deleted: {s.stats.soft_deleted}",
            f"other: {s.stats.other}",
            f"ignored: {s.stats.ignored}",
        ])
        perfdata = format_perfdata([
            ('error', s.stats.error, self.args.level_warning, self.args.level_critical, 0, None),
            ('rescued', s.stats.rescued, None, 0, 0, None),
            ('not_running', not_running, self.args.level_warning, None, 0, None),
            ('stopped', s.stats.stopped, None, None, 0, None),
            ('paused', s.stats.paused, None, None, 0, None),
            ('suspended', s.stats.suspended, None, None, 0, None),
            ('shelved', s.stats.shelved, None, None, 0, None),
            ('soft_deleted', s.stats.soft_deleted, None, None, 0, None),
            ('other', s.stats.other, None, 0, 0, None),
            ('ignored', s.stats.ignored, None, None, 0, None),
        ])
        result = self.get_exit_code(level)
        print(f"{result.description} | {perfdata}")
        days_suffix = f"older than {self.args.days} days" if self.args.days > 0 else "all ages"
        if self.args.show_all:
            self.provisions.show_all_servers(days_suffix=days_suffix)
        elif self.args.show_filtered:
            problem_ids = set(s.error + s.rescued + s.stopped + s.paused + s.suspended + s.shelved + s.soft_deleted + s.other)
            self.provisions.show_all_servers(filter_ids=problem_ids, days_suffix=days_suffix)
        sys.exit(result.code)

    def get_monitor_status_snapshots(self):
        sn = self.get_classified_snapshots()
        self.classified_snapshots = sn

        error_count = sn.stats.error + sn.stats.error_deleting
        if error_count > self.args.level_critical or sn.stats.other > 0:
            level = "critical"
        elif error_count > self.args.level_warning or sn.stats.available > self.args.level_warning:
            level = "warning"
        else:
            level = "ok"

        self.exit_code_stats = " ".join([
            f"error: {sn.stats.error}",
            f"error_deleting: {sn.stats.error_deleting}",
            f"available: {sn.stats.available}",
            f"other: {sn.stats.other}",
            f"ignored: {sn.stats.ignored}",
        ])
        perfdata = format_perfdata([
            ('errors', error_count, self.args.level_warning, self.args.level_critical, 0, None),
            ('error', sn.stats.error, None, None, 0, None),
            ('error_deleting', sn.stats.error_deleting, None, None, 0, None),
            ('available', sn.stats.available, self.args.level_warning, None, 0, None),
            ('other', sn.stats.other, None, 0, 0, None),
            ('ignored', sn.stats.ignored, None, None, 0, None),
        ])
        result = self.get_exit_code(level)
        print(f"{result.description} | {perfdata}")
        days_suffix = f"older than {self.args.days} days" if self.args.days > 0 else "all ages"
        if self.args.show_all:
            self.provisions.show_all_snapshots(days_suffix=days_suffix)
        elif self.args.show_filtered:
            problem_ids = set(sn.error + sn.error_deleting + sn.available + sn.other)
            self.provisions.show_all_snapshots(filter_ids=problem_ids, days_suffix=days_suffix)
        sys.exit(result.code)

    def _resolve_host_thresholds(self, host_name, kind):
        '''
        Per-hypervisor (warning, critical) allocation %. Priority: file
        projects:<name> (strictest if several) > file defaults: > CLI. 0 = disabled.
        '''
        tf = getattr(self.provisions, 'project_thresholds', {}) or {}
        def_cfg = ((tf.get('defaults') or {}).get(kind)) or {}
        def_w = int(def_cfg.get('warning', self.args.level_warning) or 0)
        def_c = int(def_cfg.get('critical', self.args.level_critical) or 0)
        info = getattr(self.provisions, 'host_aggregates', munchify({})).get(host_key(host_name))
        projects = list(info.projects) if info and info.projects else []
        if not projects:
            return def_w, def_c
        projcfg = tf.get('projects') or {}
        warns, crits = [], []
        for p in projects:
            pc = ((projcfg.get(p) or {}).get(kind)) or {}
            warns.append(int(pc.get('warning', def_w) or 0))
            crits.append(int(pc.get('critical', def_c) or 0))

        def strictest(vals):
            pos = [v for v in vals if v > 0]
            return min(pos) if pos else 0
        return strictest(warns), strictest(crits)

    def get_classified_allocation(self, kind):
        '''
        Classify hypervisors by RAM or vCPU allocation %, thresholds resolved
        per host via _resolve_host_thresholds. No age filtering (no updated_at).
        '''
        classified = Munch({
            'critical': [],   # allocation % > --critical
            'warning': [],    # allocation % > --warning
            'down': [],       # state != 'up' AND not disabled — unexpected failure
            'disabled': [],   # status == 'disabled' (admin-disabled), up or down — intentional
            'unknown': [],    # no usage data (e.g. Nova microversion >= 2.88)
            'ignored': [],
        })
        details = {}
        total_used = 0
        total_capacity = 0
        for compute_key, hv in self.provisions.all_compute.items():
            name = hv.get('name') or compute_key
            if hv.get('ignored') == True:
                classified.ignored.append(name)
                continue
            state = (hv.get('state') or '').lower()
            status = (hv.get('status') or '').lower()
            if kind == 'ram':
                used = hv.get('memory_used') or 0
                capacity = hv.get('memory_size') or 0
            else:
                used = hv.get('vcpus_used') or 0
                capacity = hv.get('vcpus') or 0
            total_used += used
            total_capacity += capacity
            pct = round(used / capacity * 100, 1) if capacity else None
            warn, crit = self._resolve_host_thresholds(name, kind)
            details[name] = Munch({'used': used, 'capacity': capacity, 'pct': pct,
                                   'state': state, 'status': status,
                                   'running_vms': hv.get('running_vms'),
                                   'warn': warn, 'crit': crit})
            # Policy: an admin-disabled hypervisor is INTENTIONALLY out of service,
            # so it is a WARNING even when also down. CRITICAL is reserved for a host
            # that is down WITHOUT being disabled — i.e. an unexpected failure.
            if status == 'disabled':
                classified.disabled.append(name)
            elif state and state != 'up':
                classified.down.append(name)
            if pct is None:
                classified.unknown.append(name)
            elif crit > 0 and pct > crit:
                classified.critical.append(name)
            elif warn > 0 and pct > warn:
                classified.warning.append(name)
        classified['details'] = details
        classified['cluster'] = Munch({
            'used': total_used,
            'capacity': total_capacity,
            'pct': round(total_used / total_capacity * 100, 1) if total_capacity else 0,
        })
        classified['stats'] = Munch({
            'critical': len(classified.critical),
            'warning': len(classified.warning),
            'down': len(classified.down),
            'disabled': len(classified.disabled),
            'unknown': len(classified.unknown),
            'ignored': len(classified.ignored),
            'hosts': len(details),
        })
        return classified

    def _monitor_status_allocation(self, kind):
        c = self.get_classified_allocation(kind)
        if kind == 'ram':
            self.classified_ram = c
            alloc_label = 'ram_alloc'
            # RAM in MB (a standard Nagios UOM); the table shows GB for humans.
            capacity_metrics = [
                ('ram_used', f"{c.cluster.used}MB", None, None, 0, None),
                ('ram_total', f"{c.cluster.capacity}MB", None, None, 0, None),
            ]
        else:
            self.classified_cpu = c
            alloc_label = 'vcpu_alloc'
            capacity_metrics = [
                ('vcpus_used', c.cluster.used, None, None, 0, None),
                ('vcpus_total', c.cluster.capacity, None, None, 0, None),
            ]

        if c.stats.critical > 0 or c.stats.down > 0 or c.stats.unknown > 0:
            level = "critical"
        elif c.stats.warning > 0 or c.stats.disabled > 0:
            level = "warning"
        else:
            level = "ok"

        noun = "RAM" if kind == 'ram' else "vCPU"

        # Peak host (highest single-host allocation) — the number that actually
        # relates to the alert, unlike the cluster-wide weighted average.
        peak_name, peak_pct = None, None
        for n, d in c.details.items():
            if d.pct is not None and (peak_pct is None or d.pct > peak_pct):
                peak_name, peak_pct = n, d.pct
        peak_str = f"{short_host(peak_name)} {peak_pct}%" if peak_name is not None else "n/a"

        # Name the hosts that actually caused the current level, capped for length.
        if level == "critical":
            offenders = list(dict.fromkeys(c.critical + c.down + c.unknown))
        elif level == "warning":
            offenders = list(dict.fromkeys(c.warning + c.disabled))
        else:
            offenders = []
        cap = 10
        # Just the host names — compact and uniform. Which project/aggregate a host
        # belongs to is in the --show-all/--show-filtered table, not the status line.
        offender_names = [short_host(n) for n in offenders]
        if len(offender_names) > cap:
            offender_str = ", ".join(offender_names[:cap]) + f", +{len(offender_names) - cap} more"
        else:
            offender_str = ", ".join(offender_names)

        self.exit_code_stats = (
            f"{noun}: {c.stats.critical} critical, {c.stats.warning} warning, "
            f"down: {c.stats.down}, unknown: {c.stats.unknown}, peak: {peak_str}, "
            f"cluster avg: {c.cluster.pct}%, hosts: {c.stats.hosts}"
        )
        if offender_str:
            self.exit_code_stats += f" — affected: {offender_str}"

        # The cluster-average metric carries the CLI thresholds (a global
        # reference); 0 means "disabled" -> omitted from perfdata.
        cluster_warn = self.args.level_warning or None
        cluster_crit = self.args.level_critical or None
        metrics = [(alloc_label, f"{c.cluster.pct}%", cluster_warn, cluster_crit, 0, None)]
        metrics += capacity_metrics
        metrics += [
            ('hosts_down', c.stats.down, None, 0, 0, None),
            ('hosts_disabled', c.stats.disabled, 0, None, 0, None),
            ('hosts_unknown', c.stats.unknown, None, 0, 0, None),
        ]
        # Per-hypervisor allocation %, each carrying ITS OWN resolved thresholds
        # (which differ for project-dedicated hosts), so each node graphs separately.
        for name in sorted(c.details.keys()):
            d = c.details[name]
            if d.pct is not None:
                metrics.append((short_host(name), f"{d.pct}%",
                                d.warn or None, d.crit or None, 0, None))
        perfdata = format_perfdata(metrics)

        result = self.get_exit_code(level)
        print(f"{result.description} | {perfdata}")
        if self.args.show_all:
            self.provisions.show_all_allocation(kind)
        elif self.args.show_filtered:
            problem_ids = set(c.critical + c.warning + c.down + c.disabled + c.unknown)
            self.provisions.show_all_allocation(kind, filter_ids=problem_ids)
        if self.args.show_all or self.args.show_filtered:
            # Show the loaded per-project thresholds (only when a file was given).
            self.provisions.show_thresholds_config()
        sys.exit(result.code)

    def get_classified_quota(self):
        '''
        Classify projects by quota vs usage. Projects matching
        --quota-strict-pattern must be 1:1 (free == 0 on every resource); the rest
        are checked against --warning/--critical as usage PERCENTAGES.
        '''
        classified = Munch({
            'over': [],        # strict: used > quota — over its quota
            'free': [],        # strict: quota > used — reserved but unused
            'unlimited': [],   # any project: quota -1, never expected
            'critical': [],    # non-strict: usage % > --critical
            'warning': [],     # non-strict: usage % > --warning
            'failed': [],      # a quota query failed, or reported no usable number
            'ignored': list(getattr(self.provisions, 'quota_ignored', [])),
        })
        details = {}
        deviations = {}
        # Aggregate strict drift per resource, so perfdata stays bounded (a few
        # metrics) instead of one metric per project per resource.
        resources = selected_quota_resources(self.args)
        drift = Munch({res.key: Munch({'free': 0, 'over': 0}) for res in resources})

        for pid, entry in self.provisions.project_quotas.items():
            reasons = []
            graded = 0   # resources actually evaluated, to tell 'ok' from 'not graded'
            if entry.error:
                classified.failed.append(pid)
                reasons.append('quota query failed')
            for res in resources:
                pair = entry[res.key]
                if pair.quota is None or pair.used is None:
                    # No number and no explicit API error: a missing value must not
                    # read as compliant, so it counts as a failed check instead.
                    if not entry.error:
                        if pid not in classified.failed:
                            classified.failed.append(pid)
                        reasons.append(f"{res.key} no data")
                    continue
                if is_unlimited(pair.quota):
                    # No project is expected to have an unlimited quota: a strict one
                    # can never be 1:1, and any project without a ceiling can consume
                    # the whole cloud without ever breaching a percentage threshold.
                    if pid not in classified.unlimited:
                        classified.unlimited.append(pid)
                    reasons.append(f"{res.key} unlimited")
                    continue
                if entry.strict:
                    free = quota_free(pair)
                    if free is None:
                        continue
                    graded += 1
                    if free > 0:
                        if pid not in classified.free:
                            classified.free.append(pid)
                        drift[res.key].free += free
                        reasons.append(f"{res.key} +{fmt_amount(free, res.unit_div)} free")
                    elif free < 0:
                        if pid not in classified.over:
                            classified.over.append(pid)
                        drift[res.key].over += -free
                        reasons.append(f"{res.key} {fmt_amount(free, res.unit_div)} over")
                else:
                    pct = self._quota_pct(pair)
                    if pct is None:
                        continue
                    graded += 1
                    # The level is tagged onto the reason: without it a critical and a
                    # warning breach read identically in the 'deviation' column.
                    if self.args.level_critical > 0 and pct > self.args.level_critical:
                        if pid not in classified.critical:
                            classified.critical.append(pid)
                        reasons.append(f"{res.key} {pct}% crit")
                    elif self.args.level_warning > 0 and pct > self.args.level_warning:
                        if pid not in classified.warning:
                            classified.warning.append(pid)
                        reasons.append(f"{res.key} {pct}% warn")
            details[pid] = entry
            if reasons:
                deviations[pid] = ", ".join(reasons)
            else:
                # 'ok' must mean "checked and compliant", never "nothing was checked"
                # (a quota of 0 leaves no percentage to grade).
                deviations[pid] = 'ok' if graded else 'not graded'

        classified['details'] = details
        classified['deviations'] = deviations
        classified['drift'] = drift
        classified['stats'] = Munch({
            'over': len(classified.over),
            'free': len(classified.free),
            'unlimited': len(classified.unlimited),
            'critical': len(classified.critical),
            'warning': len(classified.warning),
            'failed': len(classified.failed),
            'ignored': len(classified.ignored),
            'projects': len(details),
            'strict': sum(1 for e in details.values() if e.strict),
        })
        return classified

    @staticmethod
    def _quota_pct(pair):
        '''Usage % for a non-strict project, or None when no quota is enforced.'''
        if pair.quota is None or pair.used is None or is_unlimited(pair.quota):
            return None
        if int(pair.quota) == 0:
            return None
        return round(int(pair.used) / int(pair.quota) * 100, 1)

    def get_monitor_status_quota(self):
        q = self.get_classified_quota()
        self.classified_quota = q

        # A strict project over its quota, or ANY project with an unlimited quota, is
        # a real provisioning fault -> CRITICAL. Quota reserved but unused is
        # capacity drift -> WARNING, alongside partial query failures.
        if q.stats.over > 0 or q.stats.unlimited > 0 or q.stats.critical > 0:
            level = "critical"
        elif q.stats.free > 0 or q.stats.warning > 0 or q.stats.failed > 0:
            level = "warning"
        else:
            level = "ok"

        # Only strict projects can breach 1:1, so a non-strict project caught by the
        # cloud-wide unlimited rule must not inflate this count.
        strict_violations = len({pid for pid in set(q.over + q.free + q.unlimited)
                                 if q.details[pid].strict})
        offenders = list(dict.fromkeys(
            q.over + q.unlimited + q.critical + q.free + q.warning + q.failed))
        cap = 10
        names = [q.details[pid].name for pid in offenders]
        if len(names) > cap:
            offender_str = ", ".join(names[:cap]) + f", +{len(names) - cap} more"
        else:
            offender_str = ", ".join(names)

        self.exit_code_stats = (
            f"quota: {strict_violations} of {q.stats.strict} strict projects not 1:1 "
            f"(over: {q.stats.over}, free: {q.stats.free}), "
            f"unlimited: {q.stats.unlimited}, "
            f"threshold: {q.stats.critical} critical, {q.stats.warning} warning, "
            f"failed: {q.stats.failed}, ignored: {q.stats.ignored}, "
            f"projects: {q.stats.projects}"
        )
        if offender_str:
            self.exit_code_stats += f" — affected: {offender_str}"

        # Bounded summary perfdata: counts plus total strict drift per resource.
        # Deliberately NOT per-project — that would be one metric per project per resource.
        metrics = [
            ('strict_violations', strict_violations, 0, 0, 0, None),
            ('strict_over', q.stats.over, None, 0, 0, None),
            ('strict_free', q.stats.free, 0, None, 0, None),
            ('unlimited', q.stats.unlimited, None, 0, 0, None),
            ('projects_critical', q.stats.critical, None, 0, 0, None),
            ('projects_warning', q.stats.warning, 0, None, 0, None),
            ('projects_failed', q.stats.failed, 0, None, 0, None),
            ('ignored', q.stats.ignored, None, None, 0, None),
            ('projects_checked', q.stats.projects, None, None, 0, None),
        ]
        for res in selected_quota_resources(self.args):
            # RAM stays in MB (a standard Nagios UOM); the table renders GB.
            uom = 'MB' if res.key == 'ram' else ''
            metrics.append((f"free_{res.key}", f"{q.drift[res.key].free}{uom}",
                            None, None, 0, None))
            metrics.append((f"over_{res.key}", f"{q.drift[res.key].over}{uom}",
                            None, None, 0, None))
        perfdata = format_perfdata(metrics)

        result = self.get_exit_code(level)
        print(f"{result.description} | {perfdata}")
        if self.args.show_all:
            self.provisions.show_all_quota(deviations=q.deviations)
        elif self.args.show_filtered:
            self.provisions.show_all_quota(filter_ids=set(offenders), deviations=q.deviations)
        sys.exit(result.code)

    def get_monitor_status_ram(self):
        self._monitor_status_allocation('ram')

    def get_monitor_status_cpu(self):
        self._monitor_status_allocation('cpu')


def main():
    if args.debug:
        print(f"Args: {args}", file=sys.stderr)

    if args.thresholds_file and args.monitor not in ('ram', 'cpu'):
        print("UNKNOWN - --thresholds-file is only valid with --monitor ram|cpu",
              file=sys.stderr)
        sys.exit(3)

    if args.monitor == 'quota':
        if args.quota_scope != 'all' and not args.quota_strict_pattern:
            print("UNKNOWN - --quota-scope strict|threshold needs --quota-strict-pattern",
                  file=sys.stderr)
            sys.exit(3)
        try:
            re.compile(args.quota_strict_pattern or '')
        except re.error as err:
            print(f"UNKNOWN - --quota-strict-pattern is not a valid regex: {err}",
                  file=sys.stderr)
            sys.exit(3)
        if args.jobs < 1:
            print("UNKNOWN - --jobs must be at least 1", file=sys.stderr)
            sys.exit(3)
        known = [res.key for res in QUOTA_RESOURCES]
        unknown = [r for r in (args.quota_resources or []) if r not in known]
        if unknown:
            print(f"UNKNOWN - --quota-resources has unknown name(s) {','.join(unknown)}; "
                  f"valid: {','.join(known)}", file=sys.stderr)
            sys.exit(3)
        if args.quota_resources is not None and not args.quota_resources:
            print(f"UNKNOWN - --quota-resources selected nothing; valid: {','.join(known)}",
                  file=sys.stderr)
            sys.exit(3)

    try:
        provisions = OpenStackProvisions(config, args)
    except openstack.exceptions.SDKException as err:
        # Auth/HTTP failures surface lazily on the first API call; map any
        # OpenStack SDK error to UNKNOWN(3) so the check never reports a
        # misleading WARNING (exit 1) from an unhandled traceback.
        print(f"UNKNOWN - OpenStack API error: {err}", file=sys.stderr)
        sys.exit(3)

    monitor = OpenStackProvisionsMonitoring(config, args, provisions)

    if args.monitor == "volumes":
        monitor.get_monitor_status_volumes()
    elif args.monitor == "ports":
        monitor.get_monitor_status_ports()
    elif args.monitor == "servers":
        monitor.get_monitor_status_servers()
    elif args.monitor == "snapshots":
        monitor.get_monitor_status_snapshots()
    elif args.monitor == "ram":
        monitor.get_monitor_status_ram()
    elif args.monitor == "cpu":
        monitor.get_monitor_status_cpu()
    elif args.monitor == "quota":
        monitor.get_monitor_status_quota()
    else:
        print("UNKNOWN - no --monitor selected (nothing to check)", file=sys.stderr)
        sys.exit(3)


if __name__=="__main__":
    main()
