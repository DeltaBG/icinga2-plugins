#!/bin/bash

function help {
echo -e "\nPlease use either heap or threads as metric arguments (-m).
            Warning and Critical values in bytes(for heap)
            Typical use cases:
             ./jmx_parser.sh -m heap -u 127.0.0.1 -p 1085 -w 700000000 -c 900000000
             ./jmx_parser.sh -m threads -u 127.0.0.1 -p 1085 -w 150 -c 200\n"
        exit -1
}


while getopts "m:u:p:w:c:U:P:h" OPT; do
        case $OPT in
                "m") metric=$OPTARG;;
                "u") url=$OPTARG;;
                "p") port=$OPTARG;;
                "w") warn=$OPTARG;;
                "c") crit=$OPTARG;;
                "U") username=$OPTARG;;
                "P") password=$OPTARG;;
                "h") help;;
        esac
done

#transfer_vars=$1
#echo > /dev/tcp/${url}/${port} > /dev/null 2>&1 && status=0 || status=1
echo > /dev/tcp/${url}/${port} > /dev/null 2>&1 && status=0 || status=1
#status=0

if [ $status == "0" ]; then
	echo "1" > /dev/null	
elif [ $status == "1" ]; then
        echo "Port Unreachable (${url}:${port})"
        exit 2
else
        echo "$status Exit status please debug manually"
        exit 1
fi

if [ $metric == heap ]; then
    if [[ ! -z ${username} || ! -z ${password} ]]; then
        output=`./check_jmx -U service:jmx:rmi:///jndi/rmi://${url}:${port}/jmxrmi -O java.lang:type=Memory -A HeapMemoryUsage -K used -I HeapMemoryUsage -J used -vvvv -w ${warn} -c ${crit} -username ${username} -password "${password}"`
    else
        output=`./check_jmx -U service:jmx:rmi:///jndi/rmi://${url}:${port}/jmxrmi -O java.lang:type=Memory -A HeapMemoryUsage -K used -I HeapMemoryUsage -J used -vvvv -w ${warn} -c ${crit}`
    fi

    if [[ $output == *Exception* ]]; then
        echo $output
        echo "Critical: jmx pull failed"
        exit 2
    fi
    perfdata=`echo $output | awk -F ',' '{print $2}' | awk -F '}' '{print $1}'`
    perf_commit=`echo $perfdata | awk -F ';' '{print $1}'`
    perf_init=`echo $perfdata | awk -F ';' '{print $2}'`
    perf_max=`echo $perfdata | awk -F ';' '{print $3}'`
    perf_used=`echo $perfdata | awk -F ';' '{print $4}'`
    msg_out=`echo $output | awk -F '|' '{print $1}'| sed 's/- //'`
    msg_1=`echo $msg_out | awk -F '=' '{print $1}'`
    msg_2=`echo $msg_out | awk -F '=' '{print $2}'`
    conv_to_mb=$(echo "${msg_2}/1024/1024" | bc)
    msg_final="${msg_1} (${conv_to_mb}Mb)"
    
    #CONVERT PERFDATA TO MB
    warn_mb=$(echo "${warn}/1024/1024" | bc)
    crit_mb=$(echo "${crit}/1024/1024" | bc)
    perf_commit_b=`echo $perf_commit | awk -F '=' '{print $2}'`
    commit=$(echo "${perf_commit_b}/1024/1024" | bc)    
    perf_init_b=`echo $perf_init | awk -F '=' '{print $2}'`
    init=$(echo "${perf_init_b}/1024/1024" | bc)
    perf_max_b=`echo $perf_max | awk -F '=' '{print $2}'`
    max=$(echo "${perf_max_b}/1024/1024" | bc)
    perf_used_b=`echo $perf_used | awk -F '=' '{print $2}'`
    used=$(echo "${perf_used_b}/1024/1024" | bc)
    perfdata_str="Heap_InUse=${used}Mb;${warn_mb};${crit_mb};0;${max} Heap_Initial=${init}Mb; Heap_Committed=${commit}Mb;"

    if [ $used -ge $warn_mb ]; then
        if [ $used -ge $crit_mb ]; then

            echo "Critical: $msg_final | $perfdata_str"
            exit 2

        else
            echo "Warning: $msg_final | $perfdata_str"
            exit 1
        fi
    
    else
        echo "OK: $msg_final | $perfdata_str"
        exit 0
    fi

elif [ $metric == threads ]; then
    if [[ ! -z ${username} || ! -z ${password} ]]; then
        output=`./check_jmx -U service:jmx:rmi:///jndi/rmi://${url}:${port}/jmxrmi -O java.lang:type=Threading -A ThreadCount -K Total -vvvv -w ${warn} -c ${crit} -username ${username} -password "${password}"`
    else
        output=`./check_jmx -U service:jmx:rmi:///jndi/rmi://${url}:${port}/jmxrmi -O java.lang:type=Threading -A ThreadCount -K Total -vvvv -w ${warn} -c ${crit}`
    fi

    if [[ $output == *Exception* ]]; then
        echo "Critical: jmx pull failed"
        exit 2
    fi
    thread_count=`echo $output | awk -F '=' '{print $2}' | awk -F ' |' '{print $1}'`
    thread_msg_tmp=`echo $output | awk -F '=' '{print $1}' | sed 's/ -//'`
    thread_msg="$thread_msg_tmp (${thread_count})"
    perfdata_str=" JVM_Threads=${thread_count};${warn};${crit};0;${crit}"
    
    if [ $thread_count -ge $warn ]; then
        if [ $thread_count -ge $crit ]; then
            echo "Critical: $thread_msg | $perfdata_str"
            exit 2
        else
            echo "Warning: $thread_msg | $perfdata_str"
            exit 1
        fi
    else
        echo "OK: $thread_msg | $perfdata_str"
        exit 0
    fi

elif [ $metric == jdbc ]; then
    if [[ ! -z ${username} || ! -z ${password} ]]; then
        active=`./check_jmx -U service:jmx:rmi:///jndi/rmi://${url}:${port}/jmxrmi -O 'org.apache.tomcat.jdbc.pool.jmx:name=dataSourceMBean,type=ConnectionPool' -A NumActive -vvvv -w ${warn} -c ${crit} -username "${username}" -password "${password}"`
        idle=`./check_jmx -U service:jmx:rmi:///jndi/rmi://${url}:${port}/jmxrmi -O 'org.apache.tomcat.jdbc.pool.jmx:name=dataSourceMBean,type=ConnectionPool' -A NumIdle -vvvv -w ${warn} -c ${crit} -username ${username} -password "${password}"`
    else
        active=`./check_jmx -U service:jmx:rmi:///jndi/rmi://${url}:${port}/jmxrmi -O 'org.apache.tomcat.jdbc.pool.jmx:name=dataSourceMBean,type=ConnectionPool' -A NumActive -vvvv -w ${warn} -c ${crit}`
        idle=`./check_jmx -U service:jmx:rmi:///jndi/rmi://${url}:${port}/jmxrmi -O 'org.apache.tomcat.jdbc.pool.jmx:name=dataSourceMBean,type=ConnectionPool' -A NumIdle -vvvv -w ${warn} -c ${crit}`
    fi
    if [[ $active == *Exception* ]] || [[ $idle == *Exception* ]]; then
        echo "Critical: jmx pull failed"
        exit 2
    fi

    active=`echo $active | awk -F '=' '{print $2}'`
    idle=`echo $idle | awk -F '=' '{print $2}'`

    jdbc_msg="JDBC Connections in use (${active}/${crit})"
    perfdata_str="JDBC_conn=${active};${warn};${crit};0;${crit} JDBC_idle=${idle};"

    if [ $active -ge $warn ]; then
        if [ $active -ge $crit ]; then
            echo "Critical: $jdbc_msg | $perfdata_str"
            exit 2
        else
            echo "Warning: $jdbc_msg | $perfdata_str"
            exit 1
        fi
    else
        echo "OK: $jdbc_msg | $perfdata_str"
        exit 0
    fi

elif [ $metric == mq ]; then

    mqs_array=(ACTIVITY_FEED_QUEUE ActiveMQ.DLQ BACKOFFICE_NOTIFICATION_QUEUE CUSTOMER_FACING_NOTIFICATION_QUEUE GISELE_NOTIFICATION_QUEUE)
    metrics_array=(QueueSize BlockedSends ConsumerCount ProducerCount AverageEnqueueTime)
    msg_w=""
    msg_c=""
    perf_data=""
    for i in ${mqs_array[@]};
    do
        tmp_msg_w=""
        tmp_msg_c=""
        for y in ${metrics_array[@]};
        do

        if [[ ! -z ${username} || ! -z ${password} ]]; then
            tmp_var=`./check_jmx -U service:jmx:rmi:///jndi/rmi://${url}:${port}/jmxrmi -O "org.apache.activemq:type=Broker,brokerName=notificationBroker,destinationType=Queue,destinationName=${i}" -A ${y} -vvvv -w ${warn} -c ${crit} -username ${username} -password "${password}"`
        else
            tmp_var=`./check_jmx -U service:jmx:rmi:///jndi/rmi://${url}:${port}/jmxrmi -O "org.apache.activemq:type=Broker,brokerName=notificationBroker,destinationType=Queue,destinationName=${i}" -A ${y} -vvvv -w ${warn} -c ${crit}`
        fi

        if [[ $tmp_var == *Exception* ]]; then
            echo "Critical: jmx pull failed at ${y} - ${i}"
            exit 2
        fi

        
        tmp_var=`echo $tmp_var | awk -F '=' '{print $2}'`
        perf_data="$perf_data ${y}_${i}=${tmp_var};${warn};${crit};0;${crit}"
        
        if [ $tmp_var -ge $warn ]; then
            if [ $tmp_var -ge $crit ]; then
                tmp_msg_c="$tmp_msg_c $y:($tmp_var)"
            else
                tmp_msg_w="$tmp_msg_w $y:($tmp_var)"
            fi
        else
            echo "" > /dev/null
        fi

        done
        msg_w="$msg_w $tmp_msg_w"
        msg_c="$msg_c $tmp_msg_c"
    done

    echo "NotificationMQs Crit:[$msg_c] Warn:[$msg_w] | $perf_data"
    exit 0

else
    echo "Unknown: unknown -m metric: $metric please use either heap or threads"
    exit 3

fi
