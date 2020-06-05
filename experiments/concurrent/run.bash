# Copyright 2019 National Technology & Engineering Solutions of Sandia, LLC
# (NTESS). Under the terms of Contract DE-NA0003525 with NTESS, the U.S.
# Government retains certain rights in this software.

# run the QUE experiment between clients and servers. Called by commands
# created by sweep.bash.
#
# Expects the following as arguments:
#
#  * DIR:           directory for results
#  * ITER:          iteration number
#  * DURATION:      how long to run
#  * CONCURRENT:    number of concurrent client/server pairs
#  * VMTYPE:        VM type (kvm or container)
#  * DRIVER:        network driver (for kvm)
#  * NCPUS:         number of vCPUs
#  * OFFLOAD:       "on" or "off" to control offloading
#  * RATE:          rate limit or "none" for no limit
#  * NWORKERS:      number of client threads
#  * URL:           URL to request
#  * NREQUESTS:     number of requests to make
#  * INSTRUMENT:    "true" or "false" to control instrumentation
#  * PINNING:       "true" or "false" to enable/disable CPU pining (aka affinity)
#  * GRE:           "true" or "false" to enable/disable GRE tunneling for all traffic
#  * STRESS_CPU:    number of threads generating CPU stress
#  * STRESS_IO:     number of threads generating IO stress
#  * STRESS_MEM:    number of threads generating memory stress

if [ $# -ne 18 ]; then
    echo "USAGE: $0 DIR ITER DURATION CONCURRENT VMTYPE DRIVER NCPUS OFFLOAD RATE NWORKERS URL NREQUESTS INSTRUMENT PINNING GRE STRESS_CPU STRESS_IO STRESS_MEM"
    exit 1
fi

#TMPDIR=/tmp/minimega/files/
TMPDIR=/scratch/files/

# so many variables...
DIR=${1}
ITER=${2}
DURATION=${3}
CONCURRENT=${4}
VMTYPE=${5}
DRIVER=${6}
NCPUS=${7}
OFFLOAD=${8}
RATE=${9}
NWORKERS=${10}
URL=${11}
NREQUESTS=${12}
INSTRUMENT=${13}
PINNING=${14}
GRE=${15}
STRESS_CPU=${16}
STRESS_IO=${17}
STRESS_MEM=${18}

mm () {
    # for debugging, we print the minimega command before we run it
    echo "$@"
    /root/minimega -e $@ || exit $?
}

wait_for_files () {
    while [[ $(/root/minimega -e file status | wc -c) -ne 0 ]]; do
        echo "waiting on files..."
        sleep 10
    done
}

start_experiment () {
    local namespace=$1

    mkdir -p $dir/$namespace

    mm namespace $namespace vm info > $dir/$namespace/vm_info.before
    mm namespace $namespace cc process list all > $dir/$namespace/cc_process_list.before
    # for parsing in process_results
    /root/minimega -e namespace $namespace .csv true .column name,id .header false vm info > $TMPDIR/$namespace/vm_ids

    # start traffic generation
    mm namespace $namespace cc filter name=client

    # Make first request to generate the image on the server if this is an
    # image URL.
    mm namespace $namespace .preprocess false cc exec curl -s -o /dev/null $URL

    # Account for 100 packets per second
    if [[ "$INSTRUMENT" == "true" ]]; then
        # owping doesn't dump data periodically
        #total_packets=$(($DURATION*100))
        #mm namespace $namespace cc background bash -c "'owping -v -i 0.01 -c $total_packets -L 20 10.0.0.1 > /que/owping.out 2> /que/owping.err'"

        # powstream will test 100 owpings/second and write a summary for each
        mm namespace $namespace cc exec mkdir /que/owamp/
        mm namespace $namespace cc exec mkdir /que/owamp/client
        mm namespace $namespace cc exec mkdir /que/owamp/server

        # s2c powstream
        mm namespace $namespace cc background bash -c "'powstream -L 10 -i 0.01 -c 100 -d /que/owamp/server -p 10.0.0.1 > /que/powstream-s2c.out 2> /que/powstream-s2c.err'"
        # c2s powstream
        mm namespace $namespace cc background bash -c "'powstream -t -L 10 -i 0.01 -c 100 -d /que/owamp/client -p 10.0.0.1 > /que/powstream-c2s.out 2> /que/powstream-c2s.err'"
    fi

    # flags for ab:
    #  -c: number of workers
    #  -l: don't report errors for variable length responses
    #  -t: duration of test (not used, we run for a fixed number of requests instead)
    #  -n: number of requests (-t => -n 50000 but we want it to run for longer)
    #  -s: seconds to max. wait for each response (default is 30)
    mm namespace $namespace cc background bash -c "'ab -s 60 -c $NWORKERS -l -n $NREQUESTS $URL > /que/ab.out 2> /que/ab.err'"

    # how we did it with protonuke
    #for j in $(seq $nworkers); do
    #    mm namespace $namespace cc background /tmp/miniccc/files/protonuke -$protocol -u 0 10.0.0.1
    #done
}

wait_for_ab () {
    local namespace=$1

    local start=$(date +%s)

    while [[ ! -z "$(mm namespace $namespace cc process list all | grep ab)" ]]; do
        if [[ "$(($(date +%s)-$start))" -gt $DURATION ]]; then
            echo "timed out waiting for ab to finish"
            break
        fi

        echo "waiting on ab for $namespace..."
        sleep 5
    done
}

stop_experiment () {
    local namespace=$1

    # stop captures
    mm namespace $namespace clear capture

    # collect after version of `vm info`
    mm namespace $namespace vm info > $dir/$namespace/vm_info.after

    mm namespace $namespace clear cc filter

    # collect processes that are still running (before we kill them)
    mm namespace $namespace cc process list all > $dir/$namespace/cc_process_list.after

    # kill everything that we started with `cc background`
    mm namespace $namespace cc process kill all

    # grab final values from client
    mm namespace $namespace cc exec ifconfig
    mm namespace $namespace cc exec bash /ethtool.bash
    mm namespace $namespace cc recv /proc/net/netstat
    mm namespace $namespace cc exec cp /proc/interrupts /que/
    mm namespace $namespace cc exec cp /miniccc.log /que/

    if [[ "$VMTYPE" == "kvm" ]]; then
        mm namespace $namespace cc exec blockdev --flushbufs /dev/sda
        # always busy...
        #mm namespace $namespace cc exec umount /que
    fi
}

collect_results () {
    local namespace=$1

    # need to delete the local copies so that we pull them from the node where
    # the VM ran
    mm namespace $namespace file delete $namespace/server.qcow2
    mm namespace $namespace file delete $namespace/client.qcow2

    # grab directory that will have all the results
    mm namespace $namespace file get $namespace

    # wait for meshage to transfer the files
    wait_for_files
}

process_qcow () {
    local dir=$(dirname $1)
    local base=$(basename $1 .qcow2)
    local dst=$dir/$base

    mkdir $dst

    if [ ! -f "$1" ]; then
        echo "file does not exist: $1"
        return 1
    fi

    # connect block device
    qemu-nbd -c /dev/nbd0 $1

    # fix any errors automatically
    e2fsck -p -v -D /dev/nbd0
    if [ $? -ne 0 ]; then
        echo "e2fsck failed on $1"
        qemu-nbd -d /dev/nbd0
        return 1
    fi

    # mount read-only (mostly as a precaution against writing on accident)
    mount -t ext4 -o ro /dev/nbd0 /mnt

    # wait for the filesystem to mount
    local i=0
    until findmnt /mnt; do
        echo "waiting for mount"
        i=$((i+1))
        if [ $i -gt 6 ]; then
            echo "timed out waiting for mount for $1"
            qemu-nbd -d /dev/nbd0
            return 1
        fi
        sleep 10
    done

    # extract all files
    cp -a /mnt/. $dst/

    # umount and disconnect block device
    umount /mnt
    qemu-nbd -d /dev/nbd0
}

process_results () {
    local namespace=$1

    if [[ "$VMTYPE" == "kvm" ]]; then
        process_qcow $TMPDIR/$namespace/server.qcow2
        if [ $? -ne 0 ]; then
            return
        fi
        process_qcow $TMPDIR/$namespace/client.qcow2
        if [ $? -ne 0 ]; then
            return
        fi
    fi

    if [[ "$INSTRUMENT" == "true" ]] ; then
        if [[ "$VMTYPE" == "container" ]]; then
            # need to split system-wide scaps into server and client scaps for this namespace
            echo "splitting scaps"
            cat $TMPDIR/$namespace/vm_ids | parallel --will-cite -j2 --colsep ',' sysdig -r $TMPDIR/scap.{1} -w $TMPDIR/$namespace/{2}/sysdig.scap thread.cgroup.freezer=/minimega/{3}
        fi

        # run these commands in parallel
        parallel --will-cite -j6 <<EOF
tcptrace -l -f'port=80' $TMPDIR/$namespace/server.pcap > $TMPDIR/$namespace/server.tcptrace
tcptrace -l -f'port=80' $TMPDIR/$namespace/client.pcap > $TMPDIR/$namespace/client.tcptrace

sysdig -r $TMPDIR/$namespace/server/sysdig.scap -c topscalls > $TMPDIR/$namespace/server/topscalls-all.out
sysdig -r $TMPDIR/$namespace/server/sysdig.scap -c topscalls proc.name=protonuke > $TMPDIR/$namespace/server/topscalls-workload.out

sysdig -r $TMPDIR/$namespace/client/sysdig.scap -c topscalls > $TMPDIR/$namespace/client/topscalls-all.out
sysdig -r $TMPDIR/$namespace/client/sysdig.scap -c topscalls proc.name=ab > $TMPDIR/$namespace/client/topscalls-workload.out
EOF
    fi

    # need to pass params hint to summarize since it guesses the parameters
    # from the path and TMPDIR path doesn't contain any parameters.
    python summarize_test_results.py -p $dir/$namespace -d $TMPDIR/$namespace.sqlite3 $TMPDIR/$namespace/
}

clean_up () {
    local namespace=$1

    # copy everything to the destination
    mv $TMPDIR/$namespace/* $dir/$namespace/
    mv $TMPDIR/$namespace.sqlite3 $dir/

    mm clear namespace $namespace

    # everything is in the $namespace dir so delete it everywhere
    mm namespace $namespace mesh send all file delete $namespace
    mm namespace $namespace file delete $namespace
}

run_experiment () {
    local dir=$1

    # get a list of namespaces
    namespaces=$(mm .annotate false .header false .column namespace namespace | grep que)

    # start stressing out, if enabled
    stress_args=""
    if [[ $STRESS_CPU -gt 0 ]]; then
        stress_args="$stress_args -c $STRESS_CPU"
    fi
    if [[ $STRESS_IO -gt 0 ]]; then
        stress_args="$stress_args -i $STRESS_IO"
    fi
    if [[ $STRESS_MEM -gt 0 ]]; then
        stress_args="$stress_args -m $STRESS_MEM"
    fi
    if [[ ! -z "$stress_args" ]]; then
        if [[ "$COLOCATED" == "false" ]]; then
            # on remote hosts
            mm mesh send all background stress $stress_args
        else
            # on local host
            stress $stress_args &
        fi
    fi

    # wait for stress to start
    sleep 10

    echo "$(date) starting experiment"
    for i in $namespaces; do
        start_experiment $i
    done

    # let traffic start
    sleep 10

    # let all the traffic complete
    for i in $namespaces; do
        wait_for_ab $i
    done

    echo "$(date) experiment finished"

    # extra buffer
    sleep 10

    # stop all stress
    mm mesh send all shell pkill stress
    pkill stress

    # kick off another round of data gathering
    for i in $namespaces; do
        stop_experiment $i
    done

    # stop vmstat
    if [[ "$COLOCATED" == "false" ]]; then
        mm mesh send all shell pkill vmstat
        if [[ "$VMTYPE" == "kvm" ]]; then
            # TODO: only include when INSTRUMENT=true?
            mm mesh send all shell pkill perf
        fi
    else
        pkill vmstat
        if [[ "$VMTYPE" == "kvm" ]]; then
            # TODO: only include when INSTRUMENT=true?
            pkill perf
        fi
    fi

    # stop sysdig
    if [[ "$VMTYPE" == "container" ]] && [[ "$INSTRUMENT" == "true" ]]; then
        if [[ "$COLOCATED" == "false" ]]; then
            mm mesh send all shell pkill sysdig
            mm file get scap.*
        else
            pkill sysdig
        fi
    fi

    # let captures finish and last round of cc commands complete
    sleep 30

    # collect everything and put it in the correct place
    for i in $namespaces; do
        # record final cc results
        mm namespace $i cc commands > $dir/$i/cc.after

        # if running on a single machine, results are already local
        if [[ "$COLOCATED" == "false" ]]; then
            echo "$(date) collecting results for $i"
            collect_results $i
        fi

        echo "$(date) processing results for $i"
        process_results $i

        clean_up $i
    done

    # for good measure
    mm mesh send all clear all
    mm clear all
}

# replace URLs with more path-friendly strings:
#   http://10.0.0.1/                        -> http
#   https://10.0.0.1/                       -> https
#   https://10.0.0.1/image.png?size=15MB    -> https15MB
# note: we get ambiguous URL names if there is no size parameter
urlname=$(echo "$URL" | sed 's/\(https\?\)[^=]\+=\?/\1/')

# construct directory name from parameters
name="$VMTYPE-$DRIVER-$NCPUS-$OFFLOAD-$RATE-$NWORKERS-$CONCURRENT-$urlname"

# containers ignore the driver
if [[ "$VMTYPE" == "container" ]]; then
    name="$VMTYPE-host-$NCPUS-$OFFLOAD-$RATE-$NWORKERS-$CONCURRENT-$urlname"
fi

if [[ "$INSTRUMENT" == "true" ]]; then
    name="$name-instr"
fi

if [[ "$PINNING" == "true" ]]; then
    name="$name-pinning"
fi

if [[ "$GRE" == "true" ]]; then
    name="$name-gre"
fi

# figure out if we are running on one node or not
COLOCATED="false"
if [[ "$(/root/minimega -e .columns size .header false .annotate false mesh status)" == "1" ]]; then
    COLOCATED="true"
    name="$name-colocated"
fi

# can't have colocated with GRE tunnels
if [[ "$GRE" == "true" ]] && [[ "$COLOCATED" == "true" ]]; then
    echo "INVALID: GRE and COLOCATED are both true"
    exit 0
fi

if [[ $STRESS_CPU -gt 0 ]]; then
    name="$name-stresscpu${STRESS_CPU}"
fi

if [[ $STRESS_IO -gt 0 ]]; then
    name="$name-stressio${STRESS_IO}"
fi

if [[ $STRESS_MEM -gt 0 ]]; then
    name="$name-stressmem${STRESS_MEM}"
fi

# check to see if hyperthreading is enabled based on the number of cores vs the
# number of cpus.
if [[ "$(lscpu -e=CORE | sort -u | wc -l)" == "$(lscpu -e=CPU | sort -u | wc -l)" ]]; then
    name="$name-noht"
fi

echo "$(date) name: $name, iteration: $ITER"

dir=$DIR/$name/$ITER/
if [ -d "$dir" ]; then
    echo "SKIPPING: $dir already exists"
    exit 0
fi
mkdir -p $dir

# run as a block so that we can capture stdout/stderr
{
    if [[ "$COLOCATED" == "false" ]]; then
        # collect information about the hosts
        mm .preprocess false mesh send all shell bash -c '"uname -a > '$TMPDIR'/uname.$(hostname)"'
        mm .preprocess false mesh send all shell bash -c '"lscpu > '$TMPDIR'/lscpu.$(hostname)"'
        mm .preprocess false mesh send all shell bash -c '"kvm -version > '$TMPDIR'/kvm.$(hostname)"'
        mm .preprocess false mesh send all shell bash -c '"cp /proc/interrupts '$TMPDIR'/interrupts.before.$(hostname)"'
        mm .preprocess false mesh send all background bash -c '"vmstat 5 > '$TMPDIR'/vmstat.$(hostname)"'
        if [[ "$VMTYPE" == "kvm" ]]; then
            # TODO: only include when INSTRUMENT=true?
            mm .preprocess false mesh send all background bash -c '"perf kvm --host stat record -a -o '$TMPDIR/'kvm.trace.$(hostname)"'
        fi
    else
        # collect local machine info
        uname -a > $dir/uname.$(hostname)
        lscpu > $dir/lscpu.$(hostname)
        kvm --version > $dir/kvm.$(hostname)
        cp /proc/interrupts $dir/interrupts.before.$(hostname)
        vmstat 5 > $dir/vmstat.$(hostname) &
    fi

    # enable or disable offloading on the physical hosts
    mm mesh send all shell ethtool -k mega_bridge > $dir/offloading.before
    for v in sg tso gso gro; do
        mm mesh send all shell ethtool -K mega_bridge $v $OFFLOAD
    done
    mm mesh send all shell ethtool -k mega_bridge > $dir/offloading.after

    # create GRE tunnels between server and client nodes
    if [[ "$GRE" == "true" ]] ; then
        mm mesh send all bridge > $dir/bridge.before

        HOSTS=$(/root/minimega -e .annotate false mesh send all host name)
        for i in $HOSTS; do
            for j in $HOSTS; do
                if [[ "$i" != "$j" ]]; then
                    mm mesh send $i bridge tunnel gre mega_bridge $j
                fi
            done

        done

        mm mesh send all bridge > $dir/bridge.after
    fi

    # start concurrent envs
    for j in $(seq $CONCURRENT); do
        echo "$(date) launching environments #$j"
        bash env.bash $VMTYPE $DRIVER $NCPUS $OFFLOAD $RATE $INSTRUMENT $PINNING
    done

    if [[ "$VMTYPE" == "container" ]] && [[ "$INSTRUMENT" == "true" ]]; then
        # ensure that remote hosts pull the latest version of the script
        mm mesh send all file delete start_sysdig.bash

        # create script to start sysdig
        echo "sysdig -w $TMPDIR/scap.\$(hostname) \"thread.cgroup.freezer contains minimega\"" > $TMPDIR/start_sysdig.bash

        if [[ "$COLOCATED" == "false" ]]; then
            # on remote hosts
            mm mesh send all background bash file:start_sysdig.bash
        else
            # on local host
            bash $TMPDIR/start_sysdig.bash &
        fi
    fi

    # make sure envs have time to launch
    sleep 60

    # snapshot of what ovs looks like once we have the VMs launched including
    # the ovs version
    if [[ "$COLOCATED" == "false" ]]; then
        mm .preprocess false mesh send all shell bash -c '"ovs-vsctl show > '$TMPDIR'/ovs.$(hostname)"'
    else
        ovs-vsctl show > $dir/ovs.$(hostname)
    fi

    run_experiment $dir

    # delete GRE tunnels between server and client nodes
    if [[ "$GRE" == "true" ]] ; then
        HOSTS=$(/root/minimega -e .annotate false mesh send all host name)
        for i in $HOSTS; do
            TUNNELS=$(/root/minimega -e .column tunnel .annotate false .header false mesh send $i bridge)
            TUNNELS="${TUNNELS:1:-1}"   # trims brackets from list
            for iface in $TUNNELS; do
                mm mesh send $i bridge notunnel mega_bridge $iface
            done
        done

        mm mesh send all bridge > $dir/bridge.final
    fi

    if [[ "$COLOCATED" == "false" ]]; then
        # final data collect
        mm .preprocess false mesh send all shell bash -c '"cp /proc/interrupts '$TMPDIR'/interrupts.after.$(hostname)"'

        # fetch host info files
        mm file get uname.*
        mm file get lscpu.*
        mm file get kvm.*
        mm file get interrupts.*
        mm file get ovs.*
        mm file get vmstat.*

        wait_for_files

        mv $TMPDIR/uname.* $dir/
        mv $TMPDIR/lscpu.* $dir/
        mv $TMPDIR/kvm.* $dir/
        mv $TMPDIR/interrupts.* $dir/
        mv $TMPDIR/ovs.* $dir/
        mv $TMPDIR/vmstat.* $dir/

        mm mesh send all shell bash -c "'rm $TMPDIR/uname.*'"
        mm mesh send all shell bash -c "'rm $TMPDIR/lscpu.*'"
        mm mesh send all shell bash -c "'rm $TMPDIR/kvm.*'"
        mm mesh send all shell bash -c "'rm $TMPDIR/interrupts.*'"
        mm mesh send all shell bash -c "'rm $TMPDIR/ovs.*'"
        mm mesh send all shell bash -c "'rm $TMPDIR/vmstat.*'"

        if [[ "$VMTYPE" == "container" ]] && [[ "$INSTRUMENT" == "true" ]]; then
            mv $TMPDIR/scap.* $dir/
            mm mesh send all shell bash -c "'rm $TMPDIR/scap.*'"
        fi
    else
        # final data collect
        cp /proc/interrupts $dir/interrupts.after.$(hostname)
    fi
} > $dir/experiment.out 2> $dir/experiment.err

echo "$(date) finished: name: $name, iteration: $ITER"
