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
# the boot menu names yoq os, and the shell greets with what to do next.
grep -rl 'Arch Linux install medium' "$profile" | xargs -r sed -i 's/Arch Linux install medium/yoq os live medium/'
cp "$(dirname "$0")/motd" "$profile/airootfs/etc/motd"
# os itself, runnable by everyone.
install -Dm755 "$os" "$profile/airootfs/usr/local/bin/os"
sed -i 's|^file_permissions=(|file_permissions=(\n  ["/usr/local/bin/os"]="0:0:755"|' "$profile/profiledef.sh"
# and its man pages, for `man os` before there's anything to install.
"$(dirname "$0")/../man.sh" "$profile/man"
install -Dm644 "$profile/man/os.1" "$profile/airootfs/usr/local/share/man/man1/os.1"
install -Dm644 "$profile/man/os-generations.7" "$profile/airootfs/usr/local/share/man/man7/os-generations.7"
rm -r "$profile/man"
# what os install runs. releng has most of it already; pacman skips the
# ones it has.
printf '%s\n' btrfs-progs dosfstools git grub efibootmgr cryptsetup tpm2-tss >> "$profile/packages.x86_64"
sort -u -o "$profile/packages.x86_64" "$profile/packages.x86_64"
mkarchiso -v -w "$work/work" -o "$out" "$profile"
rm -rf "$work"
