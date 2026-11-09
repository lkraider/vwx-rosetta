#!/bin/sh
# Build driver/bin/vwx from driver/native and compare its SHA-256 with driver/bin/BUILD.tsv.
#
#     sh driver/native/build.sh           build, run the tests, install when the digest matches BUILD.tsv
#     sh driver/native/build.sh --record  write the digest into BUILD.tsv, then install
#
# The Zig caches go under $ROSETTA_TMP/zig. ROSETTA_TMP defaults to the run-all.sh scratch root.
# Exit 0 when the tests pass and the digest matches BUILD.tsv, 1 when either fails, 2 on usage.
set -eu

STORE=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
RECORD=0
case "${1:-}" in
    "") ;;
    --record) RECORD=1 ;;
    *) printf 'usage: build.sh [--record]\n' >&2; exit 2 ;;
esac

ROSETTA_TMP=${ROSETTA_TMP:-${ROSETTA_VOLUME:-/Volumes/volxxxx}/Caches/tmp/rosetta-run-$(date +%Y%m%d)}
case "$ROSETTA_TMP/" in
    /*) ;;
    *) printf 'ROSETTA_TMP must be an absolute path: %s\n' "$ROSETTA_TMP" >&2; exit 2 ;;
esac
case "$ROSETTA_TMP/" in
    "$STORE"/*) printf 'ROSETTA_TMP is inside the store: %s\n' "$ROSETTA_TMP" >&2; exit 2 ;;
esac

ZIG_CACHE=$ROSETTA_TMP/zig
mkdir -p "$ZIG_CACHE" "$STORE/driver/bin"
cd "$STORE/driver/native"
COMMAND="zig build -Dvolume=\${ROSETTA_VOLUME:-/Volumes/volxxxx} --cache-dir \$ROSETTA_TMP/zig/cache --global-cache-dir \$ROSETTA_TMP/zig/global --prefix \$ROSETTA_TMP/zig/out"
zig build -Dvolume="${ROSETTA_VOLUME:-/Volumes/volxxxx}" --cache-dir "$ZIG_CACHE/cache" --global-cache-dir "$ZIG_CACHE/global" --prefix "$ZIG_CACHE/out"
TEST_LOG=$ZIG_CACHE/test.log
if ! zig build test -Dvolume="${ROSETTA_VOLUME:-/Volumes/volxxxx}" --cache-dir "$ZIG_CACHE/cache" --global-cache-dir "$ZIG_CACHE/global" --prefix "$ZIG_CACHE/out" --summary all > "$TEST_LOG" 2>&1; then
    cat "$TEST_LOG" >&2
    printf 'zig build test failed. driver/bin/vwx is unchanged.\n' >&2
    exit 1
fi
grep 'Build Summary' "$TEST_LOG"
BUILT=$ZIG_CACHE/out/bin/vwx

SHA=$(shasum -a 256 "$BUILT" | cut -d' ' -f1)
BYTES=$(wc -c < "$BUILT" | tr -d ' ')
ZIG=$(zig version)
TSV=$STORE/driver/bin/BUILD.tsv
if [ "$RECORD" = 1 ]; then
    printf 'binary\tsha256\tbytes\tzig\tos\tarch\tcommand\n' > "$TSV"
    printf 'driver/bin/vwx\t%s\t%s\t%s\t%s\t%s\t%s\n' "$SHA" "$BYTES" "$ZIG" "$(uname -s)" "$(uname -m)" "$COMMAND" >> "$TSV"
fi
WANT=$(awk -F '\t' '$1 == "driver/bin/vwx" { print $2 }' "$TSV")
printf 'built vwx sha256 %s, %s bytes, zig %s\n' "$SHA" "$BYTES" "$ZIG"
if [ "$SHA" != "$WANT" ]; then
    printf 'BUILD.tsv records %s. driver/bin/vwx is unchanged.\n' "$WANT" >&2
    exit 1
fi
cp "$BUILT" "$STORE/driver/bin/vwx"
