#!/bin/sh
# a mkinitcpio drop-in changes the initramfs, so it waits for a reboot: the
# next root's initramfs is built with it, inside that root, and that's the
# initramfs the trial boots. runs after rollback.sh, in the same vm.
set -eu
. tests/vm/lib.sh

# the root the machine runs keeps the initramfs it booted in its own
# /boot, even where the esp is mounted over it.
booted_marker() {
    check_top "$(initramfs_count "/run/yos-top\$(findmnt -no FSROOT /)/boot/initramfs-linux.img" etc/yos-initramfs-marker)" "$1"
}

"$vm" copy tests/vm/initramfs.toml /root/initramfs.toml
"$vm" ssh "cp /etc/yos/machine.toml /root/machine.toml.saved && cat /root/initramfs.toml >> /etc/yos/machine.toml && /usr/local/bin/yos apply --yes" | tail -n 2
on_trial yes
check "test -e /etc/yos-initramfs-marker && echo here || echo not yet" "not yet"
staged=$(newest_root)
"$vm" reboot
settled
on_trial no
check "findmnt -no FSROOT / | sed 's|^/||'" "${staged#/}"
booted_marker 1

# the drop-in changing again: the next initramfs is built without the
# marker.
"$vm" ssh "sed -i 's|^text = \"FILES+=.*|text = \"# nothing\\\\n\"|' /etc/yos/machine.toml && /usr/local/bin/yos apply --yes" | tail -n 2
on_trial yes
"$vm" reboot
settled
on_trial no
booted_marker 0
# files taken out of the config stay, so they go by hand.
"$vm" ssh "cp /root/machine.toml.saved /etc/yos/machine.toml && rm /etc/mkinitcpio.conf.d/50-yos-test.conf /etc/yos-initramfs-marker"
check "/usr/local/bin/yos plan" "nothing to do. this machine matches its config."
echo "initramfs ok"
