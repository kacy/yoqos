#!/bin/sh
# spike: can grub boot a new entry exactly once on a btrfs root? a: the
# stock grub-reboot, with grubenv on btrfs. b: an env file on the esp.
# prints what happened; it doesn't fail.
vm=tests/vm/vm.sh
console=${VM_DIR:-$HOME/.cache/yoq-vm}/console.log

# which entry this boot came from. a boot that never came back shows
# grub's and the kernel's last words, and ends the spike.
booted() {
    if ! timeout 30 "$vm" ssh true 2>/dev/null; then
        echo "no boot. the console's last lines:"
        tail -n 40 "$console" | tr -d '\r' | sed 's/\x1b\[[0-9;]*[A-Za-z]//g'
        exit 0
    fi
    "$vm" ssh "grep -q yoq.gen=test /proc/cmdline && echo test entry || echo default entry"
}

"$vm" copy tests/vm/spikes/grub-guest.sh /root/grub-guest.sh
"$vm" ssh sh /root/grub-guest.sh setup

echo "--- a: grub-reboot, grubenv on btrfs"
"$vm" ssh "grub-reboot yoq-test && grub-editenv list"
"$vm" reboot || true
printf "first boot after:  "; booted
"$vm" ssh "grub-editenv list"
"$vm" reboot || true
printf "second boot after: "; booted
"$vm" ssh "grub-editenv - unset next_entry"
"$vm" reboot

echo "--- b: env on the esp"
"$vm" ssh "grub-editenv /efi/yoq/grubenv set yoq_next=yoq-test && grub-editenv /efi/yoq/grubenv list"
"$vm" reboot || true
printf "first boot after:  "; booted
"$vm" ssh "grub-editenv /efi/yoq/grubenv list"
"$vm" reboot || true
printf "second boot after: "; booted
