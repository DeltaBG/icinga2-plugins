#!/usr/bin/env python
############################################################################
# Copyright 2013 George Hansper                                            #
# This program has been made available to the Open Source community for    #
# redistribution and further development under the terms of the            #
# GNU General Public License v2: http://www.gnu.org/licenses/gpl-2.0.html  #
############################################################################
# This program is supplied 'as-is', in the hope that it will be useful,    #
# but the author does not make any warranties or guarantees as             #
# to its correct operation.                                                #
#                                                                          #
# Or in other words:                                                       #
#       Test it yourself, and make sure it works for YOU.                  #
############################################################################
# Author: George Hansper                     e-mail:  george@hansper.id.au #
# This plugin was originally based on check_cpu.py written by              #
# Kirk Hammond <kirkdhammond@gmail.com>                                    #
############################################################################

Version = "1.7 $Id$"

# import modules
import sys, getopt, time

#nagios return codes
UNKNOWN = 3
OK = 0
WARNING = 1
CRITICAL = 2

#Usage message
usage = """usage: ./check_cpu.py [-w num|--warn=num] [-c|--crit=num] [-W num |--io-warn=num] [-C num|--io-crit=num] [-p num|--period=num]
  -w, --warn     ... generate warning  if total cpu exceeds num (default: 95)
  -c, --crit     ... generate critical if total cpu exceeds num (default: 98)
  -W, --warn-any ... generate warning  if any single cpu exceeds num (default: 98)
  -C, --crit-any ... generate critical if any single cpu exceeds num (default: 100 (off))
  -i, --io-warn  ... generate warning  if any single cpu exceeds num in io_wait (default: 90)
  -I, --io-crit  ... generate critical if any single cpu exceeds num in io_wait (default: 98)
      --io-warn-overall ... generate warning  if overall cpu exceeds num in io_wait (default: 100 (off))
      --io-crit-overall ... generate critical if overall cpu exceeds num in io_wait (default: 100 (off))
  -s, --steal-warn  ... generate warning  if any single cpu exceeds num in steal (default: 30)
  -S, --steal-crit  ... generate critical if any single cpu exceeds num in steal (default: 80)
  -p, --period   ... sample cpu usage over num seconds
  -a, --abs      ... generate performance stats in cpu-ticks (jiffies), as well as percent
  -A, --abs-only ... generate performance stats in cpu-ticks (jiffies), instead of percent
  -v  --version  ... print version

Notes:
  Warning/critical alerts are generated when the threshold is exceeded
  eg -w 95 means alert on 96% and above
  All values are in percent, but no % symbol is required
  A warning/critical will also be generated if any single cpu exceeds a threshold. Specify 100 to disable. eg.
       check_cpu.py -W 100 -C 100 
  'total' includes io_wait and steal (ie. everything except idle)
"""

cpu_percent = dict()
io_wait_percent = dict()
steal_percent = dict()
cpu_id_list = []
ctxt_per_second = 0
processes_per_second = 0
cpu_stats_t1 = dict()
warn=95
crit=98
per_cpu_warn=98
per_cpu_crit=100  # Don't generate critical for a single CPU
io_warn=90
io_crit=98
io_warn_overall=100
io_crit_overall=100
steal_warn=30
steal_crit=80
proc_stat_file='/proc/stat'
sample_period = 1
perfdata_abs = 1

def get_procstat_now():
  global cpu_id_list
  global proc_stat_file
  cpu_id_list=[]
  cpu_stats = dict()
  procstat = open(proc_stat_file,'r')
  procstat_text = procstat.read()
  procstat.close()
  for line in procstat_text.split("\n"):
    if line.startswith('cpu '):
      [cpu_id,junk,cpu_ticks] = line.split(' ',2)
    elif line.startswith('cpu'):
      [cpu_id,cpu_ticks] = line.split(' ',1)
    elif line.startswith('ctxt '):
      cpu_stats['ctxt'] = line.split()[1]
      continue
    elif line.startswith('processes '):
      cpu_stats['processes'] = line.split()[1]
      continue
    else:
      continue
    # Fields are:
    # cpu user nice system idle io_wait hw_intr sw_intr steal guest guest_nice
    cpu_ticks_array = cpu_ticks.split()
    while len(cpu_ticks_array) < 10:
      cpu_ticks_array.append('0')
    [user,nice,system,idle,io_wait,hw_intr,sw_intr,steal,guest,guest_nice] = cpu_ticks_array
    cpu_usage = int(user)+int(nice)+int(system)+int(io_wait)+int(hw_intr)+int(sw_intr)+int(steal)+int(guest)+int(guest_nice)
    cpu_total_ticks = cpu_usage + int(idle)
    cpu_stats[cpu_id] = cpu_usage
    cpu_stats[cpu_id+'all'] = cpu_total_ticks
    cpu_stats[cpu_id+'io_wait'] = int(io_wait)
    cpu_stats[cpu_id+'steal'] = int(steal)
    cpu_id_list.append(cpu_id)
  return cpu_stats

# Calculate cpu use for all cpus
def get_cpu_stats():
  global cpu_id_list,cpu_percent,io_wait_percent,sample_period,steal_percent,cpu_stats_t1,ctxt_per_second,processes_per_second
  cpu_stats_t0 = dict()
  cpu_stats_t1 = dict()
  cpu_stats_t0 = get_procstat_now()
  time.sleep(sample_period)
  cpu_stats_t1 = get_procstat_now()
  for cpu_id in cpu_id_list:
    if ( cpu_stats_t1[cpu_id+'all'] - cpu_stats_t0[cpu_id+'all'] ) > 0 :
      # The normal case
      io_wait_percent[cpu_id] = int(( cpu_stats_t1[cpu_id+'io_wait'] - cpu_stats_t0[cpu_id+'io_wait'] ) * 100 / (cpu_stats_t1[cpu_id+'all'] - cpu_stats_t0[cpu_id+'all'] ))
      steal_percent[cpu_id] = int(( cpu_stats_t1[cpu_id+'steal'] - cpu_stats_t0[cpu_id+'steal'] ) * 100 / (cpu_stats_t1[cpu_id+'all'] - cpu_stats_t0[cpu_id+'all'] ))
      cpu_percent[cpu_id] = int(( cpu_stats_t1[cpu_id] - cpu_stats_t0[cpu_id] ) * 100 / (cpu_stats_t1[cpu_id+'all'] - cpu_stats_t0[cpu_id+'all'] ))
    else:
      # The case of a VM that has had no cpu cycles devoted to this CPU at all
      io_wait_percent[cpu_id] = 0
      steal_percent[cpu_id] = 0
      cpu_percent[cpu_id] = 0
  ctxt_per_second = ( float(cpu_stats_t1['ctxt']) - float(cpu_stats_t0['ctxt']) ) / sample_period
  processes_per_second = ( float(cpu_stats_t1['processes']) - float(cpu_stats_t0['processes']) ) / sample_period
  return 

# Build the performance data message
# See: https://nagios-plugins.org/doc/guidelines.html#AEN200
def performance_data():
  global warn,crit,io_warn,io_crit,cpu_id_list,cpu_percent,io_wait_percent,steal_percent,ctxt_per_second,processes_per_second
  perf_message_array = []
  if (perfdata_abs&1) == 1:
    for cpu_id in cpu_id_list:
      if cpu_id == 'cpu':
        perf_message_array.append(cpu_id +        '=' + str(cpu_percent[cpu_id])     + '%;' + str(warn)            + ';' + str(crit)+';0;' )
        perf_message_array.append(cpu_id + '_iowait=' + str(io_wait_percent[cpu_id]) + '%;' + str(io_warn_overall) + ';' + str(io_crit_overall)+';0;' )
        perf_message_array.append(cpu_id +  '_steal=' + str(steal_percent[cpu_id])   + '%;;;0;' )
      else:
        perf_message_array.append(cpu_id +        '=' + str(cpu_percent[cpu_id])     + '%;' + str(per_cpu_warn) + ';' + str(per_cpu_crit) + ';0;' )
        perf_message_array.append(cpu_id + '_iowait=' + str(io_wait_percent[cpu_id]) + '%;' + str(io_warn)      + ';' + str(io_crit) +';0;' )
        perf_message_array.append(cpu_id +  '_steal=' + str(steal_percent[cpu_id])   + '%;' + str(steal_warn)   + ';' + str(steal_crit) +';0;' )
  if (perfdata_abs&2) == 2:
    for cpu_id in cpu_id_list:
      perf_message_array.append(cpu_id +    '.all=' + str(cpu_stats_t1[cpu_id+'all'])     + 'c' )
      perf_message_array.append(cpu_id +   '.busy=' + str(cpu_stats_t1[cpu_id])           + 'c' )
      perf_message_array.append(cpu_id + '.iowait=' + str(cpu_stats_t1[cpu_id+'io_wait']) + 'c' )
      perf_message_array.append(cpu_id +  '.steal=' + str(cpu_stats_t1[cpu_id+'steal'])   + 'c' )
    perf_message_array.append('ctxt='       + str(cpu_stats_t1['ctxt'])           + 'c' )
    perf_message_array.append('procs='              + str(cpu_stats_t1['processes'])      + 'c' )
  return " ".join(perf_message_array)

# Build the status message (service output message) and set the exit code
def check_status():
  global warn,crit,io_warn,io_crit,per_cpu_warn,per_cpu_crit,cpu_id_list,cpu_percent,io_wait_percent,steal_percent
  result = 0
  message = ''
  for cpu_id in cpu_id_list:
    if cpu_id == 'cpu':
      if cpu_percent[cpu_id] > crit:
        result |= 2
        message = 'Total=' + str(cpu_percent[cpu_id]) + '% > ' + str(crit)
      elif cpu_percent[cpu_id] > warn:
        result |= 1
        message = 'Total=' + str(cpu_percent[cpu_id]) + '% > ' + str(warn)
      else:
        message = 'Total=' + str(cpu_percent[cpu_id]) + '%'
      if io_wait_percent[cpu_id] > io_crit_overall:
        result |= 2
        message += ' IOwait=' + str(io_wait_percent[cpu_id]) + '% > ' + str(io_crit_overall)
      elif io_wait_percent[cpu_id] > io_warn_overall:
        result |= 1
        message += ' IOwait=' + str(io_wait_percent[cpu_id]) + '% > ' + str(io_warn_overall)
      else:
        message += ' IOwait=' + str(io_wait_percent[cpu_id]) + '%'
      message += ' Steal=' + str(steal_percent[cpu_id]) + '%'
    else:
      if cpu_percent[cpu_id] > per_cpu_crit:
        result |= 2
        message += ' CRIT: ' + cpu_id + '=' + str(cpu_percent[cpu_id]) +  '% > ' + str(per_cpu_crit)
      elif cpu_percent[cpu_id] > per_cpu_warn:
        result |= 1
        message += ' WARN: ' + cpu_id + '=' + str(cpu_percent[cpu_id]) +  '% > ' + str(per_cpu_warn)
      if io_wait_percent[cpu_id] > io_crit:
        result |= 2
        message += ' IO_CRIT: ' + cpu_id + '=' + str(io_wait_percent[cpu_id]) +  '% > ' + str(io_crit)
      elif io_wait_percent[cpu_id] > io_warn:
        result |= 1
        message += ' IO_WARN: ' + cpu_id + '=' + str(io_wait_percent[cpu_id]) +  '% > ' + str(io_warn)
      if steal_percent[cpu_id] > steal_crit:
        result |= 2
        message += ' STEAL_CRIT: ' + cpu_id + '=' + str(steal_percent[cpu_id]) +  '% > ' + str(steal_crit)
      elif steal_percent[cpu_id] > steal_warn:
        result |= 1
        message += ' STEAL_WARN: ' + cpu_id + '=' + str(steal_percent[cpu_id]) +  '% > ' + str(steal_warn)

  if result == 3 or result == 2:
    result = 2
    message = 'CRITICAL: ' + message
  elif result == 1:
    message = 'WARNING: ' + message
  else:
    message = 'OK: ' + message
  return (result,message)


# define command lnie options and validate data.  Show usage or provide info on required options
def command_line_validate(argv):
  global warn,crit,io_warn,io_crit,sample_period
  global io_warn_overall,io_crit_overall
  global proc_stat_file
  global per_cpu_warn,per_cpu_crit
  global steal_warn,steal_crit
  global perfdata_abs
  try:
    opts, args = getopt.getopt(argv, 'w:c:o:W:C:i:I:s:S:p:f:VaA', ['warn=' ,'crit=', 'warn-any=', 'crit-any=', 'io-warn=','io-crit=','io-warn-overall=','io-crit-overall=','steal-warn=','steal-crit=','period=','version','--abs'])
  except getopt.GetoptError:
    print(usage)
  try:
    for opt, arg in opts:
      arg = arg.rstrip('%')
      if opt in ('-w', '--warn'):
        try:
          warn = int(arg)
        except:
          print('***warn value must be an integer***')
          sys.exit(CRITICAL)
      elif opt in ('-c', '--crit'):
        try:
          crit = int(arg)
        except:
          print('***crit value must be an integer***')
      elif opt in ('-W', '--warn-any'):
        try:
          per_cpu_warn = int(arg)
        except:
          print('***warn-any value must be an integer***')
          sys.exit(CRITICAL)
      elif opt in ('-C', '--crit-any'):
        try:
          per_cpu_crit = int(arg)
        except:
          print('***crit-any value must be an integer***')
      elif opt in ('-i', '--io-warn'):
        try:
          io_warn = int(arg)
        except:
          print('***io-warn value must be an integer***')
      elif opt in ('-I', '--io-crit'):
        try:
          io_crit = int(arg)
        except:
          print('***io-crit value must be an integer***')
      elif opt in ('--io-warn-overall'):
        try:
          io_warn_overall = int(arg)
        except:
          print('***io-warn-overall value must be an integer***')
      elif opt in ('--io-crit-overall'):
        try:
          io_crit_overall = int(arg)
        except:
          print('***io-crit-overall value must be an integer***')
      elif opt in ('-s', '--steal-warn'):
        try:
          steal_warn = int(arg)
        except:
          print('***steal-warn value must be an integer***')
      elif opt in ('-S', '--steal-crit'):
        try:
          steal_crit = int(arg)
        except:
          print('***steal-crit value must be an integer***')
      elif opt in ('-p','--period'):
        try:
          sample_period = int(arg)
        except:
          print('***period value must be an integer***')
      elif opt in ('-a','--abs'):
        perfdata_abs = 3
      elif opt in ('-A','--abs-only'):
        perfdata_abs = 2
      elif opt in ('-f'):
        # Just for testing
        proc_stat_file = arg
      elif opt in ('-V','--version'):
        print(Version)
        sys.exit(WARNING)
      else:
        print(usage)
        sys.exit(WARNING)
  except:
    sys.exit(CRITICAL)
  # confirm that warning level is less than critical level, alert and exit if check fails
  if warn > crit:
    print('***warning level must be less than critical level***')
    sys.exit(CRITICAL)
  return

# main function
def main():
  argv = sys.argv[1:]
  # set crit,warn,io_crit,io_warn
  command_line_validate(argv)
  
  # Read the stats from /proc/stat - results are in cpu_percent[] and io_wait_percent[]
  get_cpu_stats()

  # Build the performance data message
  perf_message = performance_data()

  # Build the status message (service output message) and set the exit code
  (exit_code,result_message) = check_status()

  print(result_message + '|' + perf_message)
  sys.exit(exit_code)

if __name__ == '__main__':
  main()
