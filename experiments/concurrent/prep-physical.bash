#! /bin/bash

# Copyright 2019 National Technology & Engineering Solutions of Sandia, LLC
# (NTESS). Under the terms of Contract DE-NA0003525 with NTESS, the U.S.
# Government retains certain rights in this software.

# Copy files to nodes, for example:
#
#   bash prep-physical.bash ccc1 ccc2 ccc3 eth1

if [ $# -ne 4 ]; then
    echo "USAGE: $0 HEAD SERVER CLIENT INTERFACE"
    exit 1
fi

head=$1
server=$2
client=$3
interface=$4

function prep {
    host=$1
    ip=$2

    echo "== prep'n $host =="

    ## configure experiment network
    ssh $host ovs-vsctl del-br mega_bridge
    ssh $host ip link set $interface up
    ssh $host ip addr add $ip dev $interface

    # connect to rond
    ssh $host "nohup miniccc -level info -logfile /miniccc.log -v=false -parent=$head -port=9005 &>/dev/null &"

    echo "== prep'd $host =="
}

# prep the head node first
ssh $head "nohup rond -level info -logfile /rond.log -v=false -nostdin &>/dev/null &"
scp *-physical.bash $head:
ssh $head "echo >> params-physical.bash"
ssh $head "echo '# -----------------------' >> params-physical.bash"
ssh $head "echo '# AUTOMATICALLY GENERATED' >> params-physical.bash"
ssh $head "echo '# -----------------------' >> params-physical.bash"
ssh $head "echo HEAD=$head >> params-physical.bash"
ssh $head "echo SERVER=$server >> params-physical.bash"
ssh $head "echo CLIENT=$client >> params-physical.bash"
ssh $head "echo INTERFACE=$interface >> params-physical.bash"

# should be the same interface as server/client so that we can check the speed
# in sweep-physical.bash
ssh $head ip link set $interface up

# copy analysis scripts
scp ../../tools/summarize_test_results.py $head:
scp ../../tools/combine.py $head:
scp ../../tools/utils.py $head:

# wait for rond to start
sleep 10

prep $server 10.0.0.1/24
prep $client 10.0.0.2/24
