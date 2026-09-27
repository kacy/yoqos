#!/bin/sh
# the tests that need a booted arch: systemd running, a real bootloader.
# boots a fresh vm, runs the arch smoke test in it, and stops the vm.
# usage: tests/vm/test.sh <path to os>
set -eu

vm=tests/vm/vm.sh
os=$1

# where the image keeps its esp, and the root it boots before generations.
case ${VM_IMAGE:-cloud} in
archinstall | ext4 | limine) VM_ESP=/boot VM_ROOT=/@ ;;
*) VM_ESP=/efi VM_ROOT=/ ;;
esac
export VM_ESP VM_ROOT

"$vm" start
trap '"$vm" stop' EXIT

# the binary is built against today's arch; bring the image up to date.
# git is what an os package would depend on, for the config's history.
"$vm" ssh pacman -Syu --noconfirm --noprogressbar --needed git >/dev/null

"$vm" copy "$os" /usr/local/bin/os
"$vm" copy tests/arch/smoke.sh /root/smoke.sh
"$vm" ssh mkdir -p /root/dist
"$vm" copy dist/yoq-drift.hook /root/dist/yoq-drift.hook
"$vm" ssh "cd /root && sh smoke.sh /usr/local/bin/os"
# machines that can't have generations yet: enable-rollback says which
# check fails, and changes nothing.
case ${VM_IMAGE:-cloud} in
ext4) tests/vm/manage.sh "root filesystem: ext4" ;;
limine) tests/vm/manage.sh "bootloader: limine" ;;
*)
    tests/vm/rollback.sh
    tests/vm/trial.sh
    tests/vm/desktop.sh
    ;;
esac
