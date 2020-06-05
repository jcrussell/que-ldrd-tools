#! /usr/bin/env python

# Copyright 2019 National Technology & Engineering Solutions of Sandia, LLC
# (NTESS). Under the terms of Contract DE-NA0003525 with NTESS, the U.S.
# Government retains certain rights in this software.

'''
Runs igor commands across multiple reservations based on a regular expression.
'''

import argparse
import binascii
import json
import os
import re
import subprocess

def regex_arg(s):
    """
    Compile regex pattern from argparse argument
    """
    r = re.compile(s)
    if r == None:
        raise argparse.ArgumentTypeError
    return r


def parse_reservations():
    """
    Parse the reservations file
    """
    # TODO: update depending on head node configuration
    with open("/var/ftpd/igor/reservations.json") as f:
        return "ccc", json.load(f)


def matching_reservations(pat, reservations):
    """
    Yields reservations matching pattern.
    """
    for r in sorted(reservations.values(), key=lambda v: v["ResName"]):
        if pat.match(r["ResName"]):
            yield r


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="make igor great again")
    parser.add_argument("pattern", type=regex_arg, help="regex pattern for reservations")
    parser.add_argument("--check", action="store_true", help="check that the nodes are all booted into the correct image")
    parser.add_argument("--cycle", action="store_true", help="power cycle all reservations")
    parser.add_argument("--off", action="store_true", help="power off all reservations")
    parser.add_argument("--prep-script", action="store_true", help="output prep script")
    parser.add_argument("--colocated", action="store_true", help="regenerate context for each host when generating prep-script")
    parser.add_argument("--heads", action="store_true", help="output head node for each reservation")
    parser.add_argument("--nodes", action="store_true", help="output all nodes for each reservation")
    parser.add_argument("--ps", type=str, help="search the ps output of each node for arg")
    parser.add_argument("--extend", type=str, help="extend reservations")

    args = parser.parse_args()

    prefix, reservations = parse_reservations()

    if args.check:
        for r in matching_reservations(args.pattern, reservations):
            ready = True
            for h in r["Hosts"]:
                try:
                    out = subprocess.check_output(["timeout", "3s", "ssh", h, "cat", "/etc/motd"])
                    if "que_host" not in out:
                        ready = False
                except subprocess.CalledProcessError:
                    ready = False
            print("Reservation {}: {}".format(r["ResName"], "ready" if ready else ""))
    elif args.cycle:
        for r in matching_reservations(args.pattern, reservations):
            try:
                subprocess.check_call(["igor", "power", "-r", r["ResName"], "cycle"])
            except subprocess.CalledProcessError:
                print("unable to power cycle {}".format(r["ResName"]))
    elif args.off:
        for r in matching_reservations(args.pattern, reservations):
            try:
                subprocess.check_call(["igor", "power", "-r", r["ResName"], "off"])
            except subprocess.CalledProcessError:
                print("unable to power off {}".format(r["ResName"]))
    elif args.extend:
        for r in matching_reservations(args.pattern, reservations):
            try:
                subprocess.check_call(["igor", "extend", "-r", r["ResName"], "-t", args.extend])
            except subprocess.CalledProcessError:
                print("unable to extend {}".format(r["ResName"]))
    elif args.prep_script:
        for r in matching_reservations(args.pattern, reservations):
            context = binascii.b2a_hex(os.urandom(8))
            for h in r["Hosts"]:
                if args.colocated:
                    context = binascii.b2a_hex(os.urandom(8))
                num = h[len(prefix):]
                print("bash prep.bash {} {} {} {}-{} &".format(prefix, num, num, r["ResName"], context))
            print("wait")
    elif args.heads:
        heads = []
        for r in matching_reservations(args.pattern, reservations):
            heads.append(r["Hosts"][0])
        print(",".join(heads))
    elif args.nodes:
        nodes = []
        for r in matching_reservations(args.pattern, reservations):
            nodes.extend(r["Hosts"])
        print(",".join(nodes))
    elif args.ps:
        for r in matching_reservations(args.pattern, reservations):
            res = []
            for h in r["Hosts"]:
                try:
                    out = subprocess.check_output(["timeout", "3s", "ssh", h, "ps", "aux"])
                    if args.ps in out:
                        res.append(h)
                    else:
                        res.append("[{}]".format(h))
                except subprocess.CalledProcessError:
                    pass
            print("Reservation {}: {}".format(r["ResName"], ", ".join(res)))
    else:
        for r in matching_reservations(args.pattern, reservations):
            print("Reservation: {}, nodes: {}".format(r["ResName"], ','.join(r["Hosts"])))
