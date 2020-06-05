# Copyright 2019 National Technology & Engineering Solutions of Sandia, LLC
# (NTESS). Under the terms of Contract DE-NA0003525 with NTESS, the U.S.
# Government retains certain rights in this software.

# run physical test

if [ $# -ne 8 ]; then
    echo "USAGE: $0 DIR INTERFACE OFFLOAD NWORKERS DURATION URL NREQUESTS INSTRUMENT"
    exit 1
fi

DIR=${1}
INTERFACE=${2}
OFFLOAD=${3}
NWORKERS=${4}
DURATION=${5}
URL=${6}
NREQUESTS=${7}
INSTRUMENT=${8}

rond() {
    # for debugging, we print the minimega command before we run it
    echo "$@"
    /usr/local/bin/rond -e "$@" || exit $?
}

wait_for_ab () {
    local start=$(date +%s)

    while [[ ! -z "$(/usr/local/bin/rond -e processes | grep ab)" ]]; do
        if [[ "$(($(date +%s)-$start))" -gt $DURATION ]]; then
            echo "timed out waiting for ab to finish"
            break
        fi

        echo "waiting on ab..."
        sleep 5
    done
}

# reset filter if set from previous run
rond clear filter

# flush dmesg
rond exec dmesg --clear

# enable or disable offloading
rond exec ethtool -K $INTERFACE
for v in sg tso gso gro; do
    rond exec ethtool -K $INTERFACE $v $OFFLOAD
done
rond exec ethtool -K $INTERFACE

# grab initial values
rond exec ifconfig
rond recv /proc/net/netstat

rond exec mkdir /que

# start background data gathering, if instrumentation is turned on.
#
# note: we always run vmstat regardless of the instrument flag.
rond exec bash -c "'echo ethtool -S $INTERFACE > /ethtool.bash'"
rond bg bash -c '"vmstat 5 > /que/vmstat.log"'

# record system info
rond exec bash -c '"lscpu > /que/lscpu"'

if [[ "$INSTRUMENT" == "true" ]] ; then
    rond bg bash -c '"while /bin/true; do cat /proc/sys/kernel/random/entropy_avail >> /que/entropy.log; sleep 5s; done"'
    rond bg bash -c '"for i in $(seq 1000); do bash /ethtool.bash > /que/ethtool.$i; sleep 5s; done"'

    # start sysdig
    rond exec modprobe sysdig-probe
    rond exec bash -c '"lsmod > /que/lsmod"'
    rond exec bash -c '"uname -a > /que/uname"'
    rond bg bash -c '"sysdig -w /que/sysdig.scap -p \"%evt.num %evt.time %evt.cpu %proc.name (%thread.tid) %evt.type\""'

    # start owampd
    rond filter ip=10.0.0.1
    rond bg bash -c "'owampd -f -Z > /que/owampd.out 2> /que/owampd.err'"

    # start capture everywhere
    rond filter ip=10.0.0.1
    rond bg tcpdump -i $INTERFACE -s 200 -w /que/server.pcap
    rond filter ip=10.0.0.2
    rond bg tcpdump -i $INTERFACE -s 200 -w /que/client.pcap
fi

# start protonuke server
rond filter ip=10.0.0.1
rond bg protonuke -serve -http

# make sure client and server are ready
sleep 30

# start traffic generation
rond filter ip=10.0.0.2

# Make first request to generate the image on the server if this is an
# image URL.
rond exec curl -s -o /dev/null $URL

# Account for 100 packets per second
if [[ "$INSTRUMENT" == "true" ]] ; then
    # owping doesn't dump data periodically
    #total_packets=$(($DURATION*100))
    #rond bg bash -c "'owping -v -i 0.01 -c $total_packets -L 20 10.0.0.1 > /que/owping.out 2> /que/owping.err'"
    # powstream will test 100 owpings/second and write a summary for each
    rond exec mkdir /que/owamp
    rond exec mkdir /que/owamp/client
    rond exec mkdir /que/owamp/server

    # server-to-client powstream
    rond bg bash -c "'powstream -L 10 -i 0.01 -c 100 -d /que/owamp/server -p 10.0.0.1 > /que/powstream-s2c.out 2> /que/powstream-s2c.err'"
    # client-to-server powstream
    rond bg bash -c "'powstream -t -L 10 -i 0.01 -c 100 -d /que/owamp/client -p 10.0.0.1 > /que/powstream-c2s.out 2> /que/powstream-c2s.err'"
fi

rond bg bash -c "'ab -s 60 -c $NWORKERS -l -n $NREQUESTS $URL > /que/ab.out 2> /que/ab.err'"

# let traffic start
sleep 10

wait_for_ab

echo "$(date) experiment finished"

# extra buffer
sleep 10

# kill everything, pkill things that don't want to be killed
rond clear filter
rond killall protonuke
rond exec pkill vmstat
if [[ "$INSTRUMENT" == "true" ]] ; then
    rond killall tcpdump
    rond killall entropy
    rond killall ethtool
    rond exec pkill owampd
    rond exec pkill powstream
    rond exec pkill sysdig
fi

# grab dmesg
rond exec bash -c '"dmesg -t > /que/dmesg"'

# get final values
rond exec ifconfig
rond exec bash /ethtool.bash
rond recv /proc/net/netstat

rond commands > $DIR/commands

# wait for everything to transfer
rond checkpoint

rond recv /miniccc.log
rond exec bash -c "'> /miniccc.log'"
rond clear commands

# grab the result files
cp -r /tmp/rond/miniccc_responses $DIR

# clean responses for next iteration
rm -r /tmp/rond/miniccc_responses/
