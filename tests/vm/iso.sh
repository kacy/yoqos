#!/bin/sh
# gate g: yoq os's own live iso boots in a vm with a blank disk, installs a
# machine from a config repository onto it, and the vm then boots that
# disk alone.
# usage: tests/vm/iso.sh <path to the iso>
set -eu
. tests/vm/lib.sh

"$vm" start-iso "$1"
trap '"$vm" stop' EXIT
# the live system's keyring is made at boot.
"$vm" ssh "for i in \$(seq 60); do systemctl is-active -q pacman-init.service && exit 0; sleep 2; done; exit 1"
check "os version | grep -c ." 1
check "grep -c 'init --new' /etc/motd" 1

# a config for this empty machine, from nothing: os init --new on the live
# system, plus a way in over ssh for the test.
"$vm" ssh "os --config /root/machines/machine.toml init --new --hostname yoq-iso --user tester --timezone UTC --ssh"
key=$(cat "${VM_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/yoq-vm}/key.pub")
printf '\n[files."/root/.ssh/authorized_keys"]\ntext = "%s\\n"\nmode = "0600"\n' "$key" > /tmp/iso-access.toml
"$vm" copy /tmp/iso-access.toml /root/iso-access.toml
"$vm" ssh "cd /root/machines && cat /root/iso-access.toml >> machine.toml && git add -A && git -c user.name=t -c user.email=t@localhost commit -q -m 'a way in for the test'"

"$vm" ssh "os install /root/machines --disk /dev/vda --update --yes" | tail -n 20

"$vm" start-installed
check "cat /etc/hostname" yoq-iso
check "id -nG tester | tr ' ' '\\n' | grep -c '^wheel$'" 1
check "test -e /etc/sudoers.d/10-wheel && echo sudo" sudo
check "findmnt -no FSROOT /" /@roots/1
check "findmnt -no FSROOT /etc/yoq" /@var/lib/yoq/config
check "ls /var/lib/yoq/generations" 1.json
settled
"$vm" ssh "/usr/local/bin/os status" || true
check "/usr/local/bin/os plan" "nothing to do. this machine matches its config."
echo "iso ok"
