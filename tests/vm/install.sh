#!/bin/sh
# a new machine: os install puts this machine's config on the vm's blank
# second disk, and the vm then boots that disk alone, as generation 1. the
# same config goes on the third disk too, inside luks2 that the vm's tpm
# unlocks, and that disk boots after, then turns secure boot on. runs
# last, since it leaves the vm running the new machines.
set -eu
. tests/vm/lib.sh

key=$(cat "${VM_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/yoq-vm}/key.pub")
"$vm" ssh "pacman -S --noconfirm --needed --noprogressbar dosfstools btrfs-progs grub >/dev/null"
"$vm" ssh "/usr/local/bin/os init >/dev/null 2>&1 || true"

# the config repository the new machine comes from: this machine's, less
# its aur packages, plus btrfs-progs, which this ext4 machine lacks and a
# btrfs one needs, a way in over ssh for the test, and a mkinitcpio
# drop-in, which the new machine's initramfs has to be built with.
cat > /tmp/yoq-access.toml <<TOML

[files."/root/.ssh/authorized_keys"]
text = "$key\n"
mode = "0600"
TOML
cat tests/vm/initramfs.toml >> /tmp/yoq-access.toml
"$vm" copy /tmp/yoq-access.toml /root/yoq-access.toml
"$vm" ssh "rm -rf /root/machines && cp -a /etc/yoq/. /root/machines && cd /root/machines && sed -i '/^aur = /d' machine.toml && { grep -q '\"btrfs-progs\"' imported.toml || sed -i 's/^packages = \\[/&\\n  \"btrfs-progs\",/' imported.toml; } && cat /root/yoq-access.toml >> machine.toml && git add -A && git -c user.name=t -c user.email=t@localhost commit -q -m 'a way in for tests'"

# a partition isn't a disk, and nothing changes without a yes.
check "/usr/local/bin/os install /root/machines --disk /dev/vda1 --update 2>&1 | grep -c '^  no  disk'" 1
check "/usr/local/bin/os install /root/machines --disk /dev/vdb --update </dev/null >/dev/null 2>&1; echo \$?; lsblk -nro NAME /dev/vdb | wc -l" "2
1"
# an --encrypt run that was cut off leaves its luks volume open, which
# holds the disk; an install without --encrypt closes it too.
"$vm" ssh "pacman -S --noconfirm --needed --noprogressbar cryptsetup tpm2-tss >/dev/null"
"$vm" ssh "printf x | cryptsetup luksFormat --batch-mode --pbkdf pbkdf2 --pbkdf-force-iterations 1000 --key-file=- /dev/vdb && printf x | cryptsetup open --key-file=- /dev/vdb yoq-install"
"$vm" ssh "/usr/local/bin/os install /root/machines --disk /dev/vdb --update --yes" | tail -n 20
check "test -e /dev/mapper/yoq-install && echo open || echo closed" closed
serial_console /dev/vdb1

# the encrypted one: the config sets the key the initramfs needs to unlock
# the root, and has tpm2-tss, which it unlocks with the tpm through. the
# passphrase file ends in a newline, which isn't part of the passphrase.
"$vm" ssh "rm -rf /root/sealed && cp -a /root/machines /root/sealed && cd /root/sealed && sed -i 's/^packages = \\[/&\\n  \"tpm2-tss\",/' imported.toml && printf '\\n[boot]\\nencrypt = true\\n' >> machine.toml && git add -A && git -c user.name=t -c user.email=t@localhost commit -q -m 'on luks, with the tpm'"
"$vm" ssh "printf 'correct horse battery\\n' > /root/luks-passphrase"
# without the key, the install stops before it changes anything.
check "/usr/local/bin/os install /root/machines --disk /dev/vdc --tpm --passphrase-file /root/luks-passphrase --yes 2>&1 | grep -c '^  no  encryption in the config'" 1
"$vm" ssh "/usr/local/bin/os install /root/sealed --disk /dev/vdc --update --tpm --passphrase-file /root/luks-passphrase --yes" | tail -n 20
check "cryptsetup isLuks --type luks2 /dev/vdc2 && echo luks2" luks2
check "cryptsetup luksDump /dev/vdc2 | grep -c 'systemd-tpm2'" 1
check "printf 'correct horse battery' | cryptsetup open --test-passphrase /dev/vdc2 && echo opens" opens
# if it's still open, what holds it: a mount in another namespace, a
# holder, a loop device, or gpg's daemons for the build's keyring.
on_failure='echo --- namespaces with it mounted; for f in $(grep -l yoq-install /proc/[0-9]*/mountinfo 2>/dev/null); do d=${f%/mountinfo}; echo "$d $(cat $d/comm 2>/dev/null)"; done; echo --- dmsetup; dmsetup info -c; echo --- holders; ls /sys/block/$(basename $(readlink -f /dev/mapper/yoq-install))/holders; echo --- mounts; findmnt -rno TARGET,SOURCE | grep -e yoq -e mapper; echo --- loop; losetup -a; echo --- gpg; ps -eo pid,comm,args | grep -e gpg -e keyboxd -e dirmngr | grep -v grep'
check "test -e /dev/mapper/yoq-install && echo open || echo closed" closed
on_failure=
serial_console /dev/vdc1

"$vm" start-installed
check "findmnt -no FSROOT /" /@roots/1
check "findmnt -no FSROOT /var" /@var
check "findmnt -no FSROOT /etc/yoq" /@var/lib/yoq/config
check "readlink /var/lib/pacman" /usr/lib/sysimage/pacman
check "ls /var/lib/yoq/generations" 1.json
check "lsinitcpio /boot/initramfs-linux.img | grep -c etc/yoq-initramfs-marker" 1
check "git -C /etc/yoq log --format=%s | grep -c 'a way in for tests'" 1
check "/usr/local/bin/os events | grep -c '\"kind\":\"install\",\"generation\":1,'" 1
settled
"$vm" ssh "/usr/local/bin/os status" || true
check "/usr/local/bin/os plan" "nothing to do. this machine matches its config."
# and it's a machine like any other with generations: a change is
# generation 2.
"$vm" ssh "/usr/local/bin/os add --yes tree" | tail -n 2
check "ls /var/lib/yoq/generations | tr '\\n' ' '" "1.json 2.json "

# the encrypted machine boots by itself: the tpm unlocks its root, which
# is the btrfs inside luks, opened as /dev/mapper/root.
"$vm" start-installed disk3
check "findmnt -no SOURCE / | sed 's/\\[.*//'" /dev/mapper/root
check "findmnt -no FSROOT /" /@roots/1
check "cryptsetup status root | head -n 1" "/dev/mapper/root is active and is in use."
check "grep -o 'rd.luks.options=tpm2-device=auto' /proc/cmdline" rd.luks.options=tpm2-device=auto
check "ls /var/lib/yoq/generations" 1.json
# sd-encrypt comes from os's drop-in, and nothing in crypttab opens the root.
check "test -e /etc/mkinitcpio.conf.d/90-yoq-encrypt.conf && echo there" there
check "lsinitcpio /boot/initramfs-linux.img | grep -c 'usr/lib/systemd/systemd-cryptsetup\$'" 1
check "cat /etc/crypttab 2>/dev/null | grep -c '^[^#[:space:]]' || true" 0
# the passphrase is nowhere on the new machine.
check "grep -rlsF 'correct horse battery' /etc /var/lib/yoq /var/log /root /boot | wc -l" 0
settled
"$vm" ssh "/usr/local/bin/os status" || true
check "/usr/local/bin/os doctor | grep -c '^  ok  luks: the root is /dev/mapper/root, from /dev/vda2'" 1
# the tpm unlocks it without secure boot: a warning, which fails nothing.
check "/usr/local/bin/os doctor | grep -c '^warn  tpm unlock: the tpm unlocks the root, and secure boot is off\$'" 1
check "/usr/local/bin/os plan" "nothing to do. this machine matches its config."
"$vm" reboot
check "cryptsetup status root | head -n 1" "/dev/mapper/root is active and is in use."
settled
# mkinitcpio counts some failures as errors without printing them. when
# a build fails here, a trace shows which call it counted.
on_failure='bash -x /usr/bin/mkinitcpio -k $(uname -r) -g /tmp/yoq-diag.img 2>&1 | grep -B12 -e "++_builderrors" | tail -n 60'
# with autodetect, which a running machine's builds use, sd-encrypt's
# initramfs builds without errors.
check "mkinitcpio -P >/tmp/yoq-mkinitcpio.log 2>&1 && echo built || tail -n 20 /tmp/yoq-mkinitcpio.log" built
# a change that needs a reboot: generation 2 is built beside the running
# one and boots once, on trial, from copies on the esp, since grub can't
# read the root. it unlocks on its own too, and passes.
"$vm" ssh "/usr/local/bin/os add --yes intel-ucode" | tail -n 25
check "ls /var/lib/yoq/generations | tr '\\n' ' '" "1.json 2.json "
on_failure=
check "grep -c -- '--set=root' /boot/grub/grub.cfg" 0
"$vm" reboot
settled
"$vm" ssh "findmnt -no FSROOT /; cat /proc/cmdline; journalctl -b -u yoq-health --no-pager -o cat | tail -n 8" || true
check "journalctl -b -u yoq-health --no-pager -o cat | grep -c 'the default now'" 1
check "/usr/local/bin/os events | grep '\"kind\":\"trial\"' | tail -n 1 | grep -c '\"step\":\"passed\"'" 1
on_trial no
check "pacman -Q intel-ucode >/dev/null && echo installed" installed
check "cryptsetup status root | head -n 1" "/dev/mapper/root is active and is in use."
# generation 1 stays in the menu, booting its copies on the esp.
check "grep -c 'linux (\${yoq_esp})/yoq/boot/' /boot/grub/grub.cfg" 1
check "/usr/local/bin/os plan" "nothing to do. this machine matches its config."
# secure boot on it: the tpm's key stops working until it's made again.
tests/vm/secureboot-luks.sh
# leaving: grub-mkconfig's menu takes what unlocks the root from grub's
# defaults, where os puts it, since only os's own entries had it.
check "/usr/local/bin/os uninstall --yes --delete-generations >/tmp/out 2>&1; echo \$?" 0
check "grep -c '^GRUB_CMDLINE_LINUX=.* rd.luks.name=' /etc/default/grub" 1
check "grep -c 'rd.luks.options=tpm2-device=auto' /boot/grub/grub.cfg | grep -c -v '^0\$'" 1
# the tpm still unlocks it, through grub and arch's own signed kernel. if
# it asks for the passphrase instead, it gets it, and pcr 7's events show
# what changed.
answered=$(VM_ANSWER_MAYBE=1 "$vm" reboot-answer "passphrase for" "correct horse battery")
if [ "$answered" = answered ]; then
    "$vm" ssh "/usr/lib/systemd/systemd-pcrlock log --pcr=7 2>&1 | tail -n 20; cryptsetup luksDump \$(cryptsetup status root | sed -n 's/^ *device: *//p') | sed -n '/^Tokens:/,/^Digests:/p'" || true
    echo "install: the tpm didn't unlock the root after uninstall"
    exit 1
fi
check "cryptsetup status root | head -n 1" "/dev/mapper/root is active and is in use."
check "test -e /var/lib/yoq && echo state || echo none" none
echo "install ok"
