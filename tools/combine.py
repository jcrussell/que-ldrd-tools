#!/usr/bin/python

# Copyright 2019 National Technology & Engineering Solutions of Sandia, LLC
# (NTESS). Under the terms of Contract DE-NA0003525 with NTESS, the U.S.
# Government retains certain rights in this software.

'''
Combine multiple databases into a single database.
'''

import collections
import json
import logging
import os
import sqlite3

import utils

def copy_table(name, cur, cur2, mapper):
    '''
    copy_table copies
    '''
    r = cur2.execute('SELECT * FROM {} LIMIT 1'.format(name)).fetchone()

    insert = utils.insert_stmt(name, collections.OrderedDict(r))

    # find the index of the experiment column
    index = [i for (i, v) in enumerate(r.keys()) if v == "experiment"][0]

    values = []

    for r in cur2.execute('SELECT * FROM {}'.format(name)):
        row = list(r)
        row[index] = mapper[r[index]]

        values.append(row)
        if len(values) > 100000:
            cur.executemany(insert, values)
            values = []

    if len(values) > 0:
        cur.executemany(insert, values)


def merge(db, db2):
    conn = sqlite3.connect(db)
    conn.row_factory = sqlite3.Row
    cur = conn.cursor()
    conn2 = sqlite3.connect(db2)
    conn2.row_factory = sqlite3.Row
    cur2 = conn2.cursor()

    dst_tables = {}
    src_tables = {}

    # check that tables are identical, create tables in db if they don't exist
    for r in cur.execute('SELECT name,sql from SQLITE_MASTER WHERE type="table"'):
        dst_tables[r['name']] = r['sql']
    for r in cur2.execute('SELECT name,sql from SQLITE_MASTER WHERE type="table"'):
        src_tables[r['name']] = r['sql']
        if r['name'] in dst_tables:
            if r['sql'] != dst_tables[r['name']]:
                logging.error('tables do not match for {}: {} and {}'.format(r['name'], db, db2))
                return
        else:
            # create table since it doesn't exist
            cur.execute(r['sql'])

    if 'experiments' not in src_tables:
        logging.warn('db does not have experiments table: {}'.format(db2))
        return

    # map from params to updated ID
    params = {}

    # read all the existing experiments in the destination db
    for r in cur.execute('SELECT rowid,* from experiments'):
        row = collections.OrderedDict(r)
        del row['rowid']

        params[json.dumps(row, sort_keys=True)] = r['rowid']

    # map from old ID to updated IDs in the new database
    mapper = {}

    insert_experiment = None

    # copy rows from experiments and create ids map
    for r in cur2.execute('SELECT rowid,* from experiments'):
        if r['rowid'] in mapper:
            # that's strange
            logging.warn('duplicate experiments IDs in {}'.format(db2))

        row = collections.OrderedDict(r)
        del row['rowid']

        p = json.dumps(row, sort_keys=True)
        if p in params:
            # we already have an experiment ID for these params so don't
            # insert this row
            mapper[r['rowid']] = params[p]
            continue

        if insert_experiment is None:
            insert_experiment = utils.insert_stmt('experiments', row)

        cur.execute(insert_experiment, row.values())

        mapper[r['rowid']] = cur.lastrowid
        params[p] = cur.lastrowid

    conn.commit()

    # copy rows from data
    copy_table('data', cur, cur2, mapper)
    conn.commit()

    # copy rows from summary, if it exists
    if 'summary' in src_tables:
        copy_table('summary', cur, cur2, mapper)
        conn.commit()


if __name__ == '__main__':
    from argparse import ArgumentParser
    parser = ArgumentParser(description='combine databases from multiple tests')
    parser.add_argument('-v', '--verbose', dest='verbose', action='store_true', default=False)
    parser.add_argument('-f', '--find', dest='find', type=str, help='directory to walk to search for databases')
    parser.add_argument('dest', metavar='DEST', type=str, help='destination database')
    parser.add_argument('src', metavar='SRC', type=str, nargs='*', help='databases to read')

    args = parser.parse_args()

    level = logging.INFO
    if args.verbose:
        level = logging.DEBUG

    log_format='%(asctime)s: %(levelname)s %(message)s'
    logging.basicConfig(level=level, format=log_format)

    if args.find:
        logging.info('walking from {}'.format(args.find))
        for root, dirs, files in os.walk(args.find):
            for fname in files:
                if fname.endswith('.sqlite3'):
                    merge(args.dest, os.path.join(root, fname))

    for src in args.src:
        merge(args.dest, src)
