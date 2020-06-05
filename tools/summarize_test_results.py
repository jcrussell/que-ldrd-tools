#!/usr/bin/python

# Copyright 2019 National Technology & Engineering Solutions of Sandia, LLC
# (NTESS). Under the terms of Contract DE-NA0003525 with NTESS, the U.S.
# Government retains certain rights in this software.

"""
Reads through a list of test directories, collects data from the files and
generates a CSV. It reads the environmental parameters from the directory name
where the file is located.

To run it, you'll need to pass a list of files to read. These files must have
information about the tests somewhere in the directory naming convention.

Usage: python summarize_test_results.py -o results.csv 1-concurrent-20171226-physical-10g
"""

import csv
import collections
import fnmatch
import json
import numpy
import re
import os
import sys
import logging
import subprocess
import sqlite3

import utils

from distutils.spawn import find_executable

class TcptraceReader(object):
    """ A class to read the output from tcptrace files """
    field_no_units_regex = re.compile('^(?P<client_field>[^:]+):\s+(?P<client_value>\S+)\s+(?P<server_field>[^:]+):\s+(?P<server_value>\S+)$')
    field_regex = re.compile('^(?P<client_field>[^:]+):\s+(?P<client_value>\S+)\s+(?P<client_units>\S+)\s+(?P<server_field>[^:]*):\s+(?P<server_value>\S+)\s+(?P<server_units>\S+)$')
    total_packets =  re.compile('^total packets:\s+(?P<packets>\d+)$')
    skip_fields = [ "req sack", "req 1323 ws/ts", "SYN/FIN pkts sent" ]
    min_packets = 0

    def readfile(self, f):
       """ Yields tcp parameters for each side of a connection """
       handle_connection = False

       for line in f:
           line = line.strip()

           m = TcptraceReader.total_packets.match(line)
           if m:
               if int(m.group('packets')) < TcptraceReader.min_packets:
                   handle_connection = False
               else:
                   handle_connection = True

           if not handle_connection:
               continue

           m = TcptraceReader.field_no_units_regex.match(line)
           if not m:
               m = TcptraceReader.field_regex.match(line)

           if not m:
               #print 'Line does not match: {}'.format(line)
               continue

           try:
               units = m.group('client_units')
           except:
               units = ''

           if m.group('client_field') in TcptraceReader.skip_fields:
               continue

           try:
               client_value = int(m.group('client_value'))
           except:
               try:
                   client_value = float(m.group('client_value'))
               except:
                   client_value = 0

           try:
               server_value = int(m.group('server_value'))
           except:
               try:
                   server_value = float(m.group('server_value'))
               except:
                   server_value = 0

           yield "client", m.group('client_field'), client_value
           yield "server", m.group('server_field'), server_value


class TcptraceSummaryReader(object):
    """
    Wraps TcptraceReader and returns the summary of each field
    """

    def readfile(self, f):
        values = {}

        for direction, field, value in TcptraceReader().readfile(f):
            key = (direction, field)
            if key not in values:
                values[key] = []

            values[key].append(value)

        for ((direction, field), vals) in values.items():
            for stat, val in stats(vals):
                yield direction, field.replace(' ', '_') + '_' + stat, val


class aBenchReader(object):
    """
    A class to read Apache Bench output and collect stats we
    want to monitor.

    e.g.

        Time taken for tests:   32.885 seconds
        Complete requests:      500000
        Failed requests:        0
        Total transferred:      235336742 bytes
        HTML transferred:       146836742 bytes
        Requests per second:    15204.37 [#/sec] (mean)
        Time per request:       0.658 [ms] (mean)
        Time per request:       0.066 [ms] (mean, across all concurrent requests)
        Transfer rate:          6988.57 [Kbytes/sec] received

    """

    time_taken =  re.compile('^Time taken for tests:\s+(?P<taken>\d+\.?\d*) seconds')
    requests =  re.compile('^Requests per second:\s+(?P<requests>\d+\.?\d*)')
    transfer =  re.compile('^Transfer rate:\s+(?P<transfer>\d+\.?\d*)')
    completed_reqs =  re.compile('^Complete requests:\s+(?P<completed>\d+\.?\d*)')
    failed_reqs =  re.compile('^Failed requests:\s+(?P<failed>\d+\.?\d*)')


    def readfile(self, f):
        total_seen = 0

        #  ab is only on the client.
        direction = "client"

        for line in f:
           line = line.strip()

           logging.debug("Reading: {line}".format(line=line))

           if line.startswith("Time taken"):
               m = aBenchReader.time_taken.match(line)
               if m:
                   try:
                       time_taken = float(m.group('taken'))

                       total_seen += 1
                       yield direction, "ab_time_taken", time_taken

                   except Exception as e:
                       logging.error(e)
                       pass
           elif line.startswith("Requests per"):
               m = aBenchReader.requests.match(line)
               if m:
                   try:
                       requests = float(m.group('requests'))

                       total_seen += 1
                       yield direction, "ab_requests_per_second", requests

                   except Exception as e:
                       logging.error(e)
                       pass
           elif line.startswith("Transfer rate"):
               m = aBenchReader.transfer.match(line)
               if m:
                   try:
                       transfer = float(m.group('transfer'))

                       total_seen += 1
                       yield direction, "ab_transfer_rate", transfer

                   except Exception as e:
                       logging.error(e)
                       pass
           elif line.startswith("Failed requests"):
               m = aBenchReader.failed_reqs.match(line)
               if m:
                   try:
                       failed = int(m.group('failed'))

                       total_seen += 1
                       yield direction, "ab_failed_requests", failed

                   except Exception as e:
                       logging.error(e)
                       pass
           elif line.startswith("Complete requests"):
               m = aBenchReader.completed_reqs.match(line)
               if m:
                   try:
                       completed = int(m.group('completed'))

                       total_seen += 1
                       yield direction, "ab_completed_requests", completed

                   except Exception as e:
                       logging.error(e)
                       pass



        logging.debug("Finished parsing {file}".format(file=f.name))

        if total_seen < 5:
            logging.error("Parse error for {file}".format(file=f.name))



class PowstreamReader(object):
    """ A class to reader the output from powstream client by converting the
        owp output into what's output by the owping client, and using the
        OwampReader on it

        e.g.

        9000 sent, 0 lost (0.000%), 0 duplicates
        one-way delay min/median/max = 971/971/988 ms, (unsync)
        one-way jitter = 0.8 ms (P95-P50)
    """
    def __init__(self, direction):
        self.direction = direction

    def readfile(self, f):
        owamp_reader = OwampReader(direction=self.direction)

        if not find_executable('owstats'):
          logging.error("Parse error for {file}: cannot find 'owstats' executable".format(file=f.name))
          return

        cmd = [ "owstats", "-v", f.name ]
        p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

        for side, field, value in owamp_reader.readfile(p.stdout):
            yield side, field, value

class OwampReader(object):
    """ A class to reader the output from owamp client

        e.g.

        9000 sent, 0 lost (0.000%), 0 duplicates
        one-way delay min/median/max = 971/971/988 ms, (unsync)
        one-way jitter = 0.8 ms (P95-P50)
    """
    packet_summary =  re.compile('^(?P<packets>\d+) sent, (?P<lost>\d+) lost.*, (?P<dups>\d+) duplicates')
    jitter_summary =  re.compile('^one-way jitter = (?P<jitter>\d+\.?\d*) ms')

    def __init__(self, direction=None):
        self.direction = direction

    def readfile(self, f):
       is_c2s = True
       total_seen = 0

       for line in f:
           line = line.strip()

           if self.direction:
               direction = self.direction
           else:
               direction = "client" if is_c2s else "server"

           m = OwampReader.packet_summary.match(line)
           if m:
               try:
                   #print >>sys.stderr, "Matched summary"
                   packet_value = int(m.group('packets'))
                   lost_value   = int(m.group('lost'))
                   dups_value   = int(m.group('dups'))

                   total_seen += 1

                   yield direction, "owamp_packets", packet_value
                   yield direction, "owamp_lost", lost_value
                   yield direction, "owamp_dups", dups_value
               except Exception as e:
                   logging.error(e)
                   pass

           m = OwampReader.jitter_summary.match(line)
           if m:
               try:
                   #print >>sys.stderr, "Matched jitter"
                   jitter_value = float(m.group('jitter'))

                   total_seen += 1

                   # This is the last value we expect
                   is_c2s = False

                   yield direction, "owamp_jitter", jitter_value
               except Exception as e:
                   logging.error(e)
                   pass


       if self.direction and total_seen < 2:
          logging.error("Parse error for {file}".format(file=f.name))
       elif not self.direction and total_seen < 4:
          logging.error("Parse error for {file}".format(file=f.name))

class VmStatsReader(object):
    """ A class to read the output from vmstat files """

    def __init__(self, direction):
        self.direction = direction

    def readfile(self, f):
        """ Yields syscall parameters for each side of a connection """
        fields_names = [
                         "running",
                         "blocked",
                         "mem_swapped",
                         "mem_free",
                         "mem_buffers",
                         "mem_cache",
                         "swap_in",
                         "swap_out",
                         "blocks_in",
                         "blocks_out",
                         "int_rate",
                         "cs_rate",
                         "cpu_user",
                         "cpu_sys",
                         "cpu_idle",
                         "cpu_wait",
                         "cpu_stolen",
                       ]

        for line in f:
            try:
                line = line.strip()
                fields = line.split()
                for i, value in enumerate(fields):
                    field_name = fields_names[i]

                    yield self.direction, "vm_{}".format(field_name), int(value)
            except:
                pass

class InterruptsReader(object):
    """ A class to read Linux '/proc/interrupts' files """
    def __init__(self, direction):
        self.direction = direction

    def readfile(self, f):
       """ Yields each interrupt total """
       header = f.readline()
       cpus = header.split()
       cpu_count = len(cpus)

       for line in f:
           line = line.strip()

           fields = line.split()
           if len(fields) < 3:
               continue

           irq = fields[0].strip(':')
           if irq.isdigit():
               irq = fields[-1].lower()

           # Normalize the irq name
           irq = irq.lower()
           irq = re.sub("[^a-z0-9_]", "_", irq)

           total_interrupts = 0
           for val in fields[1:cpu_count+1]:
               total_interrupts += int(val)

           yield self.direction, "int_{}".format(irq), total_interrupts

class SysdigFreqReader(object):
    """ A class to read the output from sysdig files """
    def __init__(self, direction):
        self.direction = direction

    def readfile(self, f):
        """
        Yields syscall parameters for each side of a connection from:

        # Calls             Syscall
        --------------------------------------------------------------------------------
        800228              epoll_ctl
        600110              epoll_wait
        403494              read
        ...
        """

        # figure out if this is all the system calls or just the workload
        kind = "workload" if "workload" in f.name else "all"

        # throw away header
        f.readline()
        f.readline()

        for line in f:
            parts = line.split()
            # if the file is truncated, it dumps the table, and error, and then
            # the table again... only need the first table
            if len(parts) != 2:
                break
            count, syscall = line.split()
            yield self.direction, "sc_{}_{}".format(kind, parts[1]), int(parts[0])


class SysdigRawReader(object):
    """ A class to read the output from sysdig files """
    syscall_count_regex = re.compile('^(?P<value>\d+)\s+(?P<syscall>\S+)$')

    def __init__(self, direction):
        self.direction = direction

    def readfile(self, f):
        """ Yields syscall parameters for each side of a connection """
        try:
          cmd = [ "sysdig", "-r", f.name, "-c", "topscalls" ]
          p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
          for line in p.stdout:
              line = line.strip()
              # 10003030           close
              logging.debug(line)
              m = SysdigReader.syscall_count_regex.match(line)
              if m:
                  variable_name = "sc_{}".format(m.group('syscall'))
                  variable_value = int(m.group('value'))
                  logging.debug("{}, {}, {}".format(self.direction, variable_name, variable_value))
                  yield self.direction, variable_name, variable_value
          errmsg = "\n".join([ _ for _ in p.stderr ])
          if errmsg:
             logging.error(errmsg)

        except subprocess.CalledProcessError as exc:
            logging.error("Problem running sysdig: {}/{}".format(exc.returncode, exc.output))

def get_file_reader(fname):
    """ Returns a reader that can read the given file """
    if "owping.out" in fname:
        return OwampReader()
    elif fname.endswith("owp"):
        direction = "server" if "server" in fname else "client"
        return PowstreamReader(direction=direction)
    elif "server.tcptrace" in fname:
        return TcptraceSummaryReader()
    elif "ab.out" in fname:
        return aBenchReader()
    elif "interrupts" in fname:
        direction = "server" if "server" in fname else "client"
        return InterruptsReader(direction=direction)
    #elif "server.scap" in fname:
    #    return SysdigRawReader(direction="server")
    #elif "client.scap" in fname:
    #    return SysdigRawReader(direction="client")
    #elif "sysdig.scap" in fname:
    #    direction = "client" if "client" in fname else "server"
    #    return SysdigRawReader(direction=direction)
    elif "topscalls-" in fname:
        direction = "client" if "client" in fname else "server"
        return SysdigFreqReader(direction=direction)
    elif "vmstat.log" in fname:
        direction = "client" if "client" in fname else "server"
        return VmStatsReader(direction=direction)

    return

def exception_hook(type,value,tb):
    """ Hook to drop into a debugger when an exception occurs """
    if hasattr(sys,'ps1') or not sys.stderr.isatty():
        # we are intereactive or don't have a tty-like device
        sys.__excepthook__(type,value,tb)

        # We're not interactive let's debug it
    else:
        import traceback, pdb
        traceback.print_exception(type,value,tb)
        print
        pdb.pm()


def find_files(directories, types):
    for d in directories:
        for directory, subdirectories, files in os.walk(d):
            for f in files:
                if len(types) > 0 and \
                   len(filter(lambda x: fnmatch.fnmatch(f, x), types)) == 0:
                    logging.warn("Skipping file: {fname}".format(fname=f))
                    continue

                if get_file_reader(f):
                    fname = os.path.join(directory, f)
                    logging.debug("Adding {fname} to path".format(fname=fname))
                    yield fname


def create_db(db, directories=[], types=[], params_hint=None):
    conn = sqlite3.connect(db)
    conn.row_factory = sqlite3.Row
    cur = conn.cursor()
    cur2 = conn.cursor()

    envs = {}
    insert_experiment = None

    exemplar = collections.OrderedDict([
        ("experiment", 0),
        ("iteration", 1),
        ("instance", "queXYZ"),
        ("field", "example"),
        ("side", "client"),
        ("value", 0.0),
    ])
    cur.execute(utils.create_table_stmt("data", exemplar))
    insert_data = utils.insert_stmt("data", exemplar)

    values = []

    for fname in find_files(directories, types):
        if params_hint is not None:
            params, path = utils.guess_test_parameters(params_hint)
        else:
            params, path = utils.guess_test_parameters(fname)
        if not params:
            logging.warn("Unknown test type: {fname}".format(fname=fname))

        # save iteration/instance and then delete them from the params
        saved = {}
        for c in ["iteration", "instance"]:
            saved[c] = params[c]
            del params[c]

        file_reader = get_file_reader(fname)
        if not file_reader:
            loging.warn("Unknown file type: {fname}".format(fname=fname))

        logging.info("Reading {fname}".format(fname=fname))
        full_env = json.dumps(params)

        if full_env not in envs:
            if insert_experiment is None:
                cur.execute(utils.create_table_stmt("experiments", params))
                insert_experiment = utils.insert_stmt("experiments", params)

            cur.execute(insert_experiment, params.values())
            envs[full_env] = cur.lastrowid

        with open(fname) as f:
            for side, field, value in file_reader.readfile(f):
                row = (envs[full_env], saved["iteration"], saved["instance"], field, side, value)
                values.append(row)
                if len(values) > 100000:
                    cur.executemany(insert_data, values)
                    conn.commit()
                    values = []

    if len(values) > 0:
        cur.executemany(insert_data, values)
        conn.commit()

    cur.close()
    conn.close()
    return


def summarize_db(db):
    conn = sqlite3.connect(db)
    conn.row_factory = sqlite3.Row
    cur = conn.cursor()
    cur2 = conn.cursor()

    # now that all the data is in the database, build the summary table
    exemplar = collections.OrderedDict([
        ("experiment", 0),
        ("field", "example"),
        ("side", "client"),
    ])
    exemplar.update(stats([0.0]))
    cur.execute(utils.create_table_stmt("summary", exemplar))
    insert_summary = utils.insert_stmt("summary", exemplar)

    # get all the results for all the non-broken tests
    query = 'SELECT data.* FROM data INNER JOIN experiments ON data.experiment=experiments.rowid WHERE broken!="true" ORDER BY data.experiment, data.side, data.field'

    last = None
    vals = []
    for r in cur.execute(query):
        r = collections.OrderedDict(r)
        for c in ["iteration", "instance"]:
            del r[c]

        if last != None and last['field'] != r['field']:
            # add stats and insert the params
            last.update(stats(vals))
            cur2.execute(insert_summary, last.values())
            vals = []

        if last == None or last['field'] != r['field']:
            # first row or new set of params
            last = collections.OrderedDict()
            for k in r.keys():
                last[k] = r[k]

            del last['value']

        vals.append(float(r['value']))

    if last != None:
        # insert the final set of params
        last.update(stats(vals))
        cur2.execute(insert_summary, last.values())

    conn.commit()

    cur.close()
    cur2.close()
    conn.close()
    return


def main(directories=[], types=[], output_fh=sys.stdin, full_results=False, params_hint=None):
    values = {}

    files_to_read = find_files(directories, types)

    for fname in sorted(set(files_to_read)):
        if params_hint is not None:
            test_parameters, path = utils.guess_test_parameters(params_hint)
        else:
            test_parameters, path = utils.guess_test_parameters(fname)
        if not test_parameters:
            logging.warn("Unknown test type: {fname}".format(fname=fname))

        file_reader = get_file_reader(fname)
        if not file_reader:
            loging.warn("Unknown file type: {fname}".format(fname=fname))

        logging.info("Reading {fname}".format(fname=fname))
        full_env = json.dumps(test_parameters, sort_keys=True)

        if not full_env in values:
            values[full_env] = { "paths": set(), "parameters": test_parameters, "client": {}, "server": {} }

        values[full_env]["paths"].add(path)

        with open(fname) as f:
            for side, field, value in file_reader.readfile(f):
                if not field in values[full_env][side]:
                    values[full_env][side][field] = []

                values[full_env][side][field].append({ "value": value, "source": fname })

    # Collect a list of the full set of result types that we've seen across
    # all tests that we can normalize the output of each test to include all
    # result types, whether they were seen in that test or not
    full_field_set = {
        "client": set(),
        "server": set(),
    }

    for env in values.values():
        for dirn in [ "client", "server" ]:
            for field in sorted(env[dirn].keys()):
               full_field_set[dirn].add(field)

    headers = [
                "environment",
                "nic",
                "num_vcpus",
                "rate_limit",
                "num_workers",
                "num_simultaneous",
                "cluster",
                "instrumentation",
                "offloading",
                "pinning",
                "gre",
                "broken",
                "workload",
                "side",
                "field",
                "instance",
                "iteration",
                "paths",
              ]


    if full_results:
        headers.extend([
                    "value"
                  ])
    else:
        headers.extend([
                    "count",
                    "median",
                    "mean",
                    "stdev",
                    "min",
                    "p25th",
                    "p75th",
                    "p95th",
                    "max",
                  ])

    writer = csv.DictWriter(output_fh, fieldnames=headers)
    writer.writeheader()

    for env in sorted(values.values()):
        for dirn in [ "client", "server" ]:
            for field in sorted(full_field_set[dirn]):
                curr_values = env[dirn].get(field, [])

                results = {}
                results.update(env["parameters"])
                results.update({ "side": dirn,
                                 "field": field })

                if full_results:
                    for value in curr_values:
                        results.update({ "value": value["value"],
                            "paths": value["source"] })
                        writer.writerow(results)
                else:
                    curr_values = map(lambda x: x["value"], curr_values)

                    results.update({ "paths": ",".join(env["paths"]) })
                    results.update(stats(curr_values))
                    writer.writerow(results)


def stats(vals):
    outliers = None
    if len(vals) > 0:
        # compute number of outliers based on 1.5 * interquartile range
        q1 = numpy.percentile(vals, 25)
        q3 = numpy.percentile(vals, 75)
        iqr = q3 - q1
        outliers = len([i for i in vals if i < (q1 - 1.5*iqr) or i > (q3 + 1.5*iqr)])

    # in preferred order
    return [
        ("count", len(vals)),
        ("min", str(min(vals)) if len(vals) > 0 else ""),
        ("p25th", str(numpy.percentile(vals, 25)) if len(vals) > 0 else ""),
        ("median", str(numpy.median(vals)) if len(vals) > 0 else ""),
        ("p75th", str(numpy.percentile(vals, 75)) if len(vals) > 0 else ""),
        ("p95th", str(numpy.percentile(vals, 95)) if len(vals) > 0 else ""),
        ("max", str(max(vals)) if len(vals) > 0 else ""),
        ("mean", str(numpy.mean(vals)) if len(vals) > 0 else ""),
        ("stdev", str(numpy.std(vals)) if len(vals) > 0 else ""),
        ("outliers", str(outliers) if len(vals) > 0 else ""),
    ]


if __name__ == "__main__":
    sys.excepthook = exception_hook   # catch all unhandled exceptions


    from argparse import ArgumentParser
    parser = ArgumentParser(description="Parse test results from QUE tests")
    parser.add_argument("-o", "--output", metavar='FILE', type=str, help="CSV output file", default="-")
    parser.add_argument("-f", "--full-results", dest='full_results', action='store_true', default=False)
    parser.add_argument("-t", "--type", metavar='TYPE', type=str, help="File types e.g. ab.out, owping.out, server.tcptrace", action="append", default=[])
    parser.add_argument("-v", "--verbose", dest='verbose', action='store_true', default=False)
    parser.add_argument("-d", "--db", dest='db', type=str, help='write data to database instead of CSV')
    parser.add_argument("-s", "--summarize", dest='summarize', action='store_true', help='generate summary table in database', default=False)
    parser.add_argument("-p", "--params", dest='params', type=str, help='params hint, passed to guess_test_parameters')
    parser.add_argument("directories", metavar='TEST_DIRECTORIES', type=str, nargs='+',
                   help='Test directories to read')
    args = parser.parse_args()

    if args.output == "-":
        out_fh = sys.stdout
    else:
        out_fh = open(args.output, 'w')

    level = logging.INFO
    if args.verbose:
        level = logging.DEBUG

    log_format="%(asctime)s: %(levelname)s %(message)s"
    logging.basicConfig(level=level, format=log_format)

    if args.db != None:
        create_db(args.db, args.directories, args.type, args.params)
        if args.summarize:
            summarize_db(args.db)
    elif args.summarize:
        if len(args.directories) != 1:
            logging.error('expected database argument to generate summary table for')
            sys.exit(1)

        summarize_db(args.directories[0])
    else:
        main(directories=args.directories, types=args.type, output_fh=out_fh, full_results=args.full_results, params_hint=args.params)
