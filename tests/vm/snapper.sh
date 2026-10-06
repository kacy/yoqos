#!/bin/sh
# a machine running the root snapper's rollback made: the default
# subvolume is a snapshot, and neither the kernel's command line nor fstab
# names a subvolume, so the default is what boots. runs before rollback.sh.
set -eu
. tests/vm/lib.sh

# snapper set up the way its rollback expects: the root is the default
# subvolume, with its snapshots nested in it at /.snapshots. snapper can't
# tell a root that wasn't installed as a snapshot is "classic", so it's
# told.
"$vm" ssh "pacman -S --noconfirm --noprogressbar --needed snapper >/dev/null"
"$vm" ssh "btrfs subvolume set-default / && { snapper list-configs | grep -c '^root ' >/dev/null || snapper -c root create-config /; }"
"$vm" ssh "snapper -c root create -d base && snapper -c root --ambit classic rollback 1" | tail -n 1
new=$("$vm" ssh "btrfs subvolume get-default / | sed 's/.* path //'")
"$vm" ssh "sed -i 's| rootflags=subvol=[^ ]*||' /boot/grub/grub.cfg"
"$vm" ssh "mkdir -p /run/top && mount -o subvolid=5 UUID=\$(findmnt -no UUID /) /run/top \
    && awk -v OFS='\\t' '\$2 == \"/\" { gsub(/,?subvolid=[0-9]+/, \"\", \$4); gsub(/,?subvol=[^,]+/, \"\", \$4) } 1' /run/top/$new/etc/fstab > /tmp/fstab \
    && cp /tmp/fstab /run/top/$new/etc/fstab && umount /run/top"
"$vm" reboot
check "findmnt -no FSROOT /" "/$new"
echo "snapper ok"
