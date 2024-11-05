#!/bin/bash

#######################################################################
#                                                                     #
# This is a script that monitors Unbound DNS resolvers.               #
#                                                                     #
# The script uses unbound-control to check that Unbound is running,   #
# and to display the statistics as performace data. The oritginal     #
# script is forked from                                               #
# https://github.com/PanoramicRum/unbound-nagios-plugins              #
#                                                                     #
#                                                                     #
# Version 1.0 2024-11-05 Initial release                              #
#                                                                     #
# Licensed under the Apache License Version 2.0                       #
# Written by Valentin Dzhorov - vdzhorov@gmail.com                    #
#                                                                     #
#######################################################################


unboundcontrol="/usr/bin/docker exec -i unbound unbound-control stats"

# Help message
usage() {
  echo "Usage: $0 [options]"
  echo ""
  echo "Options:"
  echo "  -f, --filter ARGS         Filter the output by columns, passed as a string."
  echo "  -h, --help                Display this help message."
}

# Parse CLI options
while [[ "$#" -gt 0 ]]; do
  case $1 in
    -f|--filter) unbound_filter=${@:2}; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1"; usage; exit 1 ;;
  esac
  shift
done

# Main logic
if [ ${#unbound_filter[@]} -ne 0 ]; then
  cmd=$($unboundcontrol | grep -v thread | grep -v histogram | grep -v time. | sed 's/$/, /' | tr -d '\n' | tr ',' '\n' | grep $unbound_filter | tr '\n' ', ')
  cmd_perf_data=$($unboundcontrol | grep -v thread | grep -v histogram | grep -v time. | sed 's/$/;;; /' | tr -d '\n' | tr ',' '\n' | grep $unbound_filter | tr -d '\n')
  echo "$cmd | $cmd_perf_data"
else
  cmd=$($unboundcontrol | grep -v thread | grep -v histogram | grep -v time. | sed 's/$/, /' | tr -d '\n')
  cmd_perf_data=$($unboundcontrol | grep -v thread | grep -v histogram | grep -v time. | sed 's/$/;;; /' | tr -d '\n')
  echo "$cmd | $cmd_perf_data"
fi
