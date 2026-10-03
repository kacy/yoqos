#!/bin/sh
# [boot] secure_boot on grub, on firmware that can enforce secure boot
# (vm.sh's VM_SECBOOT) and starts in setup mode. os installs grub again,
# built to start under secure boot, and signs it and the images it boots
# with sbctl's keys. once the keys are enrolled, the trial boots its
# signed image through grub, and a trial whose image has no signature
# falls back, as does an entry with an unsigned kernel. the keys stay
# enrolled, so leave.sh uninstalls under secure boot after this, in the
# same vm.
set -eu
. tests/vm/lib.sh

grub_cfg=$VM_ESP/grub/grub.cfg
on_failure="grub-editenv $VM_ESP/yoq/grubenv list; cat /proc/cmdline; ls -l $VM_ESP/yoq/boot; find $VM_ESP/EFI -type f; /usr/local/bin/os doctor"

"$vm" reboot
settled
check "$(efivar SetupMode)" 1
check "$(efivar SecureBoot)" 0

# the one-time step os leaves to the person: sbctl's keys. then both keys
# under [boot].
"$vm" ssh "pacman -S --noconfirm --needed --noprogressbar sbctl >/dev/null && sbctl create-keys >/dev/null"
"$vm" ssh "if grep -q '^\\[boot\\]' /etc/yoq/machine.toml; then sed -i -e '/^\\[boot\\]/a secure_boot = true' -e '/^\\[boot\\]/a uki = true' /etc/yoq/machine.toml; else printf '\\n[boot]\\nuki = true\\nsecure_boot = true\\n' >> /etc/yoq/machine.toml; fi"
# the new packages need a relock, as with any key that brings some.
"$vm" ssh "/usr/local/bin/os update --yes" | tail -n 3
on_trial yes

# grub went in again and is signed, like every image its menu starts.
check "test -s /var/lib/yoq/grub-signed && echo yes" yes
check "/usr/local/bin/os doctor | grep '^  no  esp signatures:' | grep -c -i -e grub -e /yoq/boot/ || true" 0

# anything else on the esp signed, then the keys enrolled with
# microsoft's, as the docs say.
"$vm" ssh "find $VM_ESP/EFI -iname '*.efi' -type f -exec sbctl sign -s {} \; >/dev/null"
check "/usr/local/bin/os doctor | grep -c '^  ok  esp signatures: every efi file is signed\$'" 1
"$vm" ssh "sbctl enroll-keys --microsoft --yes-this-might-brick-my-machine >/dev/null"
check "$(efivar SetupMode)" 0

# grub starts under secure boot, and the trial boots os's signed image.
"$vm" reboot
settled
show_env
check "$(efivar SecureBoot)" 1
check "ls /sys/firmware/efi/efivars | grep -c '^StubInfo-'" 1
check "journalctl -b -u yoq-health --no-pager -o cat | grep -c 'the default now'" 1
on_trial no
check "/usr/local/bin/os plan" "nothing to do. this machine matches its config."
# a menu write after that leaves grub as it is.
before_grub=$("$vm" ssh "cat /var/lib/yoq/grub-signed")
"$vm" ssh "/usr/local/bin/os gc >/dev/null"
check "cat /var/lib/yoq/grub-signed" "$before_grub"

# a trial whose image has no signature: the firmware won't start it, and
# grub falls back to the generation before.
"$vm" ssh "/usr/local/bin/os add --yes intel-ucode" | tail -n 1
on_trial yes
before=$(second_newest)
twin=$("$vm" ssh "sed -n '/--id head/,/^}/ s|^    chainloader (\${yoq_esp})||p' $grub_cfg | head -n 1")
"$vm" ssh "cp $VM_ESP/vmlinuz-linux $VM_ESP$twin"
show_env
falls_back "$before" "console:Falling back to"
check "$(efivar SecureBoot)" 1

# grub starts a kernel through the firmware, which checks it: an entry
# added to grub.cfg that boots arch's unsigned kernel, picked once, won't
# start, and grub falls back to the newest generation.
"$vm" ssh "printf 'menuentry \"planted\" --id planted {\n  linux (\${yoq_esp})/vmlinuz-linux %s yoq.planted\n  initrd (\${yoq_esp})/initramfs-linux.img\n}\n' \"\$(cat /proc/cmdline)\" >> $grub_cfg && grub-editenv $VM_ESP/yoq/grubenv set yoq_next=planted yoq_default=head"
"$vm" reboot
settled
check "grep -c yoq.planted /proc/cmdline || true" 0
check "findmnt -no FSROOT /" "/$(newest_root)"
"$vm" ssh "grub-editenv $VM_ESP/yoq/grubenv unset yoq_default yoq_next yoq_tried && /usr/local/bin/os gc >/dev/null"
check "grep -c planted $grub_cfg || true" 0

# without os, grub boots arch's kernel, which the firmware refuses
# unsigned, so uninstall waits for it to be signed. then it can go
# ahead, and signs the grub it installs again.
check "{ /usr/local/bin/os uninstall --yes </dev/null 2>&1 || true; } | grep -c '^  no  secure boot: enforced, and vmlinuz-linux has no signature\$'" 1
"$vm" ssh "sbctl sign -s /boot/vmlinuz-linux >/dev/null"
check "/usr/local/bin/os uninstall --json </dev/null | grep -c '\"found\": \"enforced, and sbctl has keys to sign grub\"'" 1
check "/usr/local/bin/os uninstall --json </dev/null | grep -c '\"found\": \"enforced, and the kernels in /boot are signed\"'" 1
echo "secure boot on grub ok"
