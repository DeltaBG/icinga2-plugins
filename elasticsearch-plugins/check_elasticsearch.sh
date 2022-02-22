#!/bin/bash

#   This program is free software; you can redistribute it and/or modify
#   it under the terms of the GNU General Public License as published by
#   the Free Software Foundation; either version 2 of the License, or
#   (at your option) any later version.
#
#   This program is distributed in the hope that it will be useful,
#   but WITHOUT ANY WARRANTY; without even the implied warranty of
#   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#   GNU General Public License for more details.
#
#   You should have received a copy of the GNU General Public License
#   along with this program; if not, write to the Free Software
#   Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA  02110-1301  USA

PROGNAME=`basename $0`
VERSION="Version 0.4.0"
AUTHOR="Andrew Lyon, Based on Mike Adolphs (http://www.matejunkie.com/) check_nginx.sh code. Authentication support added by Ryan Gallant, CA support added by Michael Koch."

ST_OK=0
ST_WR=1
ST_CR=2
ST_UK=3
epoch=`date +%s`
hostname="localhost"
user=elastic
pass=changeme
authentication="False"
use_ca="False"
use_cert="False"
use_key="False"
use_no_check="False"
port=9200
status_page="_cluster/health"
output_dir=/tmp
scheme=http
carbon_server=""
carbon_port=""
carbon_key="system.:::name:::.cluster.app.elasticsearch.cluster"
use_proxy="on"
use_jq="False"
verbose="False"
wget_add_args=()
jq="jq -r"


print_version() {
    echo "$VERSION $AUTHOR"
}

print_help() {
    print_version $PROGNAME $VERSION
    echo ""
    echo "$PROGNAME is a Nagios plugin to check the cluster status of elasticsearch."
    echo "It also parses the status page to get a few useful variables out, and return"
    echo "them in the output."
    echo ""
    echo "$PROGNAME -H localhost -P 9200 -o /tmp"
    echo ""
    echo "Options:"
    echo "  -h/--help)"
    echo "     Print help."
    echo "  -H/--hostname)"
    echo "     Defines the hostname. Default is: localhost"
    echo "  -P/--port)"
    echo "     Defines the port. Default is: 9200"
    echo "  -s/--secure)"
    echo "     Use TLS. Defaults to false."
    echo "  -o/--output-directory)"
    echo "     Specifies where to write the tmp-file that the check creates."
    echo "     Default is: /tmp"
    echo "  -u/--username)"
    echo "    Username for elasticsearch. Turns on authentication mode when set"
    echo "  -p/--password)"
    echo "    Password for elasticsearch. Turns on authentication mode when set"
    echo "  -a/--auth)"
    echo "    Turns on authentication mode with default credentials."
    echo "  -c/--ca-certificate)"
    echo "    Uses the provided CA certificate."
    echo "  -C/--certificate)"
    echo "    Uses the provided certificate."
    echo "  -K/--private-key)"
    echo "    Uses the provided private key."
    echo "  -N/--no-check-certificate)"
    echo "     Don't check the server certificate against the available certificate authorities."
    echo "  -k/--ok-on-yellow)"
    echo "     Exit with OK state if the cluster is yellow."
    echo "  -x/--proxy)"
    echo "     System proxy off or on. Default is: on"
    echo "  --carbon-server)"
    echo "     Defines the carbon server. Default is Null"
    echo "  --carbon-port)"
    echo "     Defines the carbon port. Default is Null"
    echo "  --carbon-key)"
    echo "     Defines the carbon key. Default is system.:::name:::.cluster.app.elasticsearch.cluster"
    echo "  -V/--verbose)"
    echo "     Enable verbose mode."
    exit $ST_UK
}

while test -n "$1"; do
    case "$1" in
        --help|-h)
            print_help
            exit $ST_UK
            ;;
        --version|-v)
            print_version $PROGNAME $VERSION
            exit $ST_UK
            ;;
        --hostname|-H)
            hostname=$2
            shift
            ;;
        --ok-on-yellow|-k)
            ok_on_yellow="True"
            ;;
        --secure|-s)
            scheme=https
            ;;
        --port|-P)
            port=$2
            shift
            ;;
        --proxy|-x)
            use_proxy=$2
            shift
            ;;
        --password|-p)
            pass=$2
            authentication="True"
            shift
            ;;
        --username|-u)
            user=$2
            authentication="True"
            shift
            ;;
        --auth|-a)
            authentication="True"
            ;;
        --ca-certificate|-c)
            ca_cert=$2
            use_ca="True"
            shift
            ;;
        --certificate|-C)
            cert=$2
            use_cert="True"
            shift
            ;;
        --private-key|-K)
            private_key=$2
            use_key="True"
            shift
            ;;
        --no-check-certificate|-N)
            use_no_check="True"
            ;;
        --output-directory|-o)
            output_dir=$2
            shift
            ;;
        --carbon-server)
            carbon_server=$2
            shift
            ;;
        --carbon-port)
            carbon_port=$2
            shift
            ;;
        --carbon-key)
            carbon_key=$2
            shift
            ;;
        --verbose|-V)
            verbose="True"
            ;;
        --use-jq)
            use_jq="True"
            ;;
        *)
        echo "Unknown argument: $1"
        print_help
        exit $ST_UK
        ;;
    esac
    shift
done

if [ "$authentication" = "True" ]; then
    pass="--password=${pass}"
    user="--user=${user}"
fi

if [ "$use_ca" = "True" ]; then
    ca_cert="--ca-certificate=${ca_cert}"
fi

if [ "$use_cert" = "True" ]; then
    cert="--certificate=${cert}"
fi

if [ "$use_key" = "True" ]; then
    private_key="--private-key=${private_key}"
fi

if [ "$use_proxy" = "off" ]; then
    proxy="--proxy=${use_proxy}"
fi

if [ "$use_no_check" = "True" ]; then
    wget_add_args+=("--no-check-certificate")
fi

if [ "$verbose" != "True" ]; then
    wget_add_args+=("-q")
fi

get_status() {
    filename=$(mktemp -u -p "$output_dir" --suffix="-${PROGNAME}")

    # If authentication via private key ist defined
    if [ -n "${private_key}" ]
    then
       wget -t 3 -T 3 ${cert} ${private_key} $scheme://${hostname}:${port}/${status_page}?pretty=true -O ${filename} ${proxy} ${wget_add_args[@]}
    elif [ "${authentication}" = "True" ]; then
       wget -t 3 -T 3 ${ca_cert} ${user} ${pass} $scheme://${hostname}:${port}/${status_page}?pretty=true -O ${filename} ${proxy} ${wget_add_args[@]}
    else
       wget -t 3 -T 3 ${ca_cert} $scheme://${hostname}:${port}/${status_page}?pretty=true -O ${filename} ${proxy} ${wget_add_args[@]}
    fi
}

get_val() {
    filename=$1
    key=$2
    ty=$3

    if [[ $use_jq == "True" ]]; then
        ${jq} ".${key}" ${filename}
    else
        line=$(grep '"'"${key}"'"' ${filename})
        if [ "${ty}" == "string" ]; then
            echo ${line} | awk -F '"' '{print $4}'
        else
            echo ${line} | awk '{print $3}' | sed 's|[\r",]||g'
        fi
    fi
}

get_vals() {
    name=$(get_val ${filename} "cluster_name" "string")
    status=$(get_val ${filename} "status" "string")
    timed_out=$(get_val ${filename} "timed_out")
    number_nodes=$(get_val ${filename} "number_of_nodes")
    number_data_nodes=$(get_val ${filename} "number_of_data_nodes")
    active_primary_shards=$(get_val ${filename} "active_primary_shards")
    active_shards=$(get_val ${filename} "active_shards")
    relocating_shards=$(get_val ${filename} "relocating_shards")
    initializing_shards=$(get_val ${filename} "initializing_shards")
    delayed_unassigned_shards=$(get_val ${filename} "delayed_unassigned_shards")
    unassigned_shards=$(get_val ${filename} "unassigned_shards")
    rm -f ${filename}

    # Determine the Nagios Status and Exit Code
    if [ "$status" = "red" ]; then
        NAGSTATUS="CRITICAL"
        EXST=$ST_CR
    elif [ "$status" = "yellow" ]; then
        if [ -z "$ok_on_yellow" ]; then
            NAGSTATUS="WARNING"
            EXST=$ST_WR
        else
            NAGSTATUS="OK"
            EXST=$ST_OK
        fi
    elif [ "$status" = "green" ]; then
        NAGSTATUS="OK"
        EXST=$ST_OK
    else
        NAGSTATUS="UNKNOWN"
        EXST=$ST_UK
    fi
}

do_output() {
    output="elasticsearch ($name) is running. \
status: $status; \
timed_out: $timed_out; \
number_of_nodes: $number_nodes; \
number_of_data_nodes: $number_data_nodes; \
active_primary_shards: $active_primary_shards; \
active_shards: $active_shards; \
relocating_shards: $relocating_shards; \
initializing_shards: $initializing_shards; \
delayed_unassigned_shards: $delayed_unassigned_shards; \
unassigned_shards: $unassigned_shards "
}

do_perfdata() {
    #perfdata="'idle'=$iproc 'active'=$aproc 'total'=$tproc"
    perfdata="'active_primary'=$active_primary_shards 'active'=$active_shards 'relocating'=$relocating_shards 'init'=$initializing_shards 'delay_unass'=$delayed_unassigned_shards 'unass'=$unassigned_shards"
}

do_graphite() {
    if [ "$carbon_server" != "" -a "$carbon_port" != "" ]; then
        key=$(echo $carbon_key | sed "s/:::name:::/$name/")
        echo "$key.cluster.status                $EXST                  $epoch" | nc -w 2 $carbon_server $carbon_port
        echo "$key.cluster.nodes.ttl             $number_nodes          $epoch" | nc -w 2 $carbon_server $carbon_port
        echo "$key.cluster.nodes.data            $number_data_nodes     $epoch" | nc -w 2 $carbon_server $carbon_port
        echo "$key.cluster.shards.active         $active_shards         $epoch" | nc -w 2 $carbon_server $carbon_port
        echo "$key.cluster.shards.active_primary $active_primary_shards $epoch" | nc -w 2 $carbon_server $carbon_port
        echo "$key.cluster.shards.initializing   $initializing_shards   $epoch" | nc -w 2 $carbon_server $carbon_port
        echo "$key.cluster.shards.relocating     $relocating_shards     $epoch" | nc -w 2 $carbon_server $carbon_port
        echo "$key.cluster.shards.delayed_unassigned     $delayed_unassigned_shards     $epoch" | nc -w 2 $carbon_server $carbon_port
        echo "$key.cluster.shards.unassigned     $unassigned_shards     $epoch" | nc -w 2 $carbon_server $carbon_port
        unset key
    fi
}

# Here we go!
which wget >/dev/null 2>&1
if [ "$?" != "0" ]; then
    echo "CRITICAL - wget is not installed"
    exit $ST_CR
fi
get_status
if [ ! -s "$filename" ]; then
    echo "CRITICAL - Could not connect to server $hostname"
    rm -f "$filename"
    exit $ST_CR
else
    get_vals
    if [ -z "$name" ]; then
        echo "CRITICAL - Error parsing server output"
        exit $ST_CR
    else
        do_output
        do_perfdata
    do_graphite
    fi
fi

COMPARE=$listql

echo "${NAGSTATUS} - ${output} | ${perfdata}"
exit $EXST
