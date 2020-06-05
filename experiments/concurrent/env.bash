# Copyright 2019 National Technology & Engineering Solutions of Sandia, LLC
# (NTESS). Under the terms of Contract DE-NA0003525 with NTESS, the U.S.
# Government retains certain rights in this software.

# launch client/server environment based on arguments.
#
# See explanation of arguments in run.bash.

if [ $# -ne 7 ]; then
    echo "USAGE: $0 VMTYPE DRIVER NCPUS OFFLOAD RATE INSTRUMENT PINNING"
    exit 1
fi

#TMPDIR=/tmp/minimega/files/
TMPDIR=/scratch/files/

VMTYPE=$1
DRIVER=$2
NCPUS=$3
OFFLOAD=$4
RATE=$5
INSTRUMENT=$6
PINNING=$7

# generate a random namespace name
namespace=que$RANDOM$RANDOM

mm() {
    # for debugging, we print the minimega command before we run it
    echo "$namespace: $*"
    /root/minimega -e namespace $namespace $@ || exit $?
}

ifname=eth0
if [[ "$VMTYPE" == "container" ]]; then
    ifname=veth0
fi

# set them all, will only use relevant ones
mm vm config kernel /root/que.kernel
mm vm config initrd /root/que.initrd
mm vm config filesystem /root/quefs

# from arguments
mm vm config vcpus $NCPUS

# configure and launch server
if [[ "$VMTYPE" == "kvm" ]]; then
    mm shell cp /root/base.qcow2 $TMPDIR/$namespace/server.qcow2
    mm vm config disk $namespace/server.qcow2
    mm vm config snapshot false
    mm vm config net LAN,$DRIVER
elif [[ "$VMTYPE" == "container" ]]; then
    mm vm config volume /que $TMPDIR/$namespace/server
    mm vm config net LAN
fi
mm vm config tag name server
mm vm config uuid 11111111-1111-1111-1111-111111111111
mm vm launch $VMTYPE server

# configure and launch client
if [[ "$VMTYPE" == "kvm" ]]; then
    mm shell cp /root/base.qcow2 $TMPDIR/$namespace/client.qcow2
    mm vm config disk $namespace/client.qcow2
    mm vm config snapshot false
    mm vm config net LAN,$DRIVER
elif [[ "$VMTYPE" == "container" ]]; then
    mm vm config volume /que $TMPDIR/$namespace/client
    mm vm config net LAN
fi
mm vm config tag name client
mm vm config uuid 22222222-2222-2222-2222-222222222222
mm vm launch $VMTYPE client

# push all the files we'll need
mm cc log level info
mm cc send file:protonuke

# set static IPs
mm cc filter name=server
mm cc exec ip link set $ifname up
mm cc exec ip addr add 10.0.0.1/24 dev $ifname

mm cc filter name=client
mm cc exec ip link set $ifname up
mm cc exec ip addr add 10.0.0.2/24 dev $ifname

# print offloading features before and after disabling a bunch of it
mm clear cc filter
mm cc exec ethtool -k $ifname
for v in sg tso gso gro; do
    mm cc exec ethtool -K $ifname $v $OFFLOAD
done
mm cc exec ethtool -k $ifname

# grab initial values
mm cc exec ifconfig
mm cc recv /proc/net/netstat

# mount the drive
if [[ "$VMTYPE" == "kvm" ]]; then
    mm cc exec modprobe ext4
    mm cc exec modprobe sd_mod
    mm cc exec modprobe ata_piix
    mm cc exec mkdir /que
    mm cc exec mount /dev/sda /que
    mm cc exec bash -c '"lsblk > /que/lsblk"'
fi

# start background data gathering, if instrumentation is turned on.
#
# note: we always run vmstat regardless of the instrument flag.
mm cc exec bash -c "'echo ethtool -S $ifname > /ethtool.bash'"
mm cc background bash -c '"vmstat 5 > /que/vmstat.log"'
mm cc background bash -c '"dmesg -t -w > /que/dmesg"'

if [[ "$INSTRUMENT" == "true" ]] ; then
    mm cc background bash -c '"while /bin/true; do cat /proc/sys/kernel/random/entropy_avail >> /que/entropy.log; sleep 5s; done"'
    # minimega will try to expand the $i if we don't turn off preprocessing
    mm .preprocess false cc background bash -c '"for i in $(seq 1000); do bash /ethtool.bash > /que/ethtool.$i; sleep 5s; done"'

    # start sysdig for kvm
    if [[ "$VMTYPE" == "kvm" ]]; then
        mm cc exec modprobe sysdig-probe
        mm cc exec bash -c '"lsmod > /que/lsmod"'
        mm cc exec bash -c '"uname -a > /que/uname"'
        mm cc background bash -c "'sysdig -w /que/sysdig.scap'"
    fi

    # start owampd
    mm cc filter name=server
    mm cc background bash -c "'owampd -f -Z > /que/owampd.out 2> /que/owampd.err'"

    # capture traffic for both VMs (from the hosts)
    mm capture pcap snaplen 200
    mm capture pcap vm server 0 $namespace/server.pcap
    mm capture pcap vm client 0 $namespace/client.pcap

    # start tcpdumps inside the VMs
    #mm clear cc filter
    #mm cc background bash -c "'tcpdump -i $ifname -n -w /que/tcpdump.pcap > /que/tcpdump.out 2> /que/tcpdump.err'"

    # start pinging in both directions
    mm cc filter name=server
    mm cc background bash -c "'ping 10.0.0.2 > /que/ping.out 2> /que/ping.err'"
    mm cc filter name=client
    mm cc background bash -c "'ping 10.0.0.1 > /que/ping.out 2> /que/ping.err'"
fi

# enable CPU pinning (processor affinity) if set in arguments
if [[ "$PINNING" == "true" ]] ; then
    mm optimize affinity true
fi

# start protonuke server
mm cc filter name=server
mm cc background /tmp/miniccc/files/protonuke -serve -http

# Apply rate, if not none
if [[ "$RATE" != "none" ]]; then
    mm qos add all 0 rate $RATE mbit
fi

mm echo "starting client and server..."
mm vm start all
