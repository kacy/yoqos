#!/bin/sh
# secure boot on the machine os installed on luks, whose tpm unlocks the
# root. turning uki and secure_boot on and enrolling the keys changes the
# firmware state the tpm's key is sealed to (pcr 7), so the next boot asks
# for the passphrase. it's typed at the serial console five and a half
# minutes in, past the trial watchdog's five, which counts from the root's
# own start, so the trial still passes. making the tpm's key again makes
# the boot after that unattended. runs inside install.sh, on the
# encrypted machine, on firmware that can enforce secure boot.
set -eu
. tests/vm/lib.sh

part=$("$vm" ssh "cryptsetup status root | sed -n 's/^ *device: *//p'")
on_failure="cat /proc/cmdline; grub-editenv /boot/yoq/grubenv list; /usr/local/bin/os doctor; journalctl -b -u yoq-health --no-pager -o cat | tail -n 8"

check "$(efivar SetupMode)" 1
check "/usr/local/bin/os doctor | grep -c '^  ok  tpm key: opens the root\$'" 1

# keys, both settings under the [boot] the install's config has, and
# everything on the esp signed, then enrolled.
"$vm" ssh "pacman -S --noconfirm --needed --noprogressbar sbctl >/dev/null && sbctl create-keys >/dev/null"
"$vm" ssh "sed -i -e '/^\\[boot\\]/a secure_boot = true' -e '/^\\[boot\\]/a uki = true' /etc/yoq/machine.toml"
"$vm" ssh "/usr/local/bin/os update --yes" | tail -n 3
on_trial yes
"$vm" ssh "find /boot/EFI -iname '*.efi' -type f -exec sbctl sign -s {} \\; >/dev/null"
check "/usr/local/bin/os doctor | grep -c '^  ok  esp signatures: every efi file is signed\$'" 1
"$vm" ssh "sbctl enroll-keys --microsoft --yes-this-might-brick-my-machine >/dev/null"
check "$(efivar SetupMode)" 0

# the trial boot asks for the passphrase, and gets it late.
VM_ANSWER_DELAY=330 "$vm" reboot-answer "passphrase for" "correct horse battery"
settled
check "$(efivar SecureBoot)" 1
check "cryptsetup status root | head -n 1" "/dev/mapper/root is active and is in use."
check "ls /sys/firmware/efi/efivars | grep -c '^StubInfo-'" 1
check "journalctl -b -u yoq-health --no-pager -o cat | grep -c 'the default now'" 1
on_trial no
check "/usr/local/bin/os history | tail -n 1 | grep -c 'fell back' || true" 0
check "/usr/local/bin/os plan" "nothing to do. this machine matches its config."
check "/usr/local/bin/os doctor | grep -c '^  ok  firmware keys: sbctl.s db key is enrolled\$'" 1
check "/usr/local/bin/os doctor | grep -c '^warn  tpm key: doesn.t open the root now\$'" 1

# new keys the firmware doesn't have: os won't sign with them.
"$vm" ssh "mv /var/lib/sbctl /root/sbctl.enrolled && sbctl create-keys >/dev/null"
check "/usr/local/bin/os plan 2>&1 | grep -c 'error\\[E0137\\]'" 1
check "/usr/local/bin/os doctor | grep -c '^  no  firmware keys: sbctl.s db key isn.t enrolled\$'" 1
"$vm" ssh "rm -rf /var/lib/sbctl && mv /root/sbctl.enrolled /var/lib/sbctl"

# the tpm's key made again, as the docs say: the next boot is unattended.
"$vm" ssh "printf 'correct horse battery' > /root/luks-key && systemd-cryptenroll --unlock-key-file=/root/luks-key --wipe-slot=tpm2 --tpm2-device=auto $part >/dev/null; rm -f /root/luks-key"
check "/usr/local/bin/os doctor | grep -c '^  ok  tpm key: opens the root\$'" 1
"$vm" reboot
check "cryptsetup status root | head -n 1" "/dev/mapper/root is active and is in use."
check "$(efivar SecureBoot)" 1
settled

# without os, grub boots arch's kernel, which has to be signed then.
"$vm" ssh "sbctl sign -s /boot/vmlinuz-linux >/dev/null"
echo "secure boot on luks ok"
