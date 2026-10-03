#!/bin/sh
# runs in the vm, for the tests where the kernel has to change: finds an
# older arch in the arch linux archive.
#   older.sh date   an archive day at least a week back whose core repo
#                   has another linux than the one installed (and another
#                   systemd, if a day in reach has one), and the same glibc
#                   and pacman releases, so os, built against today's,
#                   still runs there. as yyyy-mm-dd.
#   older.sh linux  the url of the newest linux package with an older
#                   upstream version than the one installed.
set -eu

archive=https://archive.archlinux.org

# the version of package $1 in the repository database $2.
version() {
    bsdtar -xOf "$2" --include "$1-[0-9]*/desc" 2>/dev/null | awk '/^%VERSION%$/ { getline; print; exit }'
}

# a package version without arch's part: 2.44 from 2.44+r24+g16be15-1.
upstream() {
    echo "${1%%[+-]*}"
}

case ${1:-} in
date)
    linux=$(pacman -Q linux | cut -d' ' -f2)
    systemd=$(pacman -Q systemd | cut -d' ' -f2)
    glibc=$(upstream "$(pacman -Q glibc | cut -d' ' -f2)")
    pacman=$(upstream "$(pacman -Q pacman | cut -d' ' -f2)")
    db=$(mktemp)
    # a day with another systemd too, if one in reach has it, so the
    # update forward brings both.
    found=
    for back in $(seq 7 60); do
        day=$(date -u -d "$back days ago" +%Y/%m/%d)
        curl -fsL -o "$db" "$archive/repos/$day/core/os/x86_64/core.db" || continue
        [ "$(version linux "$db")" != "$linux" ] || continue
        [ "$(upstream "$(version glibc "$db")")" = "$glibc" ] || continue
        [ "$(upstream "$(version pacman "$db")")" = "$pacman" ] || continue
        [ -n "$found" ] || found=$day
        if [ "$(version systemd "$db")" != "$systemd" ]; then
            found=$day
            break
        fi
    done
    rm -f "$db"
    [ -n "$found" ] || { echo "older.sh: no day in the last 60 with another linux and the same glibc and pacman ($glibc, $pacman)" >&2; exit 1; }
    echo "$found" | tr / -
    ;;
linux)
    now=$(pacman -Q linux | cut -d' ' -f2)
    curl -fsL "$archive/packages/l/linux/" |
        grep -o 'linux-[0-9][^"<>]*-x86_64\.pkg\.tar\.zst' | sort -urV |
        while read -r file; do
            v=${file#linux-}
            v=${v%-x86_64.pkg.tar.zst}
            if [ "${v%%.arch*}" != "${now%%.arch*}" ] && [ "$(vercmp "$v" "$now")" -lt 0 ]; then
                echo "$archive/packages/l/linux/$file"
                exit 0
            fi
        done
    ;;
*)
    echo "usage: older.sh date|linux" >&2
    exit 2
    ;;
esac
