#!/bin/sh
# the rollback rung in a booted vm: enable-rollback, a reboot, and then a
# machine running generation 1 from its own subvolume, with /var apart.
# runs after the smoke test, in the same vm.
set -eu
vm=tests/vm/vm.sh

"$vm" ssh /usr/local/bin/os enable-rollback --yes
"$vm" reboot

check() {
    got=$("$vm" ssh "$1")
    if [ "$got" != "$2" ]; then
        echo "rollback: $1 gave '$got', not '$2'"
        exit 1
    fi
    echo "ok: $1 -> $got"
}
check "findmnt -no FSROOT /" /@roots/1
check "findmnt -no FSROOT /var" /@var
check "readlink /var/lib/pacman" /usr/lib/sysimage/pacman
check "findmnt -no FSTYPE /efi" vfat
check "pacman -Q pacman >/dev/null && echo pacman works" "pacman works"
check "mkdir -p /run/yoq-check && mount -o subvolid=5 \$(findmnt -no SOURCE / | sed 's/\\[.*//') /run/yoq-check && btrfs property get -ts /run/yoq-check/@gens/1 ro" "ro=true"
"$vm" ssh "cat /var/lib/yoq/generations/1.json"
# a second run finds generations already there.
check "/usr/local/bin/os enable-rollback" "generations are on: this machine runs /@roots/1."
echo "rollback ok"
