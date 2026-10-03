#!/bin/sh
# [boot] secure_boot on grub, limine, or refind, on firmware that can
# enforce secure boot (vm.sh's VM_SECBOOT) and starts in setup mode. os
# signs the images it boots with sbctl's keys, along with grub, which it
# installs again built to start under secure boot, and refind's btrfs
# driver. once the keys are enrolled, the trial boots its signed image.
# on grub, a trial whose image has no signature falls back, and so does
# an entry with an unsigned kernel. limine starts that kernel, since it
# loads kernels itself. limine and refind can't fall back from an image
# the firmware refuses (limine halts, refind waits for a key), so that's
# not tried there. the keys stay enrolled, so leave.sh uninstalls under
# secure boot after this, in the same vm.
set -eu
. tests/vm/lib.sh

conf=$(menu_file)
on_failure="cat /proc/cmdline; ls -l $VM_ESP/yoq/boot; find $VM_ESP/EFI -type f; /usr/local/bin/os doctor"
[ "$VM_LOADER" = grub ] && on_failure="grub-editenv $VM_ESP/yoq/grubenv list; $on_failure"

"$vm" reboot
settled
check "$(efivar SetupMode)" 1
check "$(efivar SecureBoot)" 0

# the one-time step os leaves to the person: sbctl's keys. then both keys
# under [boot], replacing any an earlier test left.
"$vm" ssh "pacman -S --noconfirm --needed --noprogressbar sbctl >/dev/null && sbctl create-keys >/dev/null"
"$vm" ssh "sed -i -e '/^uki = /d' -e '/^secure_boot = /d' /etc/yoq/machine.toml && if grep -q '^\\[boot\\]' /etc/yoq/machine.toml; then sed -i -e '/^\\[boot\\]/a secure_boot = true' -e '/^\\[boot\\]/a uki = true' /etc/yoq/machine.toml; else printf '\\n[boot]\\nuki = true\\nsecure_boot = true\\n' >> /etc/yoq/machine.toml; fi"
# the new packages need a relock, as with any key that brings some.
"$vm" ssh "/usr/local/bin/os update --yes" | tail -n 3
on_trial yes

# os signed what it put on the esp: its images, grub, refind's driver.
[ "$VM_LOADER" = grub ] && check "test -s /var/lib/yoq/grub-signed && echo yes" yes
check "/usr/local/bin/os doctor | grep '^  no  esp signatures:' | grep -c -i -e /yoq/boot/ -e grub -e btrfs_x64 || true" 0

# anything else on the esp signed, then the keys enrolled with
# microsoft's, as the docs say.
"$vm" ssh "find $VM_ESP/EFI -iname '*.efi' -type f -exec sbctl sign -s {} \\; >/dev/null"
check "/usr/local/bin/os doctor | grep -c '^  ok  esp signatures: every efi file is signed\$'" 1
"$vm" ssh "sbctl enroll-keys --microsoft --yes-this-might-brick-my-machine >/dev/null"
check "$(efivar SetupMode)" 0

# the loader starts under secure boot, and the trial boots os's signed
# image.
"$vm" reboot
settled
show_env
check "$(efivar SecureBoot)" 1
check "ls /sys/firmware/efi/efivars | grep -c '^StubInfo-'" 1
check "journalctl -b -u yoq-health --no-pager -o cat | grep -c 'the default now'" 1
on_trial no
check "/usr/local/bin/os plan" "nothing to do. this machine matches its config."
check "/usr/local/bin/os doctor | grep -c '^  ok  firmware keys: sbctl.s db key is enrolled\$'" 1

case $VM_LOADER in
grub)
    # a menu write after that leaves grub as it is.
    before_grub=$("$vm" ssh "cat /var/lib/yoq/grub-signed")
    "$vm" ssh "/usr/local/bin/os gc >/dev/null"
    check "cat /var/lib/yoq/grub-signed" "$before_grub"

    # a trial whose image has no signature: the firmware won't start it,
    # and grub falls back to the generation before.
    "$vm" ssh "/usr/local/bin/os add --yes intel-ucode" | tail -n 1
    on_trial yes
    before=$(second_newest)
    twin=$("$vm" ssh "sed -n '/--id head/,/^}/ s|^    chainloader (\${yoq_esp})||p' $conf | head -n 1")
    "$vm" ssh "cp $VM_ESP/vmlinuz-linux $VM_ESP$twin"
    show_env
    falls_back "$before" "console:Falling back to"
    check "$(efivar SecureBoot)" 1

    # grub starts a kernel through the firmware, which checks it: an
    # entry added to grub.cfg that boots arch's unsigned kernel, picked
    # once, won't start, and grub falls back to the newest generation.
    "$vm" ssh "printf 'menuentry \"planted\" --id planted {\n  linux (\${yoq_esp})/vmlinuz-linux %s yoq.planted\n  initrd (\${yoq_esp})/initramfs-linux.img\n}\n' \"\$(cat /proc/cmdline)\" >> $conf && grub-editenv $VM_ESP/yoq/grubenv set yoq_next=planted yoq_default=head"
    "$vm" reboot
    settled
    check "grep -c yoq.planted /proc/cmdline || true" 0
    check "findmnt -no FSROOT /" "/$(newest_root)"
    "$vm" ssh "grub-editenv $VM_ESP/yoq/grubenv unset yoq_default yoq_next yoq_tried && /usr/local/bin/os gc >/dev/null"
    check "grep -c planted $conf || true" 0
    ;;
limine)
    # limine loads a kernel itself, without the firmware's check, as long
    # as its config's hash isn't enrolled: an entry added to limine.conf
    # that boots arch's unsigned kernel, picked once, starts. that's the
    # gap `os doctor` warns about when the tpm unlocks the root.
    "$vm" ssh "printf '\n/planted\n    protocol: linux\n    path: boot():/vmlinuz-linux\n    module_path: boot():/initramfs-linux.img\n    cmdline: %s yoq.planted\n' \"\$(cat /proc/cmdline)\" >> $conf && bootctl set-oneshot planted"
    "$vm" reboot
    settled
    check "grep -c yoq.planted /proc/cmdline" 1
    check "$(efivar SecureBoot)" 1
    "$vm" ssh "sed -i '/^\\/planted\$/,\$d' $conf"
    check "grep -c planted $conf || true" 0
    ;;
esac

# without os, grub, refind, and systemd-boot boot arch's kernel through
# the firmware, which refuses it unsigned, so uninstall waits for it to
# be signed. limine loads it itself.
case $VM_LOADER in
grub | refind)
    check "{ /usr/local/bin/os uninstall --yes </dev/null 2>&1 || true; } | grep -c '^  no  secure boot: enforced, and vmlinuz-linux has no signature\$'" 1
    "$vm" ssh "sbctl sign -s /boot/vmlinuz-linux >/dev/null"
    check "/usr/local/bin/os uninstall --json </dev/null | grep -c '\"found\": \"enforced, and the kernels in /boot are signed\"'" 1
    ;;
esac
[ "$VM_LOADER" = grub ] && check "/usr/local/bin/os uninstall --json </dev/null | grep -c '\"found\": \"enforced, and sbctl has keys to sign grub\"'" 1
echo "secure boot on $VM_LOADER ok"
