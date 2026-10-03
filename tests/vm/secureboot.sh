#!/bin/sh
# [boot] secure_boot on systemd-boot, on firmware that can enforce secure
# boot (vm.sh's VM_SECBOOT) and starts in setup mode. os refuses without
# sbctl's keys, then signs the next generation's image with them; the
# keys are enrolled, and the trial boots that image with secure boot on.
# each image has its entry's command line in it, which a line added to the
# entry on the esp doesn't change. a trial that can't boot still falls back to the generation before. at
# the end the keys come out of the firmware again, so the tests after
# this boot without secure boot. runs after uki.sh, in the same vm.
set -eu
. tests/vm/lib.sh

entries=$VM_ESP/loader/entries
stub_image="f=\$(ls /sys/firmware/efi/efivars/StubImageIdentifier-* 2>/dev/null) && tail -c +5 \$f | tr -d '\\000' | tr '\\\\' / || echo none"
on_failure="bootctl status --no-pager 2>&1 | head -n 30; cat /proc/cmdline; ls -l $VM_ESP/yoq/boot; /usr/local/bin/os doctor"

"$vm" reboot
settled
check "$(efivar SetupMode)" 1
check "$(efivar SecureBoot)" 0

# both keys under [boot]; uki.sh's rollback took uki out again.
"$vm" ssh "sed -i -e '/^uki = /d' -e '/^secure_boot = /d' /etc/yoq/machine.toml && if grep -q '^\\[boot\\]' /etc/yoq/machine.toml; then sed -i -e '/^\\[boot\\]/a secure_boot = true' -e '/^\\[boot\\]/a uki = true' /etc/yoq/machine.toml; else printf '\\n[boot]\\nuki = true\\nsecure_boot = true\\n' >> /etc/yoq/machine.toml; fi"
# no keys yet: nothing is built.
check "/usr/local/bin/os update --yes 2>&1 | grep -c 'error\\[E0134\\]' || true" 1
on_trial no

# the one-time step os leaves to the person: sbctl's keys.
"$vm" ssh "pacman -S --noconfirm --needed --noprogressbar sbctl >/dev/null && sbctl create-keys >/dev/null"
check "test -f /var/lib/sbctl/keys/db/db.key && test -f /var/lib/sbctl/keys/db/db.pem && echo yes" yes

"$vm" ssh "/usr/local/bin/os update --yes" | tail -n 3
on_trial yes
check "grep -c '^efi /yoq/boot/[0-9a-f]*-yoq.efi\$' $entries/yoq-trial*.conf" 1
image=$("$vm" ssh "sed -n 's|^efi ||p' $entries/yoq-trial*.conf")
# every image os put on the esp is signed; systemd-boot's own files aren't
# yet, and doctor names them.
check "/usr/local/bin/os doctor | grep '^  no  esp signatures:' | grep -c -e '$image' -e '/yoq/boot/' || true" 0
check "/usr/local/bin/os doctor | grep -c '^  no  esp signatures: unsigned: .*systemd' || true" 1

# the bootloader signed, then the keys enrolled with microsoft's, as the
# docs say. the vm's option roms aren't signed by anyone, so sbctl's
# check for them is skipped.
"$vm" ssh "find $VM_ESP/EFI -iname '*.efi' -type f -exec sbctl sign -s {} \\; >/dev/null"
check "/usr/local/bin/os doctor | grep -c '^  ok  esp signatures: every efi file is signed\$'" 1
"$vm" ssh "sbctl enroll-keys --microsoft --yes-this-might-brick-my-machine >/dev/null"
check "$(efivar SetupMode)" 0

# the trial boots os's signed image, with secure boot on.
"$vm" reboot
settled
show_env
check "$(efivar SecureBoot)" 1
check "bootctl status --no-pager 2>/dev/null | grep -c 'Secure Boot: enabled (user)'" 1
check "$stub_image" "$image"
check "journalctl -b -u yoq-health --no-pager -o cat | grep -c 'the default now'" 1
on_trial no
check "/usr/local/bin/os doctor | grep -c '^  ok  firmware secure boot: on\$'" 1
check "/usr/local/bin/os plan" "nothing to do. this machine matches its config."

# each image has its entry's command line in it, so the entries pass
# none, and the trial starts a twin with the trial's.
check "cat $entries/yoq-head.conf $entries/yoq-trial*.conf | grep -c '^options' || true" 0
check "test \"\$(sed -n 's|^efi ||p' $entries/yoq-head.conf)\" != '$image' && echo differs" differs
check "grep -c 'root=UUID=[^ ]* rootflags=[^ ]*subvol=/@roots/[0-9]*' /proc/cmdline" 1
# with secure boot on, the stub ignores a command line from the entry: one
# added to the head's entry on the esp doesn't reach the kernel.
"$vm" ssh "echo 'options init=/bin/sh yoq.planted' >> $entries/yoq-head.conf"
"$vm" reboot
settled
check "f=\$(ls /sys/firmware/efi/efivars/LoaderEntrySelected-*) && tail -c +5 \$f | tr -d '\\000'" yoq-head.conf
check "grep -c yoq.planted /proc/cmdline || true" 0
check "grep -c 'root=UUID=[^ ]* rootflags=[^ ]*subvol=/@roots/[0-9]*' /proc/cmdline" 1
"$vm" ssh "sed -i '/^options /d' $entries/yoq-head.conf"
check "grep -c '^options' $entries/yoq-head.conf || true" 0

# an initramfs planted on the esp goes into the root's copy at the next
# generation, but never into a signed image: os builds that one in the
# root with mkinitcpio, so the machine still boots. the real one is put
# back by hand after: `mkinitcpio -P` would also have sbctl's post hook
# sign arch's kernel in /boot, which the uninstall check below needs
# unsigned.
"$vm" ssh "cp -a $VM_ESP/initramfs-linux.img /root/initramfs-linux.img.real && echo not an initramfs > $VM_ESP/initramfs-linux.img"
"$vm" ssh "/usr/local/bin/os add --yes tree" | tail -n 1
on_trial no
# still there: nothing in that apply wrote the initramfs.
check "grep -c 'not an initramfs' $VM_ESP/initramfs-linux.img" 1
"$vm" reboot
settled
check "f=\$(ls /sys/firmware/efi/efivars/LoaderEntrySelected-*) && tail -c +5 \$f | tr -d '\\000'" yoq-head.conf
check "$(efivar SecureBoot)" 1
check "grep -c 'root=UUID=[^ ]* rootflags=[^ ]*subvol=/@roots/[0-9]*' /proc/cmdline" 1
# the real one back, and the package out again.
"$vm" ssh "cp -a /root/initramfs-linux.img.real $VM_ESP/initramfs-linux.img"
"$vm" ssh "/usr/local/bin/os remove --yes tree" | tail -n 1
on_trial no

# a trial whose kernel can't start: a signed image of its own, with a
# garbage initramfs, so the firmware runs it and the kernel panics. it has
# the running command line in it, with panic=10, since the entry passes
# none. the next boot falls back to the generation before, whose image is
# signed.
"$vm" ssh "/usr/local/bin/os add --yes intel-ucode" | tail -n 1
on_trial yes
before=$(second_newest)
"$vm" ssh "echo not an initramfs > /root/garbage.img && ukify build --config=/etc/kernel/yoq-uki.conf --linux=/boot/vmlinuz-linux --initrd=/root/garbage.img --cmdline=\"\$(cat /proc/cmdline)\" --output=$VM_ESP/yoq/boot/garbage.efi >/dev/null && sbctl sign $VM_ESP/yoq/boot/garbage.efi >/dev/null && sed -i 's|^efi .*|efi /yoq/boot/garbage.efi|' $entries/yoq-trial*.conf && cat $entries/yoq-trial*.conf"
show_env
falls_back "$before" "console:Kernel panic"
check "$(efivar SecureBoot)" 1
# uninstall would leave systemd-boot starting arch's unsigned kernel,
# which the firmware refuses now, so it won't go ahead.
on_failure="$on_failure; /usr/local/bin/os uninstall --json </dev/null 2>&1"
check "{ /usr/local/bin/os uninstall --yes </dev/null 2>&1 || true; } | grep -c '^  no  secure boot: enforced, and vmlinuz-linux has no signature\$'" 1
check "test -e /var/lib/yoq && echo state || echo none" state
# signed, as sbctl's mkinitcpio hook does whenever sbctl has keys, the
# kernel boots without os, so uninstall would go ahead. only its plan is
# looked at, then the unsigned kernel goes back.
"$vm" ssh "cp -a /boot/vmlinuz-linux /root/vmlinuz-linux.unsigned && sbctl sign /boot/vmlinuz-linux >/dev/null"
check "/usr/local/bin/os uninstall --json </dev/null | grep -c '\"found\": \"enforced, and the kernels in /boot are signed\"'" 1
"$vm" ssh "cp -a /root/vmlinuz-linux.unsigned /boot/vmlinuz-linux"

# the platform key out again: setup mode, and no secure boot from the
# next boot on.
"$vm" ssh "sbctl reset >/dev/null"
"$vm" reboot
settled
check "$(efivar SetupMode)" 1
check "$(efivar SecureBoot)" 0
echo "secure boot ok"
