#!/bin/bash
# Version 0.0.1 - SEP/2022
# by Dean Iliev

EXIT_OK=0
EXIT_WARN=1
EXIT_CRIT=2
EXIT_UKNOWN=3

function help {
	echo -e "
	Usage:

		-w,-c = pass warning and critical levels respectively.
		-l    = log files, examples:
				-l \"/var/log/rnsapshot.log\"
				-l \"/var/log/rsnapshot*\"
		-n    = period (count n number of backup runs)
		-i    = ignore backups with warnings
		-h    = this help

	"
	exit $EXIT_UKNOWN
}

if [[ "$#" -eq 0 ]]; then
	help
fi

IGNORE_WARN=0
WARN=1
CRIT=2
COUNT=7
LOGS=/var/log/rsnapshot*.log

while getopts "w:c:l:n:ih" OPT; do
    case $OPT in
        "w") WARN=$OPTARG;;
        "c") CRIT=$OPTARG;;
        "l") LOGS=$OPTARG;;
        "n") COUNT=$OPTARG;;
		"i") IGNORE_WARN=1;;
        "h") help;;
		\? ) echo "Unknown option!"; help;;
         : ) echo "Missing option arguments."; help;;
         * ) echo "Invalid option: -$OPTARG" >&2
        	 exit -1
        	 ;;
    esac
done

if (( $WARN >= $CRIT )); then
	echo "UNKNOWN - WARNING value should be lower than CRITICAL value."
	exit $EXIT_UKNOWN
fi

FAILED_BACKUPS=0
LEVEL=0

for i in $(ls $LOGS); do
	FAILED=`grep ": completed" $i | tail -n ${COUNT} | grep -ve "successfully" | wc -l`
    if [ "$FAILED" -gt 0 ]; then	
		FAILED_BACKUPS=$(( $FAILED_BACKUPS + $FAILED ))
	fi
done

if (( $FAILED_BACKUPS >= $WARN && $FAILED_BACKUPS < $CRIT )); then
	LEVEL=1
fi

if (( $FAILED_BACKUPS >= $CRIT )); then
	LEVEL=2
fi

case $LEVEL in
	0)  echo "OK - $FAILED_BACKUPS failed during last ${COUNT} backup runs."
		exit $EXIT_OK
	    	;;
	1)	echo "WARNING - $FAILED_BACKUPS failed during last ${COUNT} backup runs."
		exit $EXIT_WARN
		;;
	2)	echo "CRITICAL - $FAILED_BACKUPS failed during last ${COUNT} backup runs."
		exit $EXIT_CRIT
		;;
esac	
