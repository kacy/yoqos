#!/bin/sh
# [desktop] login in a vm with generations: a display manager changes at
# the next boot, on trial, and the health check wants it running. runs
# after trial.sh, in the same vm.
set -eu
. tests/vm/lib.sh

"$vm" reboot
settled
"$vm" ssh "printf '\\n[desktop]\\nlogin = \"greetd\"\\n' >> /etc/yoq/machine.toml && /usr/local/bin/os update --yes" | tail -n 3
# a display manager changes at the next boot: it's built into the next
# root, and this session keeps what it had.
check "systemctl is-enabled greetd.service 2>/dev/null || true" ""
on_trial yes
"$vm" reboot
settled
check "cat /etc/greetd/config.toml | grep -c tuigreet" 1
check "systemctl is-enabled greetd.service" enabled
check "systemctl is-active display-manager.service" active
check "journalctl -b -u yoq-health --no-pager -o cat | grep -c 'the default now'" 1

# a console login instead: nothing wants greetd now, so it's disabled and
# removed.
"$vm" ssh "sed -i 's/^login = \"greetd\"/login = \"tty\"/' /etc/yoq/machine.toml && /usr/local/bin/os update --yes" | tail -n 3
"$vm" reboot
settled
check "pacman -Q greetd >/dev/null 2>&1 || echo gone" gone
check "test -e /etc/systemd/system/display-manager.service || echo none" none
check "systemctl is-active greetd.service || true" inactive
check "/usr/local/bin/os plan" "nothing to do. this machine matches its config."
# a kernel module to load at boot, loaded right away too.
"$vm" ssh "printf '\n[boot]\nmodules = [\"i2c-dev\"]\n' >> /etc/yoq/machine.toml && /usr/local/bin/os apply --yes" | tail -n 2
check "lsmod | grep -c '^i2c_dev '" 1
check "cat /etc/modules-load.d/99-yoq.conf | tail -n 1" i2c-dev
echo "desktop ok"
