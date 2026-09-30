#!/bin/sh
# a new machine: os install puts this machine's config on the vm's blank
# second disk, and the vm then boots that disk alone, as generation 1.
# runs last, since it leaves the vm running the new machine.
set -eu
. tests/vm/lib.sh

key=$(cat "${VM_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/yoq-vm}/key.pub")
"$vm" ssh "pacman -S --noconfirm --needed --noprogressbar dosfstools btrfs-progs grub >/dev/null"
"$vm" ssh "/usr/local/bin/os init >/dev/null 2>&1 || true"

# the config repository the new machine comes from: this machine's, less
# its aur packages, plus a way in over ssh for the test and a mkinitcpio
# drop-in, which the new machine's initramfs has to be built with.
cat > /tmp/yoq-access.toml <<TOML

[files."/root/.ssh/authorized_keys"]
text = "$key\n"
mode = "0600"
TOML
cat tests/vm/initramfs.toml >> /tmp/yoq-access.toml
"$vm" copy /tmp/yoq-access.toml /root/yoq-access.toml
"$vm" ssh "rm -rf /root/machines && cp -a /etc/yoq/. /root/machines && cd /root/machines && sed -i '/^aur = /d' machine.toml && cat /root/yoq-access.toml >> machine.toml && git add -A && git -c user.name=t -c user.email=t@localhost commit -q -m 'a way in for tests'"

# a partition isn't a disk, and nothing changes without a yes.
check "/usr/local/bin/os install /root/machines --disk /dev/vda1 --update 2>&1 | grep -c '^  no  disk'" 1
check "/usr/local/bin/os install /root/machines --disk /dev/vdb --update </dev/null >/dev/null 2>&1; echo \$?; lsblk -nro NAME /dev/vdb | wc -l" "2
1"
"$vm" ssh "/usr/local/bin/os install /root/machines --disk /dev/vdb --update --yes" | tail -n 20
serial_console /dev/vdb1

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
echo "install ok"
