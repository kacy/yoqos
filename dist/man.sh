#!/bin/sh
# writes os's man pages from the docs, so there's one copy to keep up to
# date: os(1) from docs/usage.md and os-generations(7) from
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
        # man page, so they're just their text.
        sed -e 1d -e 's/\[\([^]]*\)\]([^)]*)/\1/g' "$here/$4"
        printf '\n## SEE ALSO\n\n%s\n' "$5"
    } | lowdown -s -Tman \
        -M title="$1" -M section="$2" -M date="$date" \
        -M source="yoq os $version" -M volume="yoq os manual" \
        -M shiftheadinglevelby=-1 \
        -o "$out/$1.$2"
}

page os 1 "declarative arch linux with rollback" docs/usage.md \
    "os-generations(7), pacman(8), systemctl(1), sbctl(8), systemd-cryptenroll(1)"
page os-generations 7 "how os keeps generations, trial boots, and rollback" docs/generations.md \
    "os(1), btrfs(8), bootctl(1), grub-install(8)"
