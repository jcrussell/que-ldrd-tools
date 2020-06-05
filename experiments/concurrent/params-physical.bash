# Copyright 2019 National Technology & Engineering Solutions of Sandia, LLC
# (NTESS). Under the terms of Contract DE-NA0003525 with NTESS, the U.S.
# Government retains certain rights in this software.

INSTRUMENT="true false"

OFFLOAD="on off"
NWORKERS="1 10"

QUERIES="100000,http://10.0.0.1/ 10000,http://10.0.0.1/image.png?size=1MB 1000,http://10.0.0.1/image.png?size=16MB"

DURATION=180

# How many times to run each set of parameters
ITERS=10
