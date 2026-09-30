#!/bin/sh
# the tests that need a booted arch: systemd running, a real bootloader.
# boots a fresh vm, runs the arch smoke test in it, and stops the vm.
# usage: tests/vm/test.sh <path to os>
set -eu
set -o pipefail

vm=tests/vm/vm.sh
os=$1

# where the image keeps its esp, the root it boots before generations,
# and its bootloader.
case ${VM_IMAGE:-cloud} in
archinstall | ext4 | snapper) VM_ESP=/boot VM_ROOT=/@ VM_LOADER=grub ;;
limine | refind) VM_ESP=/boot VM_ROOT=/@ VM_LOADER=$VM_IMAGE ;;
sdboot) VM_ESP=/boot VM_ROOT=/@ VM_LOADER=systemd-boot ;;
*) VM_ESP=/efi VM_ROOT=/ VM_LOADER=grub ;;
esac
export VM_ESP VM_ROOT VM_LOADER

# the ext4 machine installs a new one on a second disk.
[ "${VM_IMAGE:-cloud}" = ext4 ] && export VM_DISK2=1
"$vm" start
trap '"$vm" stop' EXIT

# the binary is built against today's arch; bring the image up to date.
# git is what an os package would depend on, for the config's history.
# a new kernel needs a reboot before its modules load.
"$vm" ssh pacman -Syu --noconfirm --noprogressbar --needed git >/dev/null
"$vm" reboot

"$vm" copy "$os" /usr/local/bin/os
"$vm" copy tests/arch/smoke.sh /root/smoke.sh
"$vm" ssh mkdir -p /root/dist
"$vm" copy dist/yoq-drift.hook /root/dist/yoq-drift.hook
"$vm" ssh "cd /root && sh smoke.sh /usr/local/bin/os"
case ${VM_IMAGE:-cloud} in
ext4)
    tests/vm/build.sh
    # the manage rung's failures: power lost during an apply, and no network.
    tests/vm/failures.sh crash download
    # generations need btrfs: enable-rollback says so, and changes nothing.
    tests/vm/manage.sh "root filesystem: ext4"
    tests/vm/aur.sh
    tests/vm/install.sh
    ;;
limine | sdboot)
    tests/vm/rollback.sh
    tests/vm/trial.sh
    # boot files live on the esp here, so it can run out of room.
    if [ "$VM_IMAGE" = sdboot ]; then tests/vm/failures.sh esp; fi
    tests/vm/leave.sh
    ;;
snapper)
    # the root snapper's rollback made is the one enable-rollback converts.
    tests/vm/snapper.sh
    VM_ROOT=$("$vm" ssh "findmnt -no FSROOT /")
    export VM_ROOT
    tests/vm/rollback.sh
    tests/vm/trial.sh
    tests/vm/leave.sh
    ;;
refind)
    tests/vm/rollback.sh
    tests/vm/trial.sh
    tests/vm/leave.sh
    ;;
*)
    tests/vm/rollback.sh
    # a drop-in built into a staged root, on one image of the two.
    if [ "${VM_IMAGE:-cloud}" = cloud ]; then tests/vm/initramfs.sh; fi
    tests/vm/trial.sh
    tests/vm/desktop.sh
    tests/vm/ids.sh
    # failures with generations, on one image of the two.
    if [ "${VM_IMAGE:-cloud}" = cloud ]; then tests/vm/failures.sh crash download disk; fi
    tests/vm/leave.sh
    ;;
esac
