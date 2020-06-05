#! /bin/bash

# Copyright 2019 National Technology & Engineering Solutions of Sandia, LLC
# (NTESS). Under the terms of Contract DE-NA0003525 with NTESS, the U.S.
# Government retains certain rights in this software.

# Copy files to nodes, for example:
#
#   bash prep.bash ccc 10 12 foo
#
#   bash prep.bash en 10 12 bar

if [ $# -ne 4 ]; then
    echo "USAGE: $0 PREFIX START END CONTEXT"
    exit 1
fi

#TMPDIR=/tmp/minimega/files/
TMPDIR=/scratch/files/

PREFIX=$1
MIN=$2
MAX=$3
CONTEXT=$4

function prep {
    host=$1

    echo "== prep'n $host =="

    scp ~/que_vendor/* $host:

    # extract and update container filesystems
    ssh $host tar -xf quefs.tar.gz

    scp launch.bash $host:
    ssh $host bash launch.bash $CONTEXT

    # wait for minimega to start
    sleep 5

    # push environment scripts
    scp env.bash $host:
    scp run.bash $host:
    scp sweep.bash $host:
    scp params-*.bash $host:

    # push post-processing scripts
    scp ../../tools/summarize_test_results.py $host:
    scp ../../tools/combine.py $host:
    scp ../../tools/utils.py $host:

    ssh $host cp /root/protonuke $TMPDIR/

    # load sysdig
    ssh $host modprobe sysdig-probe

    echo "== prep'd $host =="
}

for i in $(seq $MIN $MAX); do
    # prep each in parallel and then wait for all to finish
    prep $PREFIX$i &
done

wait
