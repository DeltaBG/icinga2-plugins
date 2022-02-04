#!/usr/bin/env python
# Version 0.0.2 - Feb/2022
# by Nedelin Petkov

import os
import re
import sys
import argparse

parser = argparse.ArgumentParser()
parser.add_argument('-s', '--shift', metavar='SHIFT', default=-15, help='Shifts the thresholds for critical and warning. Default: -15')
parser.add_argument('-e', '--exe', metavar='EXE', default='/usr/bin/sensors', help='Path to sensors. Default: /usr/bin/sensors')
args = parser.parse_args()

# Threshold shift
TSHIFT = float(args.shift)

# Path to sensors
SENSORS_BIN = args.exe

OK = 0
WARNING = 1
CRITICAL = 2
UNKNOWN = 3
STATE = "OK"
MESSAGE = "All sensors are normal."
GRAPHS = ""

if os.path.isfile(SENSORS_BIN) and os.access(SENSORS_BIN, os.X_OK):

    _current_cpu = "0"

    stream = os.popen(SENSORS_BIN)
    output = stream.read()

    output_regex = re.compile(r'^(.*):.*(\+[0-9]+.[0-9]).*\(high.*(\+[0-9]+.[0-9]).*crit.*(\+[0-9]+.[0-9]).*\)', re.MULTILINE)

    for line in output_regex.findall(output):
        if line[0].startswith('Physical id'):
            _current_cpu = re.search("Physical id ([0-9]+)", line[0]).group(1)
        if line[0].startswith('Core'):
            sensor = "CPU" + _current_cpu + "_" + line[0].replace(" ", "")
        else:
            sensor = line[0].replace(" ", "_")
        temp = float(line[1])
        warn = float(line[2]) + TSHIFT
        crit = float(line[3]) + TSHIFT

        GRAPHS = GRAPHS + sensor + "=" + str(temp) + ";" + str(warn) + ";" + str(crit) + "; "

        if warn <= temp < crit and STATE != "CRITICAL":
            STATE = "WARNING"
            MESSAGE = "Some of the sensors are above the warning level, but are not yet critical."

        elif temp >= crit:
            STATE = "CRITICAL"
            MESSAGE = "Some of the sensors are above the critical level."

else:
    STATE = "UNKNOWN"
    MESSAGE = "Unable to find '" + SENSORS_BIN + "'. Please install lm_sensors."


if STATE == "OK":

    print("OK: " + MESSAGE + " | " + GRAPHS)
    sys.exit(OK)

elif STATE == "WARNING":

    print("WARNING: " + MESSAGE + " | " + GRAPHS)
    sys.exit(WARNING)

elif STATE == "CRITICAL":

    print("CRITICAL: " + MESSAGE + " | " + GRAPHS)
    sys.exit(CRITICAL)

else:
    print("UNKNOWN: " + MESSAGE)
    sys.exit(UNKNOWN)
