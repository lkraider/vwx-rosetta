#!/bin/sh
# The deletion policy of this repository, in one file.
#
#     . tools/discard.sh
#     discard <path>...      move each path into the trash, then delete it from there
#     trash_path <name>      print a scratch path under the trash, for a script's own use
#     trash_expire           delete what this process put in the trash
#     trash_purge            delete what dead processes left in the trash
#     sh tools/discard.sh purge
#
# A recursive delete only ever runs on a path that discard.sh composes itself: a fixed trash root
# plus a pid. A path that a caller passes in reaches only `mv`. `discard` then deletes the run
# directory that holds it, so a wrong caller path loses that tree.
#
# `discard` deletes its run directory before it returns. A tree that `discard` moved is gone when the
# call returns. `refused_path` refuses `/`, `.`, `..`, `$HOME`, each trash root, each folder above a
# root and each path inside a root.
#
# The trash roots are /Volumes/volxxxx/Caches/tmp/vwx-export/vwx-trash and /tmp/vwx-trash. `discard`
# takes, for each path, the first root on the device of that path's parent folder, so `mv` is a
# rename on one device. A path on a device with no root is refused and stays where it is. A move
# across devices copies the whole tree before the delete. A move from the external volume into /tmp filled the
# internal disk that way.
#
# The trash root is used only when the folder that holds it exists. A missing external volume therefore
# makes no folder under /Volumes.
#
# What this replaced, and why it had to go. `tools/vwtest.sh` ran `rm -rf "$VW_RUN"`, where `VW_RUN`
# came from the environment with a default of /tmp/vwtest-run. Nothing checked the path before it was
# removed, so the script deleted whatever the variable named. A reviewer raised it as blocking and
# the author reproduced it:
#
#     T=/tmp/iu-rmtest; mkdir -p $T; printf x > $T/doc.vwx; printf keep > $T/unrelated-work.txt
#     VW_RUN=$T tools/vwtest.sh run $T/doc.vwx
#     #   cp: /tmp/iu-rmtest/doc.vwx: No such file or directory
#     # exit 1, and $T was empty
#
# Both files were the test's own - one byte and four bytes, made seconds earlier in a scratch
# directory - so nothing real was lost, and this line must not be read as a document having been
# destroyed. The finding is the shape: the script deleted a path it had not created, on the strength
# of a variable, and a variable that named a directory holding real documents would have taken
# those. The same shape was then found in 32 more places, across 29 files.
#
# The rules, stated so a reviewer can hold the code to them:
#
#   1. No `rm -rf` anywhere in this repository. `tools/no-rm-rf.sh` fails the build if one appears.
#   2. A caller never supplies a deletion path. `discard` takes a path to MOVE; the deletion that
#      follows is on a path composed in this file.
#   3. Anything to be removed is renamed into a trash root on its own device first. The recursive
#      delete then runs on the run directory of that root.
#   4. A script's own scratch is made with `trash_path` or under `mktemp -d`, never at a path that
#      came from the environment. `VW_TEST`, `VW_RUN` and their relatives are how the wrong thing
#      got deleted, and the answer is not a better guard on the delete - it is that there is no
#      deletion on that path at all.
#   5. `trash_expire` and `trash_purge` delete only under the roots in `_vwx_roots`, at a name made of
#      digits.

# One root per line, in order of preference. This file sets the list each time it is sourced, so the
# environment cannot add a root. The selftest replaces it in a subshell with mktemp roots, whose
# paths may hold a space.
_vwx_roots="/Volumes/volxxxx/Caches/tmp/vwx-export/vwx-trash
/tmp/vwx-trash"

# The device of the nearest folder that exists at or above $1.
_vwx_dev() {
    _vwx_d=$1
    while [ ! -d "$_vwx_d" ]; do _vwx_d=$(dirname -- "$_vwx_d"); done
    stat -L -f %d -- "$_vwx_d"
}

# $1 with each folder that exists resolved by `pwd -P`. The part below the deepest existing folder
# stays as written.
_vwx_phys() {
    _vwx_p=$1
    _vwx_rest=
    while [ ! -d "$_vwx_p" ]; do
        _vwx_rest=/${_vwx_p##*/}$_vwx_rest
        _vwx_p=$(dirname -- "$_vwx_p")
    done
    _vwx_p=$(CDPATH= cd -P -- "$_vwx_p" && pwd -P) || return 1
    case "$_vwx_p" in /) _vwx_p= ;; esac
    printf '%s%s\n' "$_vwx_p" "${_vwx_rest:-/}"
}

# Print the run directory of this process on the device of $1's parent folder, and make it.
_vwx_run_for() {
    _vwx_want=$(_vwx_dev "$(dirname -- "$1")") || return 1
    while IFS= read -r _vwx_root; do
        [ -n "$_vwx_root" ] && [ -d "${_vwx_root%/*}" ] || continue
        [ "$(_vwx_dev "$_vwx_root")" = "$_vwx_want" ] || continue
        mkdir -p "$_vwx_root/$$" 2>/dev/null || continue
        [ "$(stat -L -f %d -- "$_vwx_root/$$")" = "$_vwx_want" ] || continue
        printf '%s\n' "$_vwx_root/$$"
        return 0
    done <<EOF
$_vwx_roots
EOF
    return 1
}

# Whether $1 sits on another device than its parent folder. A mount point moves as a copy of the
# whole volume, and the expiry then deletes that copy.
_vwx_mount_point() {
    [ "$(stat -f %d -- "$1")" != "$(_vwx_dev "$(dirname -- "$1")")" ]
}

# Rename $1 into the trash and print where it went. The selftest calls this to inspect the move
# before the expiry.
_vwx_move() {
    _vwx_src=$1
    # `mv / tmp` would fail, but `mv ~ tmp` would succeed and then be expired. See `refused_path`.
    if refused_path "$_vwx_src"; then
        printf 'discard: refusing to move %s\n' "$_vwx_src" >&2
        return 1
    fi
    [ -e "$_vwx_src" ] || [ -L "$_vwx_src" ] || return 0
    if _vwx_mount_point "$_vwx_src"; then
        printf 'discard: refusing to move %s, a mount point\n' "$_vwx_src" >&2
        return 1
    fi
    _vwx_run=$(_vwx_run_for "$_vwx_src") || {
        printf 'discard: no trash root on the device of %s; it is unchanged\n' "$_vwx_src" >&2
        return 1
    }
    # A name that already exists in the trash gets a suffix, so two callers cannot collide.
    _vwx_dst=$_vwx_run/$(basename -- "$_vwx_src")
    _vwx_n=1
    while [ -e "$_vwx_dst" ]; do
        _vwx_dst=$_vwx_run/$(basename -- "$_vwx_src").$_vwx_n
        _vwx_n=$((_vwx_n + 1))
    done
    mv -- "$_vwx_src" "$_vwx_dst" 2>/dev/null || {
        printf 'discard: could not move %s into the trash; it is unchanged\n' "$_vwx_src" >&2
        return 1
    }
    printf '%s\n' "$_vwx_dst"
}

# Move each argument into the trash, then delete the run directory. An argument that cannot be moved
# stays where it is and is reported.
discard() {
    for _vwx_arg in "$@"; do
        [ -n "$_vwx_arg" ] || continue
        _vwx_move "$_vwx_arg" >/dev/null || true
    done
    trash_expire
}

# A scratch path owned by this process. Use it instead of inventing a path, so that expiry is
# automatic and the name is never one a caller chose.
trash_path() {
    _vwx_name=${1:-scratch}
    while IFS= read -r _vwx_root; do
        [ -n "$_vwx_root" ] && [ -d "${_vwx_root%/*}" ] || continue
        mkdir -p "$_vwx_root/$$" 2>/dev/null || continue
        printf '%s\n' "$_vwx_root/$$/$_vwx_name"
        return 0
    done <<EOF
$_vwx_roots
EOF
    return 1
}

# Delete the run directory of this process in each root. The path is a root from `_vwx_roots` plus
# this shell's pid.
trash_expire() {
    case "$$" in ''|*[!0-9]*) return 1 ;; esac
    while IFS= read -r _vwx_root; do
        [ -n "$_vwx_root" ] && [ -d "$_vwx_root/$$" ] || continue
        # `find -delete` removes the contents depth-first and does not follow symlinks, so a link
        # inside the trash is removed as a link and never as the tree it points at.
        find "$_vwx_root/$$" -depth -delete 2>/dev/null || true
        rmdir "$_vwx_root/$$" 2>/dev/null || true
        rmdir "$_vwx_root" 2>/dev/null || true
    done <<EOF
$_vwx_roots
EOF
    return 0
}

# Delete each run directory in a literal trash root whose name is a pid with no live process. A
# process that was killed or interrupted never ran its own `trash_expire`, and its run directory stays.
# The glob only lists names. The path handed to `find` is the literal root plus a name made of digits
# alone. `ps -p` sees processes of every user, so a live pid of another user is kept.
trash_purge() {
    _vwx_purge_rc=0
    while IFS= read -r _vwx_root; do
        [ -d "$_vwx_root" ] || continue
        for _vwx_entry in "$_vwx_root"/*; do
            _vwx_pid=${_vwx_entry##*/}
            case "$_vwx_pid" in
                ''|*[!0-9]*) continue ;;
            esac
            [ -d "$_vwx_root/$_vwx_pid" ] || continue
            if ps -p "$_vwx_pid" > /dev/null 2>&1; then
                printf 'trash_purge: kept %s, pid %s is running\n' "$_vwx_root/$_vwx_pid" "$_vwx_pid"
                continue
            fi
            _vwx_kb=$(du -sk "$_vwx_root/$_vwx_pid" 2>/dev/null | awk '{ print $1 }')
            find "$_vwx_root/$_vwx_pid" -depth -delete 2>/dev/null || true
            rmdir "$_vwx_root/$_vwx_pid" 2>/dev/null || true
            if [ -e "$_vwx_root/$_vwx_pid" ]; then
                printf 'trash_purge: could not remove all of %s\n' "$_vwx_root/$_vwx_pid" >&2
                _vwx_purge_rc=1
            else
                printf 'trash_purge: removed %s, %s KB\n' "$_vwx_root/$_vwx_pid" "${_vwx_kb:-0}"
            fi
        done
        rmdir "$_vwx_root" 2>/dev/null || true
    done <<EOF
$_vwx_roots
EOF
    return "$_vwx_purge_rc"
}

# The decision, on its own, as a function of one argument. It only classifies - it does not move and
# it does not delete - and that is what makes it testable. It refuses `/`, `.`, `..`, `$HOME`, each
# trash root, each path inside a root, and each folder that holds `$HOME` or a root. It compares the
# path as written and the path with its existing folders resolved, so `/private/tmp` and `/tmp/` are
# refused as `/tmp` is.
#
# This split exists because of a mistake made while testing this file. The guard was checked by
# calling `discard` on the real `$HOME` and on `/`, and it refused, and that was luck: a guard on a
# move is wrong exactly when the test is most convincing, and here being wrong would have moved a
# home directory into the trash and expired it. A decision is safe to test on anything. An action
# is only safe to test on something the test owns.
refused_path() {
    _vwx_a=${1:-}
    while :; do
        case "$_vwx_a" in ?*/) _vwx_a=${_vwx_a%/} ;; *) break ;; esac
    done
    case "$_vwx_a" in ""|/|.|..|"${HOME:-}") return 0 ;; esac
    _vwx_ap=$(_vwx_phys "$_vwx_a") || return 0
    case "$_vwx_ap" in /) return 0 ;; esac
    while IFS= read -r _vwx_r; do
        [ -n "$_vwx_r" ] || continue
        _vwx_rp=$(_vwx_phys "$_vwx_r") || return 0
        for _vwx_x in "$_vwx_a" "$_vwx_ap"; do
            for _vwx_y in "$_vwx_r" "$_vwx_rp"; do
                case "$_vwx_y/" in "$_vwx_x"/*) return 0 ;; esac
                [ "$_vwx_y" = "${HOME:-}" ] && continue
                case "$_vwx_x" in "$_vwx_y"/*) return 0 ;; esac
            done
        done
    done <<EOF
${HOME:-}
$_vwx_roots
EOF
    return 1
}

# The move, tested only on paths this file created. Every tree it discards here is made by
# `trash_path` or by `mktemp -d`, so a `discard` that went wrong could only lose something the test
# made seconds earlier. The one refusal exercised through `discard` uses a HOME the test owns, and
# the real HOME is never an argument to anything but the classifier.
selftest() {
    _st_fail=0
    _st_case() {    # name, wanted (0 refuse / 1 allow), path
        refused_path "$3"
        _st_got=$?
        if [ "$_st_got" = "$2" ]; then
            printf 'discard selftest: ok   %-24s %s\n' "$1" "$3"
        else
            printf 'discard selftest: FAIL %-24s %s gave %s, wanted %s\n' "$1" "$3" "$_st_got" "$2"
            _st_fail=1
        fi
    }
    _st_case 'refuse /'            0 /
    _st_case 'refuse .'            0 .
    _st_case 'refuse ..'           0 ..
    _st_case 'refuse HOME'         0 "${HOME:-}"
    _st_case 'refuse above HOME'   0 "$(dirname -- "${HOME:-/x}")"
    _st_case 'refuse nothing'      0 ''
    while IFS= read -r _st_root; do
        _st_case 'refuse a root'       0 "$_st_root"
        _st_case 'refuse a root/'      0 "$_st_root/"
        _st_case 'refuse a run dir'    0 "$_st_root/$$"
        _st_up=$(dirname -- "$_st_root")
        while [ "$_st_up" != / ]; do
            _st_case 'refuse above a root' 0 "$_st_up"
            _st_up=$(dirname -- "$_st_up")
        done
    done <<EOF
$_vwx_roots
EOF
    _st_case 'refuse /private/tmp' 0 /private/tmp
    _st_case 'refuse a real root'  0 /private/tmp/vwx-trash
    _st_case 'allow a /tmp path'   1 /tmp/some-scratch
    _st_case 'allow beside a root' 1 /Volumes/volxxxx/Caches/tmp/vwx-export/other
    _st_case 'allow a relative'    1 some/relative/name
    if _vwx_mount_point /dev && ! _vwx_mount_point "${TMPDIR:-/tmp}"; then
        printf 'discard selftest: ok   %-24s %s\n' 'finds a mount point' /dev
    else
        printf 'discard selftest: FAIL /dev is not found as a mount point, or TMPDIR is\n'
        _st_fail=1
    fi

    # It moves what it is given, and it takes the trash root away behind it. The victim is NOT made
    # with `trash_path`: a path inside the trash is refused, because it is already in the trash and
    # will expire on its own, so a victim there would prove nothing about the move. The first version
    # of this test did exactly that and passed - the victim was gone, but expiry had removed it and
    # the move had never run.
    # The move and the expiry are checked apart. A rename keeps the inode, and a copy across devices
    # makes a new one.
    _st_victim=$(mktemp -d "${TMPDIR:-/tmp}/vwx-selftest-victim.XXXXXX")
    mkdir -p "$_st_victim/inner" && : > "$_st_victim/inner/f"
    _st_ino=$(stat -f %i -- "$_st_victim")
    _st_dst=$(_vwx_move "$_st_victim")
    if [ ! -e "$_st_victim" ] && [ -n "$_st_dst" ] && [ "$(stat -f %i -- "$_st_dst" 2>/dev/null)" = "$_st_ino" ]; then
        printf 'discard selftest: ok   %-24s %s\n' 'renames a tree it owns' "$_st_dst"
    else
        printf 'discard selftest: FAIL the tree it made was not renamed into the trash: %s\n' "$_st_dst"
        _st_fail=1
    fi
    trash_expire
    if [ -n "$_st_dst" ] && [ ! -e "$_st_dst" ]; then
        printf 'discard selftest: ok   %-24s %s\n' 'expires the run dir' "$_st_dst"
    else
        printf 'discard selftest: FAIL expiry left %s\n' "$_st_dst"
        _st_fail=1
    fi

    # A path inside the trash is refused rather than moved, which is why the victim above is not one.
    # Its existence cannot be asserted afterwards: `discard` expires its own run directory on the way
    # out, so that path is gone either way. The refusal is read from the message instead, which is
    # the part that is actually being tested.
    _st_inside=$(trash_path inside)
    mkdir -p "$_st_inside"
    if discard "$_st_inside" 2>&1 | grep -q 'refusing to move'; then
        printf 'discard selftest: ok   %-24s %s\n' 'refuses inside the trash' "$_st_inside"
    else
        printf 'discard selftest: FAIL a path inside the trash was not refused\n'
        _st_fail=1
    fi
    trash_expire

    # A refused path, through `discard`, with a HOME this test made. Never the real HOME. The
    # subshell gets a trash root of its own because `$$` is the same in a subshell, so sharing one
    # would let the child expire the parent's scratch.
    _st_fake=$(mktemp -d "${TMPDIR:-/tmp}/vwx-selftest-home.XXXXXX")
    ( HOME=$_st_fake; _vwx_roots=$_st_fake.trash; discard "$_st_fake" ) >/dev/null 2>&1 || true
    if [ -d "$_st_fake" ]; then
        printf 'discard selftest: ok   %-24s %s\n' 'leaves a refused path' "$_st_fake"
    else
        printf 'discard selftest: FAIL a refused path was moved\n'
        _st_fail=1
    fi
    discard "$_st_fake"

    # A trash root on the device of the source that cannot be made: a file stands where its folder
    # would be. The path must survive.
    _st_keep=$(mktemp -d "${TMPDIR:-/tmp}/vwx-selftest-keep.XXXXXX")
    : > "$_st_keep.file"
    ( _vwx_roots=$_st_keep.file/trash; discard "$_st_keep" ) >/dev/null 2>&1 || true
    if [ -d "$_st_keep" ]; then
        printf 'discard selftest: ok   %-24s %s\n' 'unreachable trash' "$_st_keep"
    else
        printf 'discard selftest: FAIL a path went with nowhere to put it\n'
        _st_fail=1
    fi

    # The only root is on another device: devfs. The device test refuses before any folder is made.
    _st_msg=$( ( _vwx_roots=/dev/vwx-selftest-trash; discard "$_st_keep" ) 2>&1 )
    if [ -d "$_st_keep" ] && [ ! -e /dev/vwx-selftest-trash ]; then
        case "$_st_msg" in
            *'no trash root on the device'*)
                printf 'discard selftest: ok   %-24s %s\n' 'refuses another device' "$_st_keep" ;;
            *)  printf 'discard selftest: FAIL another device gave: %s\n' "$_st_msg"; _st_fail=1 ;;
        esac
    else
        printf 'discard selftest: FAIL a path moved to another device\n'
        _st_fail=1
    fi
    discard "$_st_keep" "$_st_keep.file"

    # `trash_purge` removes a run directory whose pid has exited and keeps one whose pid is alive. It
    # runs on a mktemp root, so the real trash keeps its run directories. The dead pid is that of a
    # shell that has just exited. The OS could reuse it at once, and then the directory is kept and this
    # case fails.
    _st_purge=$(mktemp -d "${TMPDIR:-/tmp}/vwx-selftest-purge.XXXXXX")
    _st_dead=$(sh -c 'echo $$')
    mkdir -p "$_st_purge/$_st_dead/inner" && : > "$_st_purge/$_st_dead/inner/f"
    mkdir -p "$_st_purge/$$"
    ( _vwx_roots=$_st_purge; trash_purge ) | sed 's/^/discard selftest: /'
    if [ ! -e "$_st_purge/$_st_dead" ] && [ -d "$_st_purge/$$" ]; then
        printf 'discard selftest: ok   %-24s %s\n' 'purge takes a dead run' "$_st_purge/$_st_dead"
    else
        printf 'discard selftest: FAIL purge left %s or took %s\n' "$_st_purge/$_st_dead" "$_st_purge/$$"
        _st_fail=1
    fi
    discard "$_st_purge"

    # The real HOME is checked, not assumed: the whole point of the split above is that nothing in
    # this test ever handed it to a function that moves.
    if [ -d "${HOME:-/}" ]; then
        printf 'discard selftest: ok   %-24s %s\n' 'the real HOME is untouched' "${HOME:-}"
    else
        printf 'discard selftest: FAIL the real HOME is gone\n'
        _st_fail=1
    fi

    if [ "$_st_fail" = 0 ]; then printf 'discard selftest: PASS\n'; else printf 'discard selftest: FAIL\n'; fi
    return "$_st_fail"
}

# Executed as a program, `selftest` checks the classifier and the move. Sourcing this file never
# runs it: when a file is sourced, `$0` is the caller's name, and when it is executed it is this
# file's. A caller's own `$1` therefore cannot start a selftest by accident.
case "${0##*/}" in
    discard.sh)
        case "${1:-}" in
            selftest)
                _vwx_tmp_sh=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/vwx-tmp.sh
                if [ -f "$_vwx_tmp_sh" ]; then . "$_vwx_tmp_sh"; fi
                selftest; exit $? ;;
            purge) trash_purge; exit $? ;;
            '') ;;
            *) printf 'usage: %s selftest|purge\n' "$0" >&2; exit 2 ;;
        esac
        ;;
esac
