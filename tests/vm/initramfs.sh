#!/bin/sh
# a mkinitcpio drop-in that comes with a change needing a reboot: the next
# root's initramfs is built with it, inside that root, and that's the
# initramfs the trial boots. runs after rollback.sh, in the same vm.
set -eu
. tests/vm/lib.sh

# the root the machine runs keeps the initramfs it booted in its own
# /boot, even where the esp is mounted over it.
booted_marker() {
    check_top "lsinitcpio /run/yoq-top\$(findmnt -no FSROOT /)/boot/initramfs-linux.img | grep -c etc/yoq-initramfs-marker" "$1"
}

# microcode needs a reboot, so the drop-in and the marker stage with it.
"$vm" copy tests/vm/initramfs.toml /root/initramfs.toml
"$vm" ssh "cp /etc/yoq/machine.toml /root/machine.toml.saved && cat /root/initramfs.toml >> /etc/yoq/machine.toml && /usr/local/bin/os add --yes intel-ucode" | tail -n 2
on_trial yes
check "test -e /etc/yoq-initramfs-marker && echo here || echo not yet" "not yet"
staged=$(newest_root)
"$vm" reboot
settled
on_trial no
check "findmnt -no FSROOT / | sed 's|^/||'" "${staged#/}"
booted_marker 1

# the drop-in changing again, with the microcode going: the next
# initramfs is built without the marker.
"$vm" ssh "sed -i 's|^text = \"FILES+=.*|text = \"# nothing\\\\n\"|' /etc/yoq/machine.toml && /usr/local/bin/os remove --yes intel-ucode" | tail -n 2
on_trial yes
"$vm" reboot
settled
on_trial no
booted_marker 0
# files taken out of the config stay, so they go by hand.
"$vm" ssh "cp /root/machine.toml.saved /etc/yoq/machine.toml && rm /etc/mkinitcpio.conf.d/50-yoq-test.conf /etc/yoq-initramfs-marker"
check "/usr/local/bin/os plan" "nothing to do. this machine matches its config."
echo "initramfs ok"
