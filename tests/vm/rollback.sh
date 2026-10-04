#!/bin/sh
# the rollback rung in a booted vm: enable-rollback, a reboot, and then a
# machine running generation 1 from its own subvolume, with /var apart.
# runs after the smoke test, in the same vm.
set -eu
. tests/vm/lib.sh

# a config in /etc/yos first, so generation 1 has one to go back to.
today=$(date -u +%Y-%m-%d)
"$vm" ssh "/usr/local/bin/yos init >/dev/null"
# the smoke test's own config left files yos wrote that this one doesn't
# ask for; one apply settles them.
"$vm" ssh "/usr/local/bin/yos apply --yes" | tail -n 2

# enable-rollback failing at its last step takes back every step before
# it: no subvolumes, the esp as it was, the machine as it was. the last
# step is grub-install for grub, and the menu for the others, where a
# command only it runs fails.
case $VM_LOADER in
grub) last=grub-install ;;
limine | systemd-boot) last=sha256sum ;;
refind) last=install ;;
esac
# subvolumes nested in /var, like /var/lib/machines or docker's, one in
# another: the snapshot generation 1 comes from holds them only as empty
# directories, so they're moved over apart.
"$vm" ssh "btrfs subvolume create /var/lib/yos-nested >/dev/null && echo kept > /var/lib/yos-nested/f && btrfs subvolume create /var/lib/yos-nested/inner >/dev/null && echo deeper > /var/lib/yos-nested/inner/f"
esp=$("$vm" ssh "find $VM_ESP -type f -exec sha256sum {} + | sort | sha256sum")
default=$("$vm" ssh "btrfs subvolume get-default / | cut -d' ' -f2")
"$vm" ssh "mkdir -p /tmp/fail && printf '#!/bin/sh\\necho not today >&2\\nexit 1\\n' > /tmp/fail/$last && chmod +x /tmp/fail/$last"
# it has to get that far, or there's nothing to take back.
check "PATH=/tmp/fail:\$PATH /usr/local/bin/yos enable-rollback --yes >/tmp/enable.out 2>&1; echo \$?; grep -c 'not today' /tmp/enable.out" "1
1"
check_top "ls -d /run/yos-top/@roots /run/yos-top/@gens /run/yos-top/@var 2>/dev/null | wc -l" 0
check "find $VM_ESP -type f -exec sha256sum {} + | sort | sha256sum" "$esp"
check "btrfs subvolume get-default / | cut -d' ' -f2" "$default"
check "test -d /etc/yos/.git && echo config here" "config here"
"$vm" reboot
check "findmnt -no FSROOT /" "$VM_ROOT"

root_mode=$("$vm" ssh "stat -c %a /root")
"$vm" ssh /usr/local/bin/yos enable-rollback --yes
# grub reads each generation's files from the top level, so it's the
# default subvolume now, whatever snapper's rollback made it.
if [ "$VM_LOADER" = grub ]; then check "btrfs subvolume get-default / | cut -d' ' -f2" 5; fi
# until the reboot, changes would land on the root being left.
check "/usr/local/bin/yos apply --yes 2>&1 | grep -c 'waiting for the next boot'" 1
# and so would a second enable-rollback.
check "/usr/local/bin/yos enable-rollback --yes 2>&1 | grep -c 'waiting for the next boot'" 1
"$vm" reboot

check "findmnt -no FSROOT /" /@roots/1
check "findmnt -no FSROOT /var" /@var
check "findmnt -no FSROOT /root" /@root
# the subvolume keeps the directory's mode: arch's /root is 0750.
check "stat -c %a /root" "$root_mode"
check "readlink /var/lib/pacman" /usr/lib/sysimage/pacman
check "cat /var/lib/yos-nested/f /var/lib/yos-nested/inner/f | tr '\\n' ' '" "kept deeper "
check "btrfs subvolume show /var/lib/yos-nested/inner >/dev/null && echo subvolume" subvolume
check "findmnt -no FSTYPE $VM_ESP" vfat
check "findmnt -no FSROOT /etc/yos" /@var/lib/yos/config
check "git -C /etc/yos log --format=%s -1" "init: yos-test as found on $today"
check "pacman -Q pacman >/dev/null && echo pacman works" "pacman works"
check_top "btrfs property get -ts /run/yos-top/@gens/1 ro" "ro=true"
"$vm" ssh "cat /var/lib/yos/generations/1.json"
# a second run finds generations already there.
check "/usr/local/bin/yos enable-rollback" "generations are on: this machine runs /@roots/1."
# the run that failed and was taken back left no event; this one did, in
# the /var this boot mounted.
check "/usr/local/bin/yos events | grep -c '\"kind\":\"enable-rollback\",\"step\":\"done\",\"generation\":1}'" 1

# an apply makes generation 2, and the menu keeps generation 1.
"$vm" ssh "/usr/local/bin/yos add --yes tree" | tail -n 3
check "ls /var/lib/yos/generations | tr '\\n' ' '" "1.json 2.json "
menu_generations 2
check "/usr/local/bin/yos events | grep -c '\"kind\":\"generation\",\"generation\":2,'" 1
# what changed between them, and a doctor that finds the menu in place.
check "/usr/local/bin/yos diff 1 2 | grep -c '^  + tree '" 1
check "/usr/local/bin/yos doctor | grep -c '^  ok  boot menu'" 1
# a menu another tool rewrote: status says so, and gc puts it back.
drop_menu
check "/usr/local/bin/yos status | grep -c 'boot menu without'" 1
check "/usr/local/bin/yos gc | grep -c 'wrote the boot menu'" 1
menu_generations 2
check "/usr/local/bin/yos status | grep -c 'boot menu without' || true" 0
# copies on the esp that went by hand come back at gc, with nothing to
# remove.
case $VM_LOADER in
limine | systemd-boot)
    "$vm" ssh "rm -f $VM_ESP/yos/boot/*"
    check "/usr/local/bin/yos gc | grep -c 'nothing to remove'" 1
    check "ls $VM_ESP/yos/boot | grep -c . | grep -c '^[1-9]'" 1
    ;;
*) ;;
esac

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
"$vm" ssh "echo kept > /root/after-2 && mkdir -p /home/someone && echo kept > /home/someone/after-2"
"$vm" ssh "/usr/local/bin/yos rollback --yes"
check "/usr/local/bin/yos events | grep -c '\"kind\":\"rollback\",\"generation\":1}'" 1
# and one changed after the rollback, before the reboot, is carried at
# shutdown.
"$vm" ssh "echo root:changed-at-the-last-minute | chpasswd"
hash=$("$vm" ssh "grep ^root: /etc/shadow | cut -d: -f2")
"$vm" reboot
check "findmnt -no FSROOT /" /@roots/3
check "grep ^root: /etc/shadow | cut -d: -f2" "$hash"
check "cat /root/after-2 /home/someone/after-2" "kept
kept"
check "pacman -Q tree >/dev/null 2>&1 || echo no tree" "no tree"
# the config went back with it: no tree there either, and nothing to do.
check "grep -c tree /etc/yos/machine.toml || true" 0
check "/usr/local/bin/yos plan" "nothing to do. this machine matches its config."
"$vm" ssh "/usr/local/bin/yos history"

# an older generation booted from the menu, and kept.
boot_once 2
"$vm" reboot
check "findmnt -no FSROOT /" /@roots/boot-2
"$vm" ssh "/usr/local/bin/yos rollback --to-booted --yes"
"$vm" reboot
check "findmnt -no FSROOT /" /@roots/4
check "pacman -Q tree >/dev/null && echo tree" tree
check "grep -c tree /etc/yos/machine.toml" 1
check "/usr/local/bin/yos plan" "nothing to do. this machine matches its config."
"$vm" ssh "/usr/local/bin/yos history"

# garbage collection: pinned, first, and newest stay; 3 goes, with its
# snapshot and the root nothing else uses.
"$vm" ssh "/usr/local/bin/yos pin 2"
check "/usr/local/bin/yos events | grep '\"kind\":\"pin\"' | tail -n 1 | grep -c '\"step\":\"pinned\",\"generation\":2}'" 1
check "/usr/local/bin/yos gc --keep 1" "removed generations: 3."
check "/usr/local/bin/yos events | grep '\"kind\":\"gc\"' | tail -n 1 | grep -c '\"generations\":\[3\]}'" 1
check "ls /var/lib/yos/generations | tr '\\n' ' '" "1.json 2.json 4.json "
check_top "ls /run/yos-top/@gens /run/yos-top/@roots | tr '\\n' ' '" "/run/yos-top/@gens: 1 2 4  /run/yos-top/@roots: 1 4 boot-1 boot-2 "
"$vm" ssh "/usr/local/bin/yos history"

echo "rollback ok"
