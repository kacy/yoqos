#!/bin/sh
# builds yoq os's live iso: arch's releng profile, the one arch's own iso
# comes from, with os in it and the tools `os install` runs.
# usage: dist/iso/build.sh <path to os> <output directory>
set -eu

os=$1
out=$2
work=$(mktemp -d)
profile=$work/profile
cp -r /usr/share/archiso/configs/releng "$profile"
sed -i -e 's/^iso_name=.*/iso_name="yoq-os"/' \
    -e 's|^iso_publisher=.*|iso_publisher="yoq os"|' \
    -e 's|^iso_application=.*|iso_application="yoq os live medium"|' \
    "$profile/profiledef.sh"
# os itself, runnable by everyone.
install -Dm755 "$os" "$profile/airootfs/usr/local/bin/os"
sed -i 's|^file_permissions=(|file_permissions=(\n  ["/usr/local/bin/os"]="0:0:755"|' "$profile/profiledef.sh"
# what os install runs. releng has most of it already; pacman skips the
# ones it has.
printf '%s\n' btrfs-progs dosfstools git grub efibootmgr >> "$profile/packages.x86_64"
sort -u -o "$profile/packages.x86_64" "$profile/packages.x86_64"
mkarchiso -v -w "$work/work" -o "$out" "$profile"
rm -rf "$work"
