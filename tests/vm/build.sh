#!/bin/sh
# a clean build: the config and the lock alone, installed into an empty
# directory, give the same packages and the same files os writes as the
# machine they came from. runs after the smoke test.
set -eu
. tests/vm/lib.sh

"$vm" ssh "/usr/local/bin/os init >/dev/null 2>&1 || true"
"$vm" ssh "/usr/local/bin/os apply --yes" | tail -n 1
"$vm" ssh "/usr/local/bin/os build --clean /var/tmp/clean >/tmp/build.out 2>&1; echo \$? >/tmp/build.rc; tail -n 40 /tmp/build.out"
check "cat /tmp/build.rc" 0
check "pacman -r /var/tmp/clean -Q | sha256sum" "$("$vm" ssh "pacman -Q | sha256sum")"
check "cmp /etc/hostname /var/tmp/clean/etc/hostname && echo same" same
check "cmp /etc/locale.conf /var/tmp/clean/etc/locale.conf && echo same" same
# nothing stays mounted in it, and a second build won't start over it.
"$vm" ssh "findmnt -rn -o TARGET,SOURCE,FSTYPE | grep /var/tmp/clean || true; sleep 5"
check "findmnt -rn -o TARGET | grep -c /var/tmp/clean || true" 0
check "/usr/local/bin/os build --clean /var/tmp/clean 2>&1 | grep -c 'can.t make /var/tmp/clean'" 1
"$vm" ssh "rm -rf /var/tmp/clean"
echo "build ok"
