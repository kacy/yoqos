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
archinstall | ext4) VM_ESP=/boot VM_ROOT=/@ VM_LOADER=grub ;;
limine | refind) VM_ESP=/boot VM_ROOT=/@ VM_LOADER=$VM_IMAGE ;;
*) VM_ESP=/efi VM_ROOT=/ VM_LOADER=grub ;;
esac
export VM_ESP VM_ROOT VM_LOADER

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
    # generations need btrfs: enable-rollback says so, and changes nothing.
    tests/vm/manage.sh "root filesystem: ext4"
    tests/vm/aur.sh
    ;;
limine)
    tests/vm/rollback.sh
    tests/vm/trial.sh
    tests/vm/leave.sh
    ;;
refind)
    # no one-shot boot, so no trials: a failed generation is picked from
    # the menu by hand.
    tests/vm/rollback.sh
    tests/vm/leave.sh
    ;;
*)
    tests/vm/rollback.sh
    tests/vm/trial.sh
    tests/vm/desktop.sh
    tests/vm/leave.sh
    ;;
esac
