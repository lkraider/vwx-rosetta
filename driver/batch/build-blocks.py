#!/usr/bin/env python3
"""Split a stage plan into block plans of about 2 h each, in the row order of the plan.

Usage: build-blocks.py [PLAN.tsv]

The default plan is driver/batch/stage2.tsv. Block N goes to driver/batch/<plan>-blockN.tsv.
Stage 1 measured 86.5 s for one DXF pair and 79.4 s for one DWG pair, with the check and the install,
so each block holds at most 7200 // 87 = 82 pairs.
A row with more cases than the block has room for continues in the next block with its other cases.
Run it again after each change to the plan. StagePlans in driver/tests/test_batch.py compares the files.
"""
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
PLAN = os.path.join(ROOT, "driver", "batch", "stage2.tsv")
BLOCK_SECONDS = 7200
PAIR_SECONDS = 87


def blocks(lines):
    room = BLOCK_SECONDS // PAIR_SECONDS
    out, current, used = [], [], 0
    for line in lines:
        cols = line.rstrip("\n").split("\t")
        cases = cols[4].split(",")
        while cases:
            if used == room:
                out.append(current)
                current, used = [], 0
            take, cases = cases[:room - used], cases[room - used:]
            current.append("\t".join(cols[:4] + [",".join(take)] + cols[5:]) + "\n")
            used += len(take)
    if current:
        out.append(current)
    return out


def main(argv):
    if len(argv) > 1:
        raise SystemExit(__doc__)
    plan = argv[0] if argv else PLAN
    with open(plan) as f:
        lines = f.readlines()
    head = lines[0]
    body = [l for l in lines[1:] if l.strip() and not l.startswith("#")]
    stem = plan[:-len(".tsv")]
    for n, block in enumerate(blocks(body), 1):
        with open("%s-block%d.tsv" % (stem, n), "w") as f:
            f.write(head + "".join(block))
        print("%s-block%d.tsv: %d pairs" % (os.path.basename(stem), n,
                                            sum(len(l.split("\t")[4].split(",")) for l in block)))


if __name__ == "__main__":
    main(sys.argv[1:])
