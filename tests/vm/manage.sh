#!/bin/sh
# a machine without btrfs stays on the manage rung: enable-rollback says
# why it can't, and changes nothing. runs after the smoke test.
set -eu
. tests/vm/lib.sh

"$vm" ssh "/usr/local/bin/os init >/dev/null 2>&1 || true"
check "/usr/local/bin/os enable-rollback --yes >/tmp/out 2>&1; echo \$?" 1
check "grep -c 'root filesystem: ext4' /tmp/out" 1
check "test -e /var/lib/yoq/generations && echo generations || echo none" none
check "/usr/local/bin/os rollback --to-booted 2>&1 | grep -c 'no generations'" 1
echo "manage ok"
