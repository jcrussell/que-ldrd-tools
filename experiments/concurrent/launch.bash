#! /bin/bash

# Copyright 2019 National Technology & Engineering Solutions of Sandia, LLC
# (NTESS). Under the terms of Contract DE-NA0003525 with NTESS, the U.S.
# Government retains certain rights in this software.

if [ $# -ne 1 ]; then
    echo "USAGE: $0 CONTEXT"
    exit 1
fi

#TMPDIR=/tmp/minimega/files/
TMPDIR=/scratch/files/

context=$1

export minirouterfs=/root/minirouterfs/
export minicccfs=/root/minicccfs/
export images=/root

# kill any lingering instances of minimega first
if [ "$(pgrep mini)" != "" ]; then
    /root/minimega -e quit
fi

# now start minimega
nohup /root/minimega -logfile /root/mm.log -level info -degree 2 -context $context -nostdin -filepath $TMPDIR &> /root/mm.out &

