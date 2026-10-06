#!/bin/sh
# [boot] secure_boot on grub, limine, or refind, on firmware that can
# enforce secure boot (vm.sh's VM_SECBOOT) and starts in setup mode. yos
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
on_failure="cat /proc/cmdline; ls -l $VM_ESP/yos/boot; find $VM_ESP/EFI -type f; /usr/local/bin/yos doctor"
[ "$VM_LOADER" = grub ] && on_failure="grub-editenv $VM_ESP/yos/grubenv list; $on_failure"

"$vm" reboot
settled
check "$(efivar SetupMode)" 1
check "$(efivar SecureBoot)" 0

# the one-time step yos leaves to the person: sbctl's keys. then both keys
# under [boot], replacing any an earlier test left.
"$vm" ssh "pacman -S --noconfirm --needed --noprogressbar sbctl >/dev/null && sbctl create-keys >/dev/null"
"$vm" ssh "sed -i -e '/^uki = /d' -e '/^secure_boot = /d' /etc/yos/machine.toml && if grep -q '^\\[boot\\]' /etc/yos/machine.toml; then sed -i -e '/^\\[boot\\]/a secure_boot = true' -e '/^\\[boot\\]/a uki = true' /etc/yos/machine.toml; else printf '\\n[boot]\\nuki = true\\nsecure_boot = true\\n' >> /etc/yos/machine.toml; fi"
# the new packages need a relock, as with any key that brings some.
"$vm" ssh "/usr/local/bin/yos update --yes" | tail -n 3
on_trial yes

# yos signed what it put on the esp: its images, grub, refind's driver.
[ "$VM_LOADER" = grub ] && check "test -s /var/lib/yos/grub-signed && echo yes" yes
check "$(doctor_report); grep '^  no  esp signatures:' /tmp/report | grep -c -i -e /yos/boot/ -e grub -e btrfs_x64 || true" 0

# anything else on the esp signed, then the keys enrolled with
# microsoft's, as the docs say.
"$vm" ssh "find $VM_ESP/EFI -iname '*.efi' -type f -exec sbctl sign -s {} \\; >/dev/null"
check "$(doctor_report); grep -c '^  ok  esp signatures: every efi file is signed\$' /tmp/report" 1
"$vm" ssh "sbctl enroll-keys --microsoft --yes-this-might-brick-my-machine >/dev/null"
check "$(efivar SetupMode)" 0

# the loader starts under secure boot, and the trial boots yos's signed
# image.
"$vm" reboot
settled
show_env
check "$(efivar SecureBoot)" 1
check "ls /sys/firmware/efi/efivars | grep -c '^StubInfo-'" 1
check "journalctl -b -u yos-health --no-pager -o cat | grep -c 'the default now'" 1
on_trial no
check "/usr/local/bin/yos plan" "nothing to do. this machine matches its config."
check "$(doctor_report); grep -c '^  ok  firmware keys: sbctl.s db key is enrolled\$' /tmp/report" 1

case $VM_LOADER in
grub)
    # a menu write after that leaves grub as it is.
    before_grub=$("$vm" ssh "cat /var/lib/yos/grub-signed")
    "$vm" ssh "/usr/local/bin/yos gc >/dev/null"
    check "cat /var/lib/yos/grub-signed" "$before_grub"

    # a trial whose image has no signature: the firmware won't start it,
    # and grub falls back to the generation before.
    "$vm" ssh "/usr/local/bin/yos add --yes intel-ucode" | tail -n 1
    on_trial yes
    before=$(second_newest)
    twin=$("$vm" ssh "sed -n '/--id head/,/^}/ s|^    chainloader (\${yos_esp})||p' $conf | sed -n 1p")
    "$vm" ssh "cp $VM_ESP/vmlinuz-linux $VM_ESP$twin"
    show_env
    falls_back "$before" "console:Falling back to"
    check "$(efivar SecureBoot)" 1

    # grub starts a kernel through the firmware, which checks it: an
    # entry added to grub.cfg that boots arch's unsigned kernel, picked
    # once, won't start, and grub falls back to the newest generation.
    "$vm" ssh "printf 'menuentry \"planted\" --id planted {\n  linux (\${yos_esp})/vmlinuz-linux %s yos.planted\n  initrd (\${yos_esp})/initramfs-linux.img\n}\n' \"\$(cat /proc/cmdline)\" >> $conf && grub-editenv $VM_ESP/yos/grubenv set yos_next=planted yos_default=head"
    mark=$(wc -c < "$console" 2>/dev/null || echo 0)
    "$vm" reboot
    settled
    # grub tried the planted entry and fell back from it, rather than never
    # trying it.
    if ! tail -c +"$((mark + 1))" "$console" | tr -d '\r' | grep -a -e "Falling back to" >/dev/null; then
        echo "$name: grub never tried the planted entry: no fallback on the console"
        exit 1
    fi
    check "grep -c yos.planted /proc/cmdline || true" 0
    check "findmnt -no FSROOT /" "/$(newest_root)"
    "$vm" ssh "grub-editenv $VM_ESP/yos/grubenv unset yos_default yos_next yos_tried && /usr/local/bin/yos gc >/dev/null"
    check "grep -c planted $conf || true" 0
    ;;
limine)
    # limine loads a kernel itself, without the firmware's check, as long
    # as its config's hash isn't enrolled: an entry added to limine.conf
    # that boots arch's unsigned kernel, picked once, starts. that's the
    # gap `yos doctor` warns about when the tpm unlocks the root.
    "$vm" ssh "printf '\n/planted\n    protocol: linux\n    path: boot():/vmlinuz-linux\n    module_path: boot():/initramfs-linux.img\n    cmdline: %s yos.planted\n' \"\$(cat /proc/cmdline)\" >> $conf && bootctl set-oneshot planted"
    "$vm" reboot
    settled
    check "grep -c yos.planted /proc/cmdline" 1
    check "$(efivar SecureBoot)" 1
    "$vm" ssh "sed -i '/^\\/planted\$/,\$d' $conf"
    check "grep -c planted $conf || true" 0
    ;;
esac

# without yos, grub, refind, and systemd-boot boot arch's kernel through
# the firmware, which refuses it unsigned, so uninstall waits for it to
# be signed. limine loads it itself.
case $VM_LOADER in
grub | refind)
    check "/usr/local/bin/yos uninstall --yes </dev/null >/tmp/out 2>&1; echo \$?" 1
    check "grep -c '^  no  secure boot: enforced, and vmlinuz-linux has no signature\$' /tmp/out" 1
    "$vm" ssh "sbctl sign -s /boot/vmlinuz-linux >/dev/null"
    check "/usr/local/bin/yos uninstall --json </dev/null >/tmp/out; echo \$?" 0
    check "grep -c '\"found\": \"enforced, and the kernels in /boot are signed\"' /tmp/out" 1
    ;;
esac
if [ "$VM_LOADER" = grub ]; then
    check "/usr/local/bin/yos uninstall --json </dev/null >/tmp/out; echo \$?" 0
    check "grep -c '\"found\": \"enforced, and sbctl has keys to sign grub\"' /tmp/out" 1
fi
echo "secure boot on $VM_LOADER ok"
