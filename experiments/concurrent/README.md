# Concurrent experiment

This experiment runs multiple http client/server pairs to evaluate how
contention affects the virtual testbed.

## Running an experiment

To run an experiment, several things must be set up first:

 * Create reservation(s) on using the que_host image.
 * Power cycle the nodes
 * Prep the nodes
 * Generate experiment

To create several reservations, use a for loop:

```bash
<headnode>$ for i in $(seq 16); do
    igor sub -r que$i -k /home/jcrusse/que_host.kernel -i /home/jcrusse/que_host.initrd -n 3 -t 7d
done
```

To power cycle nodes, use `tools/igor.py` (copied over to <headnode>):

```bash
<headnode>$ python igor.py --cycle que[0-9]+
```

Note that `igor.py` takes a regular expression as its argument for the
reservation names. You will have to modify the regex if you use a different
naming scheme for reservations.

To prep the nodes, we use `igor.py` to generate a script to run from our
staging node:

```bash
<headnode>$ python igor.py --prep-script que[0-9]+ > prep-all.bash
```

The `prep-all.bash` script should be copied to the staging node to
`experiments/concurrent`. The staging node should have the vendor
dependencies in the location specified by `prep.bash`.

Before running `prep-all.bash`, you should give the nodes sufficient time to
boot. After 5-10 minutes, you can use `igor.py` to check that the nodes have
booted (and that the images are correct):

```bash
<headnode>$ python igor.py --check que[0-9]+
```

```bash
<staging>$ cd experiments/concurrent/
<staging>$ scp <headnode>:prep-all.bash ./
<staging>$ bash prep-all.bash
```

To generate the experiment, modify an existing params file and then run
`sweep.bash`:

```bash
<staging>$ bash sweep.bash /path/to/output <PARAMS> > sweep.out
```

Copy the resulting file back to <headnode>. At this point the experiment should
be ready to start.

We use `parallel` to run the experiment in parallel across the reservations. To
get the list of head nodes, again use `igor.py`:

```bash
<headnode>$ python igor.py --heads que[0-9]+
```

Finally to start the experiment, run:

```bash
cat sweep.out | parallel -j1 --eta -S <HEADS>
```

You should run this command in a tmux because it may take a while depending on
the number of parameters and iterations.

## Collecting results

Once `parallel` has finished, it's time to do the final result compilation.

To collect the partial results for each parameter set:

```bash
<headnode>$ ssh <ANY HEAD> find /path/to/output -maxdepth 1 -mindepth 1 -type d | parallel -j4 --eta -S <HEADS> python /root/combine.py -f {} {}.sqlite3
<headnode>$ ssh <ANY HEAD> find /path/to/output -maxdepth 1 -mindepth 1 -name \\*.sqlite3 | parallel -j4 --eta -S <HEADS> python /root/summarize_test_results.py -s {}
<headnode>$ ssh <ANY HEAD>
<ANY HEAD>$ cd /path/to/output
<ANY HEAD>$ python /root/combine.py <OUTPUT>.sqlite3 *.sqlite3
```

or

```
cd /path/to/output
find . -maxdepth 1 -mindepth 1 -type d | parallel -j4 --eta python /root/combine.py -f {} {}.sqlite3
find . -maxdepth 1 -mindepth 1 -name \*.sqlite3 | parallel -j4 --eta python /root/summarize_test_results.py -s {}
python /root/combine.py <OUTPUT>.sqlite3 *.sqlite3
```
