# Copyright 2019 National Technology & Engineering Solutions of Sandia, LLC
# (NTESS). Under the terms of Contract DE-NA0003525 with NTESS, the U.S.
# Government retains certain rights in this software.

# sweep generates a list of commands that will sweep the parameters from a
# file. Can then be fed into parallel, for example:
#
#   bash sweep.bash /scatch/test/ params.bash | parallel -j1 --eta -S en7,en10
#
# Expects the following arguments:
#
#  * dir:       directory to store results
#  * params:    file containing parameters to sweep

if [ $# -ne 2 ]; then
    echo "USAGE: $0 DIR PARAMS"
    exit 1
fi

OUT=$1
. $2

for concurrent in $CONCURRENT; do
    for vmtype in $TYPES; do
        for driver in $KVM_DRIVERS; do
            for ncpus in $NCPUS; do
                for offload in $OFFLOAD; do
                    for rate in $RATES; do
                        for nworkers in $NWORKERS; do
                            for v in $QUERIES; do
                                # split on `,`
                                nrequests=${v%%,*}
                                url=${v#*,}

                                for instrument in $INSTRUMENT; do
                                    for pinning in $PINNING; do
                                        for gre in $GRE; do
                                            # filter out parameter sets where pinning and gre are both true
                                            if [[ $gre == "false" || $pinning == "false" ]]; then
                                                for stress_cpu in $STRESS_CPU; do
                                                    for stress_io in $STRESS_IO; do
                                                        for stress_mem in $STRESS_MEM; do
                                                            for i in $(seq $ITERS); do
                                                                echo "bash /root/run.bash $OUT $i $DURATION $concurrent $vmtype $driver $ncpus $offload $rate $nworkers $url $nrequests $instrument $pinning $gre $stress_cpu $stress_io $stress_mem"
                                                            done
                                                        done
                                                    done
                                                done
                                            fi
                                        done
                                    done
                                done
                            done
                        done
                    done
                done
            done

            # containers ignore the driver
            if [[ "$vmtype" == "container" ]]; then
                break
            fi
        done
    done
done
