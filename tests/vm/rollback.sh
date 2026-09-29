#!/bin/sh
# the rollback rung in a booted vm: enable-rollback, a reboot, and then a
# machine running generation 1 from its own subvolume, with /var apart.
# runs after the smoke test, in the same vm.
set -eu
. tests/vm/lib.sh

# a config in /etc/yoq first, so generation 1 has one to go back to.
today=$(date -u +%Y-%m-%d)
"$vm" ssh "/usr/local/bin/os init >/dev/null"
# the smoke test's own config left files os wrote that this one doesn't
# ask for; one apply settles them.
"$vm" ssh "/usr/local/bin/os apply --yes" | tail -n 2

# enable-rollback failing at its last step takes back every step before
# it: no subvolumes, the esp as it was, the machine as it was. the last
# step is grub-install for grub, and the menu for the others, where a
# command only it runs fails.
case $VM_LOADER in
grub) last=grub-install ;;
limine) last=sha256sum ;;
refind) last=install ;;
esac
esp=$("$vm" ssh "find $VM_ESP -type f -exec sha256sum {} + | sort | sha256sum")
"$vm" ssh "mkdir -p /tmp/fail && printf '#!/bin/sh\\necho not today >&2\\nexit 1\\n' > /tmp/fail/$last && chmod +x /tmp/fail/$last"
# it has to get that far, or there's nothing to take back.
check "PATH=/tmp/fail:\$PATH /usr/local/bin/os enable-rollback --yes >/tmp/enable.out 2>&1; echo \$?; grep -c 'not today' /tmp/enable.out" "1
1"
check_top "ls -d /run/yoq-top/@roots /run/yoq-top/@gens /run/yoq-top/@var 2>/dev/null | wc -l" 0
check "find $VM_ESP -type f -exec sha256sum {} + | sort | sha256sum" "$esp"
check "test -d /etc/yoq/.git && echo config here" "config here"
"$vm" reboot
check "findmnt -no FSROOT /" "$VM_ROOT"

root_mode=$("$vm" ssh "stat -c %a /root")
"$vm" ssh /usr/local/bin/os enable-rollback --yes
# until the reboot, changes would land on the root being left.
check "/usr/local/bin/os apply --yes 2>&1 | grep -c 'waiting for the next boot'" 1
"$vm" reboot

check "findmnt -no FSROOT /" /@roots/1
check "findmnt -no FSROOT /var" /@var
check "findmnt -no FSROOT /root" /@root
# the subvolume keeps the directory's mode: arch's /root is 0750.
check "stat -c %a /root" "$root_mode"
check "readlink /var/lib/pacman" /usr/lib/sysimage/pacman
check "findmnt -no FSTYPE $VM_ESP" vfat
check "findmnt -no FSROOT /etc/yoq" /@var/lib/yoq/config
check "git -C /etc/yoq log --format=%s -1" "init: yoq-test as found on $today"
check "pacman -Q pacman >/dev/null && echo pacman works" "pacman works"
check_top "btrfs property get -ts /run/yoq-top/@gens/1 ro" "ro=true"
"$vm" ssh "cat /var/lib/yoq/generations/1.json"
# a second run finds generations already there.
check "/usr/local/bin/os enable-rollback" "generations are on: this machine runs /@roots/1."

# an apply makes generation 2, and the menu keeps generation 1.
"$vm" ssh "/usr/local/bin/os add --yes tree" | tail -n 3
check "ls /var/lib/yoq/generations | tr '\\n' ' '" "1.json 2.json "
menu_generations 2

# generation 1, booted once from the menu: a fresh copy of it, from
# before tree.
boot_once 1
"$vm" reboot
check "findmnt -no FSROOT /" /@roots/boot-1
check "pacman -Q tree >/dev/null 2>&1 || echo no tree" "no tree"
boot_done

# and the next boot is the running generation again.
"$vm" reboot
check "findmnt -no FSROOT /" /@roots/1
check "pacman -Q tree >/dev/null && echo tree" tree

# a whole-root rollback: generation 1 again, as generation 3. a password
# changed since carries over: generation 1's would be the old one.
# data made since, in /root and /home, stays.
"$vm" ssh "echo root:carried-over | chpasswd"
hash=$("$vm" ssh "grep ^root: /etc/shadow | cut -d: -f2")
"$vm" ssh "echo kept > /root/after-2 && mkdir -p /home/someone && echo kept > /home/someone/after-2"
"$vm" ssh "/usr/local/bin/os rollback --yes"
"$vm" reboot
check "findmnt -no FSROOT /" /@roots/3
check "grep ^root: /etc/shadow | cut -d: -f2" "$hash"
check "cat /root/after-2 /home/someone/after-2" "kept
kept"
check "pacman -Q tree >/dev/null 2>&1 || echo no tree" "no tree"
# the config went back with it: no tree there either, and nothing to do.
check "grep -c tree /etc/yoq/machine.toml || true" 0
check "/usr/local/bin/os plan" "nothing to do. this machine matches its config."
"$vm" ssh "/usr/local/bin/os history"

# an older generation booted from the menu, and kept.
boot_once 2
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
check_top "ls /run/yoq-top/@gens /run/yoq-top/@roots | tr '\\n' ' '" "/run/yoq-top/@gens: 1 2 4  /run/yoq-top/@roots: 1 4 boot-1 boot-2 "
"$vm" ssh "/usr/local/bin/os history"

# refind can't boot a generation once, so a change that needs a reboot
# says how to go back by hand.
if [ "$VM_LOADER" = refind ]; then
    check "/usr/local/bin/os add --yes amd-ucode | grep -c 'pick generation'" 1
fi
echo "rollback ok"
