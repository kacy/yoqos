#!/bin/sh
# the rollback rung in a booted vm: enable-rollback, a reboot, and then a
# machine running generation 1 from its own subvolume, with /var apart.
# runs after the smoke test, in the same vm.
set -eu
vm=tests/vm/vm.sh

check() {
    got=$("$vm" ssh "$1")
    if [ "$got" != "$2" ]; then
        echo "rollback: $1 gave '$got', not '$2'"
        exit 1
    fi
    echo "ok: $1 -> $got"
}

# a config in /etc/yoq first, so generation 1 has one to go back to.
"$vm" ssh "/usr/local/bin/os init >/dev/null"

# enable-rollback failing at its last step, grub-install, takes back every
# step before it: no subvolumes, the esp as it was, the machine as it was.
esp=$("$vm" ssh "find /efi -type f -exec sha256sum {} + | sort | sha256sum")
"$vm" ssh "mkdir -p /tmp/fail && printf '#!/bin/sh\\necho no grub today >&2\\nexit 1\\n' > /tmp/fail/grub-install && chmod +x /tmp/fail/grub-install"
if "$vm" ssh "PATH=/tmp/fail:\$PATH /usr/local/bin/os enable-rollback --yes"; then echo "enable-rollback should have failed"; exit 1; fi
check "mkdir -p /run/yoq-check && mount -o subvolid=5 \$(findmnt -no SOURCE / | sed 's/\\[.*//') /run/yoq-check && ls -d /run/yoq-check/@* 2>/dev/null | wc -l; umount /run/yoq-check" 0
check "find /efi -type f -exec sha256sum {} + | sort | sha256sum" "$esp"
check "test -d /etc/yoq/.git && echo config here" "config here"
"$vm" reboot
check "findmnt -no FSROOT /" /

"$vm" ssh /usr/local/bin/os enable-rollback --yes
"$vm" reboot

check "findmnt -no FSROOT /" /@roots/1
check "findmnt -no FSROOT /var" /@var
check "readlink /var/lib/pacman" /usr/lib/sysimage/pacman
check "findmnt -no FSTYPE /efi" vfat
check "findmnt -no FSROOT /etc/yoq" /@var/lib/yoq/config
check "git -C /etc/yoq log --format=%s -1" "init: yoq-test as found on $(date -u +%Y-%m-%d)"
check "pacman -Q pacman >/dev/null && echo pacman works" "pacman works"
check "mkdir -p /run/yoq-check && mount -o subvolid=5 \$(findmnt -no SOURCE / | sed 's/\\[.*//') /run/yoq-check && btrfs property get -ts /run/yoq-check/@gens/1 ro" "ro=true"
"$vm" ssh "cat /var/lib/yoq/generations/1.json"
# a second run finds generations already there.
check "/usr/local/bin/os enable-rollback" "generations are on: this machine runs /@roots/1."

# an apply makes generation 2, and the menu keeps generation 1.
"$vm" ssh "/usr/local/bin/os add --yes tree" | tail -n 3
check "ls /var/lib/yoq/generations | tr '\\n' ' '" "1.json 2.json "
check "grep -c -e '--id head' -e '--id gen-1' /efi/grub/grub.cfg" 2

# generation 1, booted once from the menu: a fresh copy of it, from
# before tree.
"$vm" ssh "grub-editenv /efi/yoq/grubenv set yoq_next=gen-1"
"$vm" reboot
check "findmnt -no FSROOT /" /@roots/boot-1
check "pacman -Q tree >/dev/null 2>&1 || echo no tree" "no tree"

# and the next boot is the running generation again.
"$vm" reboot
check "findmnt -no FSROOT /" /@roots/1
check "pacman -Q tree >/dev/null && echo tree" tree

# a whole-root rollback: generation 1 again, as generation 3. a password
# changed since carries over: generation 1's would be the old one.
"$vm" ssh "echo root:carried-over | chpasswd"
hash=$("$vm" ssh "grep ^root: /etc/shadow | cut -d: -f2")
"$vm" ssh "/usr/local/bin/os rollback --yes"
"$vm" reboot
check "findmnt -no FSROOT /" /@roots/3
check "grep ^root: /etc/shadow | cut -d: -f2" "$hash"
check "pacman -Q tree >/dev/null 2>&1 || echo no tree" "no tree"
# the config went back with it: no tree there either, and nothing to do.
check "grep -c tree /etc/yoq/machine.toml || true" 0
check "/usr/local/bin/os plan" "nothing to do. this machine matches its config."
"$vm" ssh "/usr/local/bin/os history"

# an older generation booted from the menu, and kept.
"$vm" ssh "grub-editenv /efi/yoq/grubenv set yoq_next=gen-2"
"$vm" reboot
check "findmnt -no FSROOT /" /@roots/boot-2
"$vm" ssh "/usr/local/bin/os rollback --to-booted --yes"
"$vm" reboot
check "findmnt -no FSROOT /" /@roots/4
check "pacman -Q tree >/dev/null && echo tree" tree
check "grep -c tree /etc/yoq/machine.toml" 1
check "/usr/local/bin/os plan" "nothing to do. this machine matches its config."
"$vm" ssh "/usr/local/bin/os history"

# garbage collection: pinned, first, and newest stay; 3 goes, with its
# snapshot and the root nothing else uses.
"$vm" ssh "/usr/local/bin/os pin 2"
check "/usr/local/bin/os gc --keep 1" "removed generations: 3."
check "ls /var/lib/yoq/generations | tr '\\n' ' '" "1.json 2.json 4.json "
check "mkdir -p /run/yoq-gc && mount -o subvolid=5 \$(findmnt -no SOURCE / | sed 's/\\[.*//') /run/yoq-gc && ls /run/yoq-gc/@gens /run/yoq-gc/@roots | tr '\\n' ' '; umount /run/yoq-gc" "/run/yoq-gc/@gens: 1 2 4  /run/yoq-gc/@roots: 1 4 boot-1 boot-2 "
"$vm" ssh "/usr/local/bin/os history"
echo "rollback ok"
