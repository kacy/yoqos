#!/bin/sh
# leaving: yos uninstall on a machine with generations leaves plain arch on
# the running root, and pacman and a reboot work the way they would
# without yos. runs last.
set -eu
. tests/vm/lib.sh

# no trial or rollback waiting.
"$vm" reboot
settled
running=$("$vm" ssh "findmnt -no FSROOT /")
check "/usr/local/bin/yos uninstall --yes --delete-generations >/tmp/out 2>&1; echo \$?" 0
"$vm" ssh "cat /tmp/out"
check "test -L /var/lib/pacman && echo link || echo dir" dir
check "findmnt /etc/yos >/dev/null && echo mounted || echo plain" plain
check "git -C /etc/yos log --format=%s -1 | grep -c ." 1
check "test -e /var/lib/yos && echo state || echo none" none
check "test -e $VM_ESP/yos && echo esp || echo none" none
check "ls /etc/systemd/system | grep -c -e yos-health -e yos-watchdog || true" 0
check_top "ls /run/yos-top/@roots | tr '\\n' ' '" "${running#/@roots/} "
check_top "test -e /run/yos-top/@gens && echo gens || echo none" none
# a second run finds nothing left to take back from generations.
check "/usr/local/bin/yos uninstall --yes >/dev/null 2>&1; echo \$?" 0

# nothing of yos's is left in the firmware: no default or one-shot naming
# an entry of yos's, and no boot entry for refind's trials.
check "for v in LoaderEntryDefault LoaderEntryOneShot; do f=\$(ls /sys/firmware/efi/efivars/\$v-* 2>/dev/null) && tail -c +5 \$f | tr -d '\\000'; echo; done | grep -c '^yos' || true" 0
check "efibootmgr 2>/dev/null | grep -c 'yos trial' || true" 0

# plain arch from here. the kernel changes twice, older with pacman -U and
# back with an upgrade, and each reboot goes into the same root, through
# the bootloader as yos left it, with the kernel pacman installed and its
# modules. pacman keeps working.
url=$(older linux)
[ -n "$url" ] || { echo "$name: no older linux in the archive"; exit 1; }
"$vm" ssh "pacman -U --noconfirm --noprogressbar $url >/dev/null"
"$vm" reboot
check "findmnt -no FSROOT /" "$running"
kernel_matches
before=$("$vm" ssh "uname -r")
"$vm" ssh "pacman -Syu --noconfirm --noprogressbar >/dev/null"
"$vm" reboot
check "findmnt -no FSROOT /" "$running"
check "test \"\$(uname -r)\" != $before && echo newer" newer
kernel_matches
check "pacman -Q pacman >/dev/null && echo pacman works" "pacman works"
check "test -e /var/lib/yos && echo state || echo none" none
echo "leave ok"
