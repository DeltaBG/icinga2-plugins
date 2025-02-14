#!/usr/bin/python3
# -*- coding: UTF-8 -*-

import sys
sys.dont_write_bytecode = True

import argparse
import os
import subprocess
import re
from munch import munchify, Munch

config = {}
config['prog_name'] = str(os.path.basename(sys.argv[0]))

config = munchify(config)

# Define command line arguments
parser = argparse.ArgumentParser(prog=config.prog_name,
                                 description='Check DMESG OOM Killer logs',
                                 formatter_class=argparse.ArgumentDefaultsHelpFormatter,
                                 add_help=True,
                                 allow_abbrev=False,
                                 epilog="Check DMESG OOM Killer logs"
                                 )
parser.add_argument('--debug', action='store_true', dest='debug', required=False,
                    help='Debug mode'
                    )
parser.add_argument('--warning', action='store', dest='level_warning', required=False, type=int, default=0,
                    help='Set Warning level as percent value')
parser.add_argument('--critical', action='store', dest='level_critical', required=False, type=int, default=1,
                    help='Set Critical level as percent value')
parser.add_argument('--short', action='store_true', dest='short_check',
                    help="Check ignores DMESG OOM problems older then 24 hours")
parser.add_argument('--verbose', action='store_true', dest="verbose",
                    help='Show verbose output from demsg about OOM Killer events')
parser.add_argument('--exclude', action='store', dest="exclude", required=False, type=str,
                    help='Exclude process')

args = parser.parse_args()
# args = parser.parse_args(args=None if sys.argv[1:] else ['--help'])

known_args, leftovers = parser.parse_known_args()
known_args = munchify(known_args.__dict__)

config['level'] = {}
config['level']['warning'] = args.level_warning
config['level']['critical'] = args.level_critical

config['check'] = {}
config['check']['short'] = args.short_check
config['check']['verbose'] = args.verbose

config['oom_killer']={}
config['oom_killer']['check_command'] = "LC_ALL=C /bin/dmesg | /usr/bin/awk '/invoked oom-killer:/ || /Killed process/'"

config['exclude'] = []
if args.exclude:
    for indice in args.exclude.split(','):
        config['exclude'].append(indice.strip())

config = munchify(config)

if len(config.exclude) > 0:
    config['oom_killer']['check_command'] += " | grep -Evw '"
    for exclude in config.exclude:
       config['oom_killer']['check_command'] += exclude
       if exclude != config.exclude[-1]:
            config['oom_killer']['check_command'] += "|"

    config['oom_killer']['check_command'] += "'"

# execute commands
def execute_cmd(cmd_query):
    return subprocess.Popen(cmd_query, stdout=subprocess.PIPE, shell=True).stdout.read().strip().decode('utf8')


class OOMKillerMonitor:
    def __init__(self,config):
        self.config = config
        self.oom_killer_logs_count = self.check_oom_killer()

    def check_dmesg(self):
        return execute_cmd(cmd_query="dmesg > /dev/null; echo $?")

    def check_oom_killer(self):
        if self.check_dmesg() == "0":
            self.dmesg_logs = execute_cmd(cmd_query=self.config.oom_killer.check_command)
            dmesg_logs_list = str.split(self.dmesg_logs, '\n')
            counter = 0

            while '' in dmesg_logs_list:
                dmesg_logs_list.remove('')

            if (self.config.check.short):
                for line in dmesg_logs_list:
                    last_error = float(re.sub('[\[\]]', '', line.split()[0]))
                    with open('/proc/uptime', 'r') as f:
                        uptime_seconds = float(f.readline().split()[0])
                    if (uptime_seconds - last_error <= 86400):
                        counter += 1
            else:
                counter = len(dmesg_logs_list)
        else:
            counter = -1

        return counter

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

    def monitor_status(self):
        performance_data = ""
        if self.oom_killer_logs_count == -1:
            level = "unknown"
            self.exit_code_stats = f"check could not be performed"
        elif self.oom_killer_logs_count <= self.config.level.warning and self.oom_killer_logs_count < self.config.level.critical:
            level = "ok"
            self.exit_code_stats = f"There aren't any OOM Killer logs"
        elif self.oom_killer_logs_count > self.config.level.warning and self.oom_killer_logs_count < self.config.level.critical:
            level = "warning"
            self.exit_code_stats = f"There are {self.oom_killer_logs_count} OOM Killer logs"
            if self.config.check.verbose:
                self.exit_code_stats += f"\nLogs:\n{self.dmesg_logs}"
        elif self.oom_killer_logs_count > self.config.level.warning and self.oom_killer_logs_count >= self.config.level.critical:
            level = "critical"
            self.exit_code_stats = f"There are {self.oom_killer_logs_count} OOM Killer logs"
            if self.config.check.verbose:
                self.exit_code_stats += f"\nLogs:\n{self.dmesg_logs}"
        else:
            level = "unknown"
            self.exit_code_stats = f"Error! Check failed."

        performance_data = f"oom_killer_logs={self.oom_killer_logs_count}"
        print(f"{self.get_exit_code(level).description} | {performance_data}")
        sys.exit(self.get_exit_code(level).code)


def main():
    oom_killer_monitor = OOMKillerMonitor(config)

    oom_killer_monitor.monitor_status()


if __name__ == "__main__":
    main()
