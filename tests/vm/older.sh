#!/bin/sh
# runs in the vm, for the tests where the kernel has to change: finds an
# older arch in the arch linux archive.
#   older.sh date   the newest archive day at least a week back whose core
#                   repo has another linux than the one installed, and the
#                   same glibc and pacman, so os, built against today's,
#                   still runs there. as yyyy-mm-dd.
#   older.sh linux  the url of the newest linux package with an older
#                   upstream version than the one installed.
set -eu

archive=https://archive.archlinux.org

# the version of package $1 in the repository database $2.
version() {
    bsdtar -xOf "$2" --include "$1-[0-9]*/desc" 2>/dev/null | awk '/^%VERSION%$/ { getline; print; exit }'
}

case ${1:-} in
date)
    linux=$(pacman -Q linux | cut -d' ' -f2)
    glibc=$(pacman -Q glibc | cut -d' ' -f2)
    pacman=$(pacman -Q pacman | cut -d' ' -f2)
    db=$(mktemp)
    for back in $(seq 7 120); do
        day=$(date -u -d "$back days ago" +%Y/%m/%d)
        curl -fsL -o "$db" "$archive/repos/$day/core/os/x86_64/core.db" || continue
        if [ "$(version linux "$db")" != "$linux" ] && [ "$(version glibc "$db")" = "$glibc" ] && [ "$(version pacman "$db")" = "$pacman" ]; then
            echo "$day" | tr / -
            rm -f "$db"
            exit 0
        fi
    done
    echo "older.sh: no day in the last 120 with another linux and the same glibc and pacman" >&2
    exit 1
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
