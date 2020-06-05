# Copyright 2019 National Technology & Engineering Solutions of Sandia, LLC
# (NTESS). Under the terms of Contract DE-NA0003525 with NTESS, the U.S.
# Government retains certain rights in this software.

INSTRUMENT="true false"

PINNING="false"

GRE="false"

# concurrent runs
CONCURRENT="1 2 4 8 12 16 20 24 28 32 36 40" # 48 56 64 72 80 88 96 100 104"

# Parameter space to sweep
TYPES="kvm"
KVM_DRIVERS="e1000 virtio-net-pci"
NCPUS="1"
OFFLOAD="on"
RATES="1000"
NWORKERS="1"
QUERIES="100000,http://10.0.0.1/ 1000,http://10.0.0.1/image.png?size=16MB"

DURATION=360

STRESS_CPU="0"
STRESS_IO="0"
STRESS_MEM="0"
# with stress
#STRESS_CPU="0 4 16"
#STRESS_IO="0 4 16"
#STRESS_MEM="0 4 16"

# How many times to run each set of parameters
ITERS=10
