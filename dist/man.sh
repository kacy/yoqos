#!/bin/sh
# writes yos's man pages from the docs, so there's one copy to keep up to
# date: yos(1) from docs/usage.md and yos-generations(7) from
# docs/generations.md. each page gets the NAME section man and whatis look
# for, and a SEE ALSO. needs lowdown.
# usage: dist/man.sh <dir>
set -eu

out=$1
here=$(cd "$(dirname "$0")/.." && pwd)
version=$(sed -n 's/^ *\.version = "\(.*\)",$/\1/p' "$here/build.zig.zon")
# the date of the last commit, so the same source makes the same page.
date=$(git -C "$here" log -1 --format=%cs 2>/dev/null || date -u +%F)
mkdir -p "$out"

# page <name> <section> <what it is> <doc> <see also>
page() {
    {
        printf '## NAME\n\n%s - %s\n\n## DESCRIPTION\n' "$1" "$3"
        # the doc without its own title; its ## sections become the page's.
        # links point at other files and anchors, which mean nothing in a
        # man page, so they're just their text. read whole, since a link's
        # text can wrap onto the next line.
        sed 1d "$here/$4" | sed -z 's/\[\([^]]*\)\]([^)]*)/\1/g'
        printf '\n## SEE ALSO\n\n%s\n' "$5"
    } | lowdown -s -Tman \
        -M title="$1" -M section="$2" -M date="$date" \
        -M source="yos $version" -M volume="yos manual" \
        -M shiftheadinglevelby=-1 \
        -o "$out/$1.$2"
}

page yos 1 "declarative arch linux with rollback" docs/usage.md \
    "yos-generations(7), pacman(8), systemctl(1), sbctl(8), systemd-cryptenroll(1)"
page yos-generations 7 "how yos keeps generations, trial boots, and rollback" docs/generations.md \
    "yos(1), btrfs(8), bootctl(1), grub-install(8)"
