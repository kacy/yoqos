#!/bin/sh
# leaving: os uninstall on a machine with generations leaves plain arch on
# the running root, and pacman and a reboot work the way they would
# without os. runs last.
set -eu
. tests/vm/lib.sh

# no trial or rollback waiting.
"$vm" reboot
settled
running=$("$vm" ssh "findmnt -no FSROOT /")
check "/usr/local/bin/os uninstall --yes --delete-generations >/tmp/out 2>&1; echo \$?" 0
"$vm" ssh "cat /tmp/out"
check "test -L /var/lib/pacman && echo link || echo dir" dir
check "findmnt /etc/yoq >/dev/null && echo mounted || echo plain" plain
check "git -C /etc/yoq log --format=%s -1 | grep -c ." 1
check "test -e /var/lib/yoq && echo state || echo none" none
check "test -e $VM_ESP/yoq && echo esp || echo none" none
check "ls /etc/systemd/system | grep -c -e yoq-health -e yoq-watchdog || true" 0
check_top "ls /run/yoq-top/@roots | tr '\\n' ' '" "${running#/@roots/} "
check_top "test -e /run/yoq-top/@gens && echo gens || echo none" none
# a second run finds nothing left to take back from generations.
check "/usr/local/bin/os uninstall --yes >/dev/null 2>&1; echo \$?" 0

# plain arch from here: an upgrade, a reboot into the same root, and
# pacman still working.
"$vm" ssh "pacman -Syu --noconfirm --noprogressbar >/dev/null"
"$vm" reboot
check "findmnt -no FSROOT /" "$running"
check "pacman -Q pacman >/dev/null && echo pacman works" "pacman works"
check "test -e /var/lib/yoq && echo state || echo none" none
echo "leave ok"
