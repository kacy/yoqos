#!/bin/sh
# the tests that need a booted arch: systemd running, a real bootloader.
# boots a fresh vm, runs the arch smoke test in it, and stops the vm.
# usage: tests/vm/test.sh <path to os>
set -eu

vm=tests/vm/vm.sh
os=$1

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
