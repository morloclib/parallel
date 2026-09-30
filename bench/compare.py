#!/usr/bin/env python3
"""Line up parallel benchmark results across languages.

    usage: compare.py [results/*.tsv ...]

With no arguments, reads the newest results file for each language in
bench/results/. Prints markdown: one table per case giving, for each variant
and worker count, the median time and the speedup over that language's
sequential baseline for py, cpp and rust side by side.

The baseline is the case's `seq` row, except for the stream cases: there it is
the native stage with one worker, which runs inline and is the sequential
stream loop. (The morloc `Pure` stage is a variant, not a baseline: each of its
iterations is a pool call of its own.)

A speedup is shown only when the baseline takes over 50 ms; below that (the
cheap stream case) the case measures overhead and only the times mean
anything.

Time is the labelled in-pool time when the run reported one. Otherwise (the
stream stages) it is wall time minus the median wall time of the same command
on an empty source, which removes pool start-up and file opening.
"""

import collections
import glob
import os
import statistics
import sys

LANGS = ["py", "cpp", "rust"]
HERE = os.path.dirname(os.path.abspath(__file__))


def newest_files():
    files = {}
    for path in sorted(glob.glob(os.path.join(HERE, "results", "*.tsv"))):
        lang = os.path.basename(path).rsplit("-", 1)[1][: -len(".tsv")]
        files[lang] = path
    return files


def load(path):
    rows = collections.defaultdict(list)
    calibration = {}
    with open(path) as fh:
        header = fh.readline().rstrip("\n").split("\t")
        for line in fh:
            r = dict(zip(header, line.rstrip("\n").split("\t")))
            if r["case"] == "calibration":
                calibration[r["variant"]] = int(r["checksum"])
                continue
            rows[(r["case"], r["variant"], int(r["workers"]))].append(r)
    return rows, calibration


def median_time(rows, key):
    rs = rows.get(key)
    if not rs:
        return None
    stages = [float(r["stage_s"]) for r in rs if r["stage_s"]]
    if stages:
        return statistics.median(stages)
    wall = statistics.median(float(r["wall_s"]) for r in rs)
    case, variant, workers = key
    # a variant of a command (native-arrival, native-inflight12) shares the
    # start-up of its base command's empty run
    empty = rows.get((case, variant + "-empty", workers)) or rows.get(
        (case, variant.split("-")[0] + "-empty", workers))
    if empty:
        wall -= statistics.median(float(r["wall_s"]) for r in empty)
    return wall


def checksums(rows, case):
    return {r["checksum"] for (c, v, w), rs in rows.items() if c == case and not v.endswith("-empty") for r in rs}


def main(argv):
    if argv:
        files = {os.path.basename(p).rsplit("-", 1)[1][: -len(".tsv")]: p for p in argv}
    else:
        files = newest_files()
    data = {lang: load(path) for lang, path in files.items()}
    langs = [lang for lang in LANGS if lang in data]

    print("# Parallel benchmark comparison\n")
    for lang in langs:
        print("- %s: `%s`, base %s iterations/element" % (
            lang, os.path.relpath(files[lang], HERE), data[lang][1].get("base", "?")))
    print()

    cases = []
    for lang in langs:
        for (case, _, _) in data[lang][0]:
            if case not in cases:
                cases.append(case)

    for case in cases:
        variants = []
        for lang in langs:
            for (c, v, w) in sorted(data[lang][0], key=lambda k: (k[1], k[2])):
                if c == case and not v.startswith("seq") and not v.endswith("-empty") and (v, w) not in variants:
                    variants.append((v, w))
        print("## %s\n" % case)
        print("| variant | workers | " + " | ".join("%s time (s) | %s speedup" % (l, l) for l in langs) + " |")
        print("|---|---:|" + "---:|---:|" * len(langs))
        base_key = ("native", 1) if case.startswith("stream") else ("seq", 1)
        seq = {lang: median_time(data[lang][0], (case,) + base_key) for lang in langs}
        print("| %s (baseline) | 1 | " % base_key[0] + " | ".join(
            ("%.3f | 1.00" % seq[l]) if seq[l] is not None else "- | -" for l in langs) + " |")
        for v, w in variants:
            if (v, w) == base_key:
                continue
            cells = []
            for lang in langs:
                t = median_time(data[lang][0], (case, v, w))
                if t is None:
                    cells.append("- | -")
                elif seq[lang] and seq[lang] > 0.05 and t > 0:
                    cells.append("%.3f | %.2f" % (t, seq[lang] / t))
                else:
                    cells.append("%.3f | -" % t)
            print("| %s | %d | %s |" % (v, w, " | ".join(cells)))
        disagree = [lang for lang in langs if len(checksums(data[lang][0], case)) > 1]
        if disagree:
            print("\nChecksums disagree within a run for: %s" % ", ".join(disagree))
        print()


if __name__ == "__main__":
    main(sys.argv[1:])
