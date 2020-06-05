# Copyright 2019 National Technology & Engineering Solutions of Sandia, LLC
# (NTESS). Under the terms of Contract DE-NA0003525 with NTESS, the U.S.
# Government retains certain rights in this software.

if [ $# -ne 2 ]; then
    echo "USAGE: $0 DIR PARAMS"
    exit 1
fi

OUT=$1
. $2

mkdir -p $OUT
cp $2 $OUT/params.bash

ssh="ssh -oStrictHostKeyChecking=no"
scp="scp -oStrictHostKeyChecking=no"

function run {
    # replace URLs with more path-friendly strings:
    #   http://10.0.0.1/                        -> http
    #   https://10.0.0.1/                       -> https
    #   https://10.0.0.1/image.png?size=15MB    -> https15MB
    # note: we get ambiguous URL names if there is no size parameter
    urlname=$(echo "$url" | sed 's/\(https\?\)[^=]\+=\?/\1/')
    speed=$(cat /sys/class/net/$INTERFACE/speed)
    name="physical-$((speed/1000))g-$offload-$nworkers-$urlname"

    if [[ "$INSTRUMENT" == "true" ]] ; then
        name="$name-instr"
    fi

    for i in $(seq $ITERS); do
        echo "$(date) name: $name, iteration: $i"

        dir=$OUT/$name/$i/
        if [ -d "$dir" ]; then
            echo "SKIPPING: $dir already exists"
            continue
        fi
        mkdir -p $dir

        # run as a block so that we can capture stdout/stderr
        {
            bash run-physical.bash $dir $INTERFACE $offload $nworkers $DURATION $url $nrequests $INSTRUMENT
        } > $dir/experiment.out 2> $dir/experiment.err

        echo "$(date) process results: name: $name, iteration: $i"

        # collect results via rsync
        mkdir $dir/server
        mkdir $dir/client
        rsync -a -e "$ssh" $SERVER:/que/* $dir/server/
        rsync -a -e "$ssh" $CLIENT:/que/* $dir/client/
        $ssh $SERVER rm -rf /que/
        $ssh $CLIENT rm -rf /que/

        if [[ "$INSTRUMENT" == "true" ]] ; then
            # process results
            parallel --will-cite -j6 <<EOF
tcptrace -l -f'port=80' $dir/server/server.pcap > $dir/server/server.tcptrace
tcptrace -l -f'port=80' $dir/client/client.pcap > $dir/client/client.tcptrace

sysdig -r $dir/server/sysdig.scap -c topscalls > $dir/server/topscalls-all.out
sysdig -r $dir/server/sysdig.scap -c topscalls proc.name=protonuke > $dir/server/topscalls-workload.out

sysdig -r $dir/client/sysdig.scap -c topscalls > $dir/client/topscalls-all.out
sysdig -r $dir/client/sysdig.scap -c topscalls proc.name=ab> $dir/client/topscalls-workload.out
EOF
        fi

        python summarize_test_results.py -d $dir/que.sqlite3 $dir

        echo "$(date) finished: name: $name, iteration: $i"
    done
}

for offload in $OFFLOAD; do
    for nworkers in $NWORKERS; do
        for v in $QUERIES; do
            # split on `,`
            nrequests=${v%%,*}
            url=${v#*,}
            run
        done
    done
done
