#!/bin/bash
# Version 0.0.1 - Jan/2022
# by Nedelin Petkov

OK=0
WARNING=1
CRITICAL=2
UNKNOWN=3

help () {
    echo
    echo "Check the permissions of all files and directories in a directory."
    echo
    echo -e "\t$0:"
    echo -e "\t-d\tFull path to the directory."
    echo -e "\t-u\tUser name of the owner."
    echo -e "\t-g\tGroup name of the owner."
    echo -e "\t-s\tShow list of files and directories."
    echo
    echo -e "\t-h\tHelp"
    exit $UNKNOWN
}

FIND_BIN=`which find 2>/dev/null`

[ ! -f "$FIND_BIN" ] && echo "ERROR: You must have 'find'." && help

SHOW=false

# Getting parameters:
while getopts "d:u:g:sh" OPT; do
    case $OPT in
        d ) DIR=$OPTARG;;
        u ) USER=$OPTARG;;
        g ) GROUP=$OPTARG;;
        s ) SHOW=true;;
        h ) help;;
        \?) echo "Unknown option!"; help;;
        : ) echo "Missing option arguments."; help;;
        * ) echo "Unimplemented option"; help;;
    esac
done

( [ -z "$DIR" ] || [ -z "$USER" ] || [ -z "$GROUP" ] ) && \
    echo "ERROR: You must specify a directory, user, and group." && help

OUTPUT=$(eval "$FIND_BIN $DIR ! -user $USER -or ! -group $GROUP")

if [ -z "$OUTPUT" ]; then
    echo "OK: No files or directories with permissions other than user '$USER' or group '$GROUP'."
    exit $OK
else
    NUM_FOUND=$(echo -e $OUTPUT | sed 's/ /\n/' | wc -l)
    echo "WARNING: Found '$NUM_FOUND' files or directories with permissions other than user '$USER' or group '$GROUP'."
    if $SHOW; then
        echo Found:
        echo -e $OUTPUT | sed 's/ /\n/'
    fi
    exit $WARNING
fi
