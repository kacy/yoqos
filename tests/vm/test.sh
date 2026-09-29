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
    # generations need btrfs: enable-rollback says so, and changes nothing.
    tests/vm/manage.sh "root filesystem: ext4"
    tests/vm/aur.sh
    tests/vm/install.sh
    ;;
limine | sdboot)
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
    tests/vm/trial.sh
    tests/vm/desktop.sh
    tests/vm/ids.sh
    tests/vm/leave.sh
    ;;
esac
