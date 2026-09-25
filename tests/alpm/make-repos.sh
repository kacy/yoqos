#!/bin/sh
# builds the sync databases the alpm tests resolve against. packages are
# tiny: a .PKGINFO and one doc file each. run from the repo root; the
# resulting core.db and extra.db are committed, the packages aren't.
set -eu

out=tests/alpm/repos
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
rm -rf "$out"
mkdir -p "$out"

# pkg <repo> <name> <version> [depend=x provides=y conflicts=z ...]
pkg() {
    repo=$1 name=$2 ver=$3
    shift 3
    dir=$work/$name
    mkdir -p "$dir/usr/share/doc/$name"
    echo "$name $ver" > "$dir/usr/share/doc/$name/README"
    {
        echo "pkgname = $name"
        echo "pkgbase = $name"
        echo "pkgver = $ver"
        echo "pkgdesc = test package $name"
        echo "builddate = 1790000000"
        echo "packager = yoq os tests"
        echo "size = 64"
        echo "arch = x86_64"
        echo "license = MIT"
        for kv in "$@"; do
            echo "${kv%%=*} = ${kv#*=}"
        done
    } > "$dir/.PKGINFO"
    file=$work/$repo/$name-$ver-x86_64.pkg.tar.gz
    mkdir -p "$work/$repo"
    (cd "$dir" && bsdtar -czf "$file" --uid 0 --gid 0 --options gzip:!timestamp .PKGINFO usr)
}

pkg core filesystem 2025.05.03-1
pkg core glibc 2.42-1 depend=filesystem
pkg core bash 5.3.3-2 depend=glibc depend=readline provides=sh
pkg core readline 8.3.001-1 depend=glibc
pkg core openssl 3.5.3-1 depend=glibc
pkg core curl 8.16.0-1 depend=glibc depend=openssl
pkg core perl 5.42.0-1 depend=glibc
pkg core linux 6.16.8.arch1-1 depend=mkinitcpio
pkg core mkinitcpio 40-2 depend=bash depend=sh
pkg core openssh 10.0p1-4 depend=openssl "depend=glibc>=2.40"
pkg extra git 2.51.0-1 depend=curl depend=perl-error "depend=glibc>=2.26"
pkg extra perl-error 0.17030-2 depend=perl
pkg extra neovim 0.11.4-1 depend=luajit depend=libuv
pkg extra luajit 2.1.1753364724-1 depend=glibc
pkg extra libuv 1.51.0-1 depend=glibc
pkg extra jre-openjdk 24.0.2-1 provides=java-runtime=24 depend=glibc
pkg extra jre17-openjdk 17.0.16-1 provides=java-runtime=17 depend=glibc
pkg extra jdk-tool 1.0-1 depend=java-runtime
pkg extra broken 1.0-1 depend=no-such-package
pkg extra vim 9.1-1 depend=glibc conflict=neovim

for repo in core extra; do
    repo-add -q "$work/$repo/$repo.db.tar.gz" "$work/$repo"/*.pkg.tar.gz
    cp "$work/$repo/$repo.db.tar.gz" "$out/$repo.db"
done
ls -l "$out"
