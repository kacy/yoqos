#!/bin/sh
# builds yos's live iso: arch's releng profile, the one arch's own iso
# comes from, with yos in it and the tools `yos install` runs.
# usage: dist/iso/build.sh <path to yos> <output directory>
set -eu

yos=$1
out=$2
work=$(mktemp -d)
profile=$work/profile
cp -r /usr/share/archiso/configs/releng "$profile"
sed -i -e 's/^iso_name=.*/iso_name="yos"/' \
    -e 's|^iso_publisher=.*|iso_publisher="yos"|' \
    -e 's|^iso_application=.*|iso_application="yos live medium"|' \
    "$profile/profiledef.sh"
# the boot menu names yos, and the shell greets with what to do next.
grep -rl 'Arch Linux install medium' "$profile" | xargs -r sed -i 's/Arch Linux install medium/yos live medium/'
cp "$(dirname "$0")/motd" "$profile/airootfs/etc/motd"
# yos itself, runnable by everyone.
install -Dm755 "$yos" "$profile/airootfs/usr/local/bin/yos"
sed -i 's|^file_permissions=(|file_permissions=(\n  ["/usr/local/bin/yos"]="0:0:755"|' "$profile/profiledef.sh"
# the profiles a config includes by path, as the package has them.
install -Dm644 -t "$profile/airootfs/usr/share/yos/profiles" "$(dirname "$0")/../profiles/"*.toml
# and its man pages, for `man yos` before there's anything to install.
# /usr/local/share/man is a link to ../man there, which the filesystem
# package owns.
"$(dirname "$0")/../man.sh" "$profile/man"
install -Dm644 "$profile/man/yos.1" "$profile/airootfs/usr/local/man/man1/yos.1"
install -Dm644 "$profile/man/yos-generations.7" "$profile/airootfs/usr/local/man/man7/yos-generations.7"
rm -r "$profile/man"
# what yos install runs. releng has most of it already; pacman skips the
# ones it has.
printf '%s\n' btrfs-progs dosfstools git grub efibootmgr cryptsetup tpm2-tss >> "$profile/packages.x86_64"
sort -u -o "$profile/packages.x86_64" "$profile/packages.x86_64"
mkarchiso -v -w "$work/work" -o "$out" "$profile"
rm -rf "$work"
