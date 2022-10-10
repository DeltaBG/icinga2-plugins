#!/bin/bash

while getopts "s:t:a:S:" opt; do
  case $opt in
    s)
      servicestate=$OPTARG
      ;;
    t)
      servicestatetype=$OPTARG
      ;;
    a)
      serviceattempt=$OPTARG
      ;;
    S)
      service=$OPTARG
      ;;
  esac
done

if ( [ -z $servicestate ] || [ -z $servicestatetype ] || [ -z $serviceattempt ] || [ -z $service ] ); then
  echo "USAGE: $0 -s servicestate -z servicestatetype -a serviceattempt -S service"
  exit 3;
else
  # Only restart on the third attempt of a critical event
  if ( [ $servicestate == "CRITICAL" ] && [ $servicestatetype == "HARD" ] && [ $serviceattempt -eq 1 ] ); then
    if [[ -f "/usr/bin/systemctl" ]]; then
      sudo /usr/bin/systemctl restart $service
    elif [[ -f "/sbin/service" ]]; then
      sudo /sbin/service $service restart
    fi
  fi
fi

