#!/usr/bin/env python

import urllib3
import json
import argparse
import sys

def get_data(http, baseurl, call): 
    url = '{}{}'.format(baseurl, call)

    try:
        request = http.request('GET', url)
    except Exception as e:
        print 'CRITICAL: unable to connect to solr'
        print e
        sys.exit(2)

    data = json.loads(request.data.decode('utf8'))

    return data

def get_ping(http, baseurl, core):
    path = '/{}/admin/ping?wt=json&ident=true'.format(core)

    ping = get_data(http, baseurl, path)

    return ping

def get_cores(http, baseurl):
    path = '/admin/cores?action=status&wt=json'

    cores = get_data(http, baseurl, path)

    return cores

def get_replication(http, baseurl, core):
    path = '/{}/replication?command=details&wt=json'.format(core)
    
    repl = get_data(http, baseurl, path)

    return repl

def output_ping(http, baseurl, extended):
    # Should get cores first
    cores = get_cores(http, baseurl)

    state = 0
    okCores = []
    nokCores = []
    outputE = ''

    for k, c in cores['status'].items():
        size = c['index']['sizeInBytes']
        numdocs = c['index']['numDocs']
        uptime = c['uptime']
        status = get_ping(http, baseurl, k)

        if status['status'] != 'OK':
            state = 2
            nokCores.append(k)
        else:
            okCores.append(k)

        outputE += '\n{} - Status: {} | {}_size={}B {}_numdocs={} {}_uptime={}s'.format(k, status['status'], k, size, k, numdocs, k, uptime)

    if state == 2:
        print 'CRITICAL: couldn\'t ping {} cores'.format(','.join(nokCores))
    else:
        print 'OK: {} ping correctly'.format(','.join(okCores))
       
    if extended:
        print outputE
    
    sys.exit(state)

def output_replication_master(http, baseurl, extended):
    # Should get cores first
    cores = get_cores(http, baseurl)

    state = 0
    okCores = []
    nokCores = []
    outputE = ''

    for k, c in cores['status'].items():
        repl = get_replication(http, baseurl, k)

        master = repl['details']['isMaster']
        enabled = repl['details']['master']['replicationEnabled']

        if master != "true" or enabled != "true":
            state = 2
            nokCores.append(k)
        else:
            okCores.append(k)

        outputE += '\n{} - isMaster: {} -- replicationEnabled: {}'.format(k, master, enabled)

    if state == 2:
        print 'CRITICAL: {} are not masters/replication disabled'.format(','.join(nokCores))
    else:
        print 'OK: {} are all master & replicating!'.format(','.join(okCores))

    if extended:
        print outputE

    sys.exit(state)

def output_replication_slave(http, baseurl, extended, warn, critical):
    # Should get cores first
    cores = get_cores(http, baseurl)

    state = 0
    okCores = []
    nokCores = []
    outputE = ''

    for k, c in cores['status'].items():
        repl = get_replication(http, baseurl, k)

        slave = repl['details']['isSlave']
        slaveIndex = repl['details']['indexVersion']
        slaveGen = repl['details']['generation']
        masterIndex = repl['details']['slave']['masterDetails']['master']['replicableVersion']
        masterGen = repl['details']['slave']['masterDetails']['master']['replicableGeneration']

        enabled = repl['details']['slave']['masterDetails']['master']['replicationEnabled']

        if (masterGen - slaveGen) >= critical or slave != "true" or enabled != "true":
            state = 2
            nokCores.append(k)
        elif (masterGen - slaveGen) >= warn:
            nokCores.append(k)
            if state == 0:
                state = 1
        else:
            okCores.append(k)

        outputE += '\n{}\t - isSlave: {}\treplicationEnabled: {}\tSlaveIndex: {}\tMasterIndex: {}\tSlaveGen: {}\tMasterGen: {} | {}_slaveindex={} {}_masterindex={} {}_slavegen={} {}_mastergen={}'.format(
                k, slave, enabled,
                slaveIndex, masterIndex, slaveGen, masterGen,
                k, slaveIndex, k, masterIndex, k, slaveGen, k, masterGen)

    if state == 2:
        print 'CRITICAL: {} are not slaves/replication disabled'.format(','.join(nokCores))
    elif state == 1:
        print 'WARNING: {} is delayed!'.format(','.join(nokCores))
    else:
        print 'OK: {} are all slaves & replicating!'.format(','.join(okCores))

    if extended:
        print outputE

    sys.exit(state)

def output_compare(http, baseurl, baseurl2, extended):
    # Cores of server1
    cores1 = get_cores(http, baseurl)
    coresL1 = set()

    for k in cores1['status']:
        coresL1.add(k)

    # Cores of server2
    cores2 = get_cores(http, baseurl2)
    coresL2 = set()

    for k in cores2['status']:
        coresL2.add(k)
    
    intersect = coresL1 ^ coresL2

    state = 0
    if len(intersect) > 0:
        print 'CRITICAL: {} core(s) is/are not on both solr servers | count={}'.format(','.join(intersect), len(intersect))
        state = 2
    else:
        print 'OK: all cores exist on both servers | count={}'.format(len(intersect))
       
    sys.exit(state)


def main():
    parser = argparse.ArgumentParser(description='check_solr Nagios plugin')

    parser.add_argument('-H', '--host', help='Hostname of the solr server', required=True)
    parser.add_argument('-p', '--port', help='Port of the solr server', default=8983, type=int)
    parser.add_argument('-W', '--path', help='Path to the solr instance', default='solr')
    parser.add_argument('-t', '--timeout', help='timeout', default=15, type=int)
    parser.add_argument('--extended', help='Add extended info where possible', action='store_true')
    parser.add_argument('-P', '--ping', help='Ping the solr cores', action='store_true')
    parser.add_argument('-r', '--replication', help='Ping the solr cores', default='slave')
    parser.add_argument('-w', '--warning', help='Warning threshold for replication', default=1, type=int)
    parser.add_argument('-c', '--critical', help='Critical threshold for replication', default=3, type=int)
    parser.add_argument('-C', '--compare', help='Compare cores on 2 solr servers', action='store_true')
    parser.add_argument('--host2', help='Host to compare to')
    parser.add_argument('--port2', help='Port of host to compare to', default=8983, type=int)
    parser.add_argument('--path2', help='Path of host to compare to', default='solr')

    args = parser.parse_args()

    baseurl = 'http://{}:{}/{}'.format(args.host, args.port, args.path)
    http = urllib3.PoolManager(timeout=args.timeout, retries=False)

    try:
        if args.ping:
            output_ping(http, baseurl, args.extended)
        elif args.replication == 'master':
            output_replication_master(http, baseurl, args.extended)
        elif args.replication == 'slave' and not args.compare:
            output_replication_slave(http, baseurl, args.extended, args.warning, args.critical)
        elif args.compare:
            baseurl2 = 'http://{}:{}/{}'.format(args.host2, args.port2, args.path2)
            output_compare(http, baseurl, baseurl2, args.extended)
    except KeyError as e:
        print 'CRITICAL: unable to parse JSON. Possible SOLR issues!'
        print e
        sys.exit(2)
    except Exception as e:
        print 'UNKNOWN: exception when running check.'
        print e
        sys.exit(3)

if __name__ == "__main__":
    main()
