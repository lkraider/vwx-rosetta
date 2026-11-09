"""Map a path stored in the ledger or a run record onto the store root of this checkout.

Usage: store_path.py ROOT PATH

Records written before the store moved to its own repository hold absolute paths under OLD_ROOT.
Records written since hold paths relative to the store root. The stored values stay as written,
so every reader passes them through resolve().
"""
import hashlib
import os
import sys

OLD_ROOT = "/Volumes/volxxxx/Projects/rosetta"


def resolve(path, root):
    """Return PATH as a path under ROOT when it is relative or under OLD_ROOT, else PATH."""
    if not path or not isinstance(path, str):
        return path
    if path.startswith(OLD_ROOT + "/"):
        return os.path.join(root, path[len(OLD_ROOT) + 1:])
    if not os.path.isabs(path):
        return os.path.join(root, path)
    return path


_digests = {}
_aliases = {}


def current_digest(digest, root):
    """Return the sha256 that ledger/anonymized.tsv gives the bytes that once hashed to DIGEST.

    Run records and the corpus ledger keep the digest they were written with.
    """
    if root not in _aliases:
        table = {}
        ledger = os.path.join(root, "ledger", "anonymized.tsv")
        if os.path.isfile(ledger):
            with open(ledger, encoding="utf-8") as f:
                for line in f.read().splitlines()[1:]:
                    cols = line.split("\t")
                    table[cols[1]] = cols[2]
        _aliases[root] = table
    seen = set()
    while digest in _aliases[root] and digest not in seen:
        seen.add(digest)
        digest = _aliases[root][digest]
    return digest


def find_source(path, digest, root):
    """Return the recorded source PATH under ROOT, or the file under ROOT/sources with DIGEST.

    Most recorded sources sit in a work directory that a clone does not carry. The store holds
    the same bytes under sources/, and sources/superseded/ holds the older bytes of repaired
    fixtures. A source found nowhere returns its resolved path, so the reader reports it gone.
    """
    resolved = resolve(path, root)
    if not resolved or os.path.isfile(resolved) or not digest:
        return resolved
    if root not in _digests:
        found = {}
        for dirpath, _dirs, names in os.walk(os.path.join(root, "sources")):
            for name in sorted(names):
                if name.endswith(".vwx"):
                    full = os.path.join(dirpath, name)
                    h = hashlib.sha256()
                    with open(full, "rb") as f:
                        for chunk in iter(lambda: f.read(1 << 20), b""):
                            h.update(chunk)
                    found.setdefault(h.hexdigest(), full)
        _digests[root] = found
    return _digests[root].get(current_digest(digest, root), resolved)


def relative(path, root):
    """Return PATH relative to ROOT when it lies under ROOT, else PATH."""
    rel = os.path.relpath(os.path.abspath(path), os.path.abspath(root))
    return path if rel == os.pardir or rel.startswith(os.pardir + os.sep) else rel


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__.split("\n\n")[1])
    print(resolve(sys.argv[2], sys.argv[1]))
