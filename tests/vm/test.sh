#!/bin/sh
# the tests that need a booted arch: systemd running, a real bootloader.
# boots a fresh vm, runs the arch smoke test in it, and stops the vm.
# usage: tests/vm/test.sh <path to yos>
set -eu
set -o pipefail

vm=tests/vm/vm.sh
yos=$1

# where the image keeps its esp, the root it boots before generations,
# and its bootloader.
case ${VM_IMAGE:-cloud} in
archinstall | ext4 | snapper) VM_ESP=/boot VM_ROOT=/@ VM_LOADER=grub ;;
limine | refind) VM_ESP=/boot VM_ROOT=/@ VM_LOADER=$VM_IMAGE ;;
sdboot) VM_ESP=/boot VM_ROOT=/@ VM_LOADER=systemd-boot ;;
*) VM_ESP=/efi VM_ROOT=/ VM_LOADER=grub ;;
esac
export VM_ESP VM_ROOT VM_LOADER

# the ext4 machine installs new ones on a second disk, and on luks on a
# third, which its tpm unlocks, and whose passphrase is typed at the
# serial console once secure boot is on.
[ "${VM_IMAGE:-cloud}" = ext4 ] && export VM_DISK2=1 VM_DISK3=1 VM_TPM=1
# every vm's serial console takes input too, so one that stops answering
# over ssh can be asked why (vm.sh diagnose).
export VM_SERIAL_IN=1
# every image but cloud and snapper runs on firmware that can enforce
# secure boot, in setup mode until a test enrolls keys. grub needs a tpm
# to start under secure boot.
case ${VM_IMAGE:-cloud} in sdboot | archinstall | limine | refind | ext4) export VM_SECBOOT=1 ;; esac
[ "${VM_IMAGE:-cloud}" = archinstall ] && export VM_TPM=1
"$vm" start
trap '"$vm" stop' EXIT

# the binary is built against today's arch; bring the image up to date.
# git is what a yos package would depend on, for the config's history.
# a new kernel needs a reboot before its modules load.
"$vm" ssh pacman -Syu --noconfirm --noprogressbar --needed git >/dev/null
# the journal goes to the serial console too, so when a boot never answers
# over ssh, the console log shows what sshd and the network did. it's in
# /etc, so every root made from this one has it.
"$vm" ssh "mkdir -p /etc/systemd/journald.conf.d && printf '[Journal]\\nForwardToConsole=yes\\nTTYPath=/dev/ttyS0\\nMaxLevelConsole=info\\n' > /etc/systemd/journald.conf.d/yos-test-console.conf"
"$vm" reboot

# the move from yoq os, yos's name before 0.2.0, runs on its own: yos goes
# in /usr/bin there, as its package puts it.
if [ "${VM_SUITE:-}" = switch ]; then
    tests/vm/switch.sh /tmp/old/0.1.5 "$yos"
    exit 0
fi

# the serial console report a vm that stops answering gets, checked once
# here so it works when it's needed.
"$vm" diagnose 2>&1 | grep -a -c '^lo ' | grep -qx 1 || { echo "test: the serial console report came back empty"; exit 1; }
"$vm" copy "$yos" /usr/local/bin/yos
"$vm" copy tests/arch/smoke.sh /root/smoke.sh
"$vm" ssh mkdir -p /root/dist
"$vm" copy dist/yos-drift.hook /root/dist/yos-drift.hook
"$vm" ssh "cd /root && sh smoke.sh /usr/local/bin/yos"
case ${VM_IMAGE:-cloud} in
ext4)
    tests/vm/build.sh
    # the manage rung's failures: power lost during an apply or right
    # after its transaction, and no network.
    tests/vm/failures.sh crash committed download
    tests/vm/secrets.sh
    # a new kernel, applied live, and the old one's modules kept for it.
    tests/vm/kernel-live.sh
    # generations need btrfs: enable-rollback says so, and changes nothing.
    tests/vm/manage.sh "root filesystem: ext4"
    tests/vm/aur.sh
    tests/vm/install.sh
    ;;
limine | sdboot)
    tests/vm/rollback.sh
    tests/vm/trial.sh
    tests/vm/load-failures.sh
    # unified kernel images, started by each loader's own kind of entry.
    tests/vm/uki.sh
    # boot files live on the esp here, so it can run out of room. both
    # lose power partway through a trial.
    if [ "$VM_IMAGE" = sdboot ]; then tests/vm/failures.sh esp trial; else tests/vm/failures.sh trial; fi
    # signed images under secure boot. systemd-boot's test takes the keys
    # out at the end; limine's leaves them for leave.sh.
    if [ "$VM_IMAGE" = sdboot ]; then tests/vm/secureboot.sh; else tests/vm/secureboot-loader.sh; fi
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
    tests/vm/load-failures.sh
    # the firmware's one-shot boot, with the power lost partway through.
    tests/vm/failures.sh trial
    # under secure boot, with the keys left enrolled for leave.sh.
    tests/vm/secureboot-loader.sh
    tests/vm/leave.sh
    ;;
*)
    tests/vm/rollback.sh
    # the kernel changing through generations: back a few weeks, the
    # weekly update forward, and rollbacks across it. it leaves a pinned
    # generation with the older kernel for failures.sh restore.
    if [ "${VM_IMAGE:-cloud}" = archinstall ]; then tests/vm/kernel.sh; fi
    # a drop-in built into a staged root, on one image of the two.
    if [ "${VM_IMAGE:-cloud}" = cloud ]; then tests/vm/initramfs.sh; fi
    tests/vm/trial.sh
    # kernels grub can't load and early hangs, on one image of the two:
    # the one whose run is shorter.
    if [ "${VM_IMAGE:-cloud}" = archinstall ]; then tests/vm/load-failures.sh; fi
    tests/vm/desktop.sh
    tests/vm/ids.sh
    # failures with generations, on one image of the two.
    if [ "${VM_IMAGE:-cloud}" = cloud ]; then tests/vm/failures.sh crash committed download disk trial; fi
    # the esp is /boot here, so a rollback puts a kernel on it.
    if [ "${VM_IMAGE:-cloud}" = archinstall ]; then tests/vm/failures.sh restore; fi
    # grub under secure boot, with the keys left enrolled for leave.sh.
    if [ "${VM_IMAGE:-cloud}" = archinstall ]; then tests/vm/secureboot-loader.sh; fi
    tests/vm/leave.sh
    ;;
esac
