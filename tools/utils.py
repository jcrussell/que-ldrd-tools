# Copyright 2019 National Technology & Engineering Solutions of Sandia, LLC
# (NTESS). Under the terms of Contract DE-NA0003525 with NTESS, the U.S.
# Government retains certain rights in this software.

'''
functions shared by mulitple tools
'''

import collections
import logging
import os
import re
import types


def check_test_broken(test_directory):
    """ A crude method to see if we have an e1000 issue. It'd be better to use
    the dmesg output, but we don't have that for a bunch of existing data. This
    checks the apache bench file, and uses the crude metric of "is the maximum
    more than 10x then median, and is the maximum more than 1 second".
    """
    logging.debug("Checking test broken for test: {path}".format(path=test_directory))

    # Find the ab.out file in the test directory
    ab_file = None
    for directory, subdirectories, files in os.walk(test_directory):
        for file in files:
            if file == "ab.out":
                ab_file = os.path.join(directory, file)
                break

    # No way to determine
    if not ab_file:
        logging.error("No ab.out, cannot discern broken-ness of test")
        return "unknown"

    median_regex  = re.compile('^ *50% *(?P<duration>\d+)$')
    longest_regex = re.compile('^ *100% *(?P<duration>\d+) \(longest request\)$')

    longest = None
    median  = None

    logging.debug("Reading Apache Bench file: {fname}".format(fname=ab_file))
    with open(ab_file) as fh:
        for line in fh:
           m = median_regex.match(line)
           if m:
               median = int(m.group(1))

           m = longest_regex.match(line)
           if m:
               longest = int(m.group(1))

    if not longest or not median:
        return "unknown"

    logging.debug("Median apache bench request: {duration}".format(duration=median))
    logging.debug("Longest apache bench request: {duration}".format(duration=longest))

    if longest/median < 10 or \
       longest < 1000:
        return "false"

    return "true"



def guess_test_parameters(fname):
    """ Guesses the test parameters from the directories a file is in """
    environment = None
    mixed_split = "mixed" if "mixed" in fname else "split"
    cluster = "ccc"

    broken_test = "unknown"

    #path = os.path.dirname(fname)
    path = fname

    # Account for path field differences
    path = path.replace("virtio-net-pci", "virtio")
    prev_path = None

    # assume disabled
    instrumentation = "disabled"
    pinning = "disabled"
    gre = "disabled"
    colocated = "disabled"
    stress_cpu = 0
    stress_io = 0
    stress_mem = 0

    # assume enabled
    hyperthreading = "enabled"

    instance = None

    while path and not environment:
        logging.debug("Trying path: {path}".format(path=path))

        if path == "/":
            break

        base = os.path.basename(path)
        parts = base.split('-')

        if base.startswith("que"):
            instance = base
            prev_path = path
            path = os.path.dirname(path)
            continue

        try:
            if parts[0] == "physical":
                environment, nic, offloading, num_workers, workload = parts[:5]
                # fill these in
                nvcpus = 1
                rate_limit = nic.replace("g", "000")
                num_simultaneous = 1
            else:
                # unpack in order based from run.bash
                environment, nic, nvcpus, offloading, rate_limit, num_workers, num_simultaneous, workload = parts[:8]

            # now, check for "extras"
            for v in parts:
                if v == "instr":
                    instrumentation = "enabled"
                elif v == "pinning":
                    pinning = "enabled"
                elif v == "gre":
                    gre = "enabled"
                elif v == "colocated":
                    colocated = "enabled"
                elif v.startswith("stresscpu"):
                    stress_cpu = int(v[9:])
                elif v.startswith("stressio"):
                    stress_io = int(v[8:])
                elif v.startswith("stressmem"):
                    stress_mem = int(v[9:])
                elif v == "noht":
                    hyperthreading = "disabled"

            iteration = int(os.path.basename(prev_path))

            # no exceptions means that we decoded it properly
            break
        except Exception as e:
            pass

        prev_path = path
        path = os.path.dirname(path)

    if not environment:
        return

    # Fix up the test_directory so that it corresponds to an actual path...
    test_directory = prev_path
    test_directory = test_directory.replace("virtio", "virtio-net-pci")

    # Do the check_test_broken function after anything that might
    # fail to avoid recursive descent into / or whatever
    #broken_test = check_test_broken(test_directory)

    if offloading == "on":
        offloading = "enabled"
    elif offloading == "off":
        offloading = "disabled"

    # keep in an order we like
    return collections.OrderedDict([
        ("iteration", iteration),
        ("instance", instance),
        ("cluster", cluster),
        ("environment", environment),
        ("nic", nic),
        ("num_vcpus", nvcpus),
        ("num_workers", num_workers),
        ("num_simultaneous", num_simultaneous),
        ("rate_limit", rate_limit),
        ("workload", workload),
        ("broken", broken_test),
        ("instrumentation", instrumentation),
        ("offloading", offloading),
        ("pinning", pinning),
        ("gre", gre),
        ("colocated", colocated),
        ("stress_cpu", stress_cpu),
        ("stress_io", stress_io),
        ("stress_mem", stress_mem),
        ("hyperthreading", hyperthreading),
    ]), test_directory


def columns(exemplar, skipCols):
    """
    columns returns a list of tuples for column name and type from the
    exemplar, skipping any columns from skipCols.
    """
    cols = []

    for k, v in exemplar.items():
        if k in skipCols:
            continue

        if type(v) is str or type(v) is unicode:
            cols.append((k, 'STRING'))
        elif type(v) is int:
            cols.append((k, 'INT'))
        elif type(v) is float:
            cols.append((k, 'REAL'))
        elif type(v) is types.NoneType:
            cols.append((k, 'STRING'))
        else:
            logging.info("unknown type for {}: {}".format(k, type(v)))

    return cols

def create_table_stmt(name, exemplar, skipCols=[]):
    """
    create_table creates a database table with the specified name for the given
    exemplar. It returns an insert statement for that table.
    """
    cols = columns(exemplar, skipCols)

    create = 'CREATE TABLE {} ({})'.format(name,
            ','.join([x+' '+y for (x, y) in cols]))
    logging.info(create)

    return create

def insert_stmt(name, exemplar, skipCols=[]):
    """
    insert_stmt returns a statement to insert the exemplar into the specified
    table, skipping any columns in skipCols.
    """
    cols = columns(exemplar, skipCols)

    insert = 'INSERT INTO {} ({}) VALUES ({})'.format(name,
            ','.join([v for (v, _) in cols]),
            ','.join('?'*len(cols)))
    logging.info(insert)

    return insert
