#!/bin/sh
# trials whose kernel the bootloader can't load at all: missing, or not a
# kernel. trial.sh's broken initramfs gets as far as a kernel panic, which
# reboots by itself; these stop in the bootloader, which has to fall back
# to the generation before on its own. runs after trial.sh, in the same vm.
set -eu
. tests/vm/lib.sh

for how in missing garbage; do
    "$vm" reboot
    settled
    "$vm" ssh "/usr/local/bin/os add --yes intel-ucode" | tail -n 1
    on_trial yes
    before=$(second_newest)
    break_trial_kernel "$how"
    show_env
    falls_back "$before"
    on_trial no
    echo "load failure ok: $how"
done
echo "load failures ok"
