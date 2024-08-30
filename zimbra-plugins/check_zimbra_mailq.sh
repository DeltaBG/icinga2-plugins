#!/bin/bash
# Version 0.0.1 - SEP/2024
# by Dean Iliev

ZIMBRA_MAILQ=`su - zimbra -c "which mailq"`

EXIT_OK=0
EXIT_WARN=1
EXIT_CRIT=2
EXIT_UKNOWN=3

function help {
	echo -e "
	Usage: $0 [params]

		-w,-c = pass warning and critical levels respectively.
		-h    = this help

	"
	exit $EXIT_UKNOWN
}

if [[ "$#" -eq 0 ]]; then
	help
fi

# Default ward and crit values
WARN=10
CRIT=20

while getopts "w:c:h" OPT; do
    case $OPT in
        "w") WARN=$OPTARG;;
        "c") CRIT=$OPTARG;;
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

MQC=`$ZIMBRA_MAILQ | tail -n 1 | cut -d" " -f 5`

LEVEL=0

if (( $MQC >= $WARN && $MQC < $CRIT )); then
   LEVEL=1
fi

if (( $MQC > $CRIT )); then
   LEVEL=2
fi

case $LEVEL in
	0)  echo "OK - $MQC messages in queue."
		exit $EXIT_OK
	    	;;
	1)	echo "WARNING - $MQC messages in queue."
		exit $EXIT_WARN
		;;
	2)	echo "CRITICAL - $MQC messages in queue."
		exit $EXIT_CRIT
		;;
esac
