#!/bin/sh
# trial boots in a vm with generations: a change that needs a reboot boots
# once on trial, and becomes the default only if it comes up healthy.
# runs after rollback.sh, in the same vm.
set -eu
. tests/vm/lib.sh

# a healthy trial: microcode needs a reboot, so it's built into the next
# root, and the running system doesn't change until then.
"$vm" ssh "/usr/local/bin/os add --yes amd-ucode" | tail -n 3
check "pacman -Q amd-ucode >/dev/null 2>&1 || echo not yet" "not yet"
show_env
# until that reboot, the machine can't hibernate: resuming would start the
# new kernel with the old one's memory.
check "grep -c AllowHibernation=no /run/systemd/sleep.conf.d/yoq.conf" 1
"$vm" reboot
settled
# what the trial boot was, for when it isn't what the checks expect.
"$vm" ssh "findmnt -no FSROOT /; cat /proc/cmdline; journalctl -b -u yoq-health --no-pager -o cat | tail -n 8; efibootmgr 2>/dev/null | head -n 3" || true
check "journalctl -b -u yoq-health --no-pager -o cat | grep -c 'the default now'" 1
on_trial no
check "test -e /run/systemd/sleep.conf.d/yoq.conf && echo blocked || echo free" free
check "pacman -Q amd-ucode >/dev/null && echo installed" installed
# a good boot puts its boot files where /boot is, the esp included.
check "test -e /boot/amd-ucode.img && echo there" there

# an unhealthy trial: a service the config turns on that only starts
# while a marker file exists. the trial boot runs without the marker.
"$vm" ssh "touch /etc/yoq-flaky-ok && printf '[Unit]\\nDescription=flaky\\n[Service]\\nType=oneshot\\nRemainAfterExit=yes\\nExecStart=/usr/bin/test -e /etc/yoq-flaky-ok\\n[Install]\\nWantedBy=multi-user.target\\n' > /etc/systemd/system/yoq-flaky.service && systemctl daemon-reload"
"$vm" ssh "printf '\\n[services.flaky]\\nunit = \"yoq-flaky.service\"\\npackage = \"pacman\"\\n' >> /etc/yoq/machine.toml && /usr/local/bin/os apply --yes" | tail -n 2
before=$(newest)
# the marker goes first, so the next root, a snapshot of this one, lacks it.
"$vm" ssh "rm /etc/yoq-flaky-ok"
"$vm" ssh "/usr/local/bin/os remove --yes amd-ucode" | tail -n 2
show_env
# the trial boot may answer before its health check reboots it, so this
# waits for the boot after: the generation before, from its copy, taken
# on as the newest generation with its config.
falls_back "$before"
on_trial no
check "/usr/local/bin/os status | grep -c '^note: generation'" 1
check "/usr/local/bin/os plan" "nothing to do. this machine matches its config."

# a trial boot that hangs before it's up: the watchdog reboots it, and the
# machine falls back the same way. first onto the generation just adopted.
"$vm" reboot
settled
# the hang goes in first, so the next root, a snapshot of this one, has it.
"$vm" ssh "printf '[Unit]\nDescription=hang\nBefore=multi-user.target\n[Service]\nType=oneshot\nTimeoutStartSec=infinity\nExecStart=/usr/bin/sleep infinity\n[Install]\nWantedBy=multi-user.target\n' > /etc/systemd/system/yoq-hang.service && systemctl enable -q yoq-hang.service"
"$vm" ssh "/usr/local/bin/os add --yes intel-ucode" | tail -n 1
before=$(second_newest)
show_env
falls_back "$before"

# a trial whose kernel can't start: its initramfs is garbage, so the kernel
# panics, and panic=10 brings back the generation before.
"$vm" reboot
settled
"$vm" ssh "/usr/local/bin/os add --yes intel-ucode" | tail -n 1
on_trial yes
before=$(second_newest)
break_trial_boot
show_env
falls_back "$before"
# a trial that comes up without a network, on a config that turns on
# networkmanager: it manages no devices there, so there's no default
# route, and the machine falls back to the generation before.
if "$vm" ssh "systemctl is-active -q NetworkManager.service"; then
    "$vm" reboot
    settled
    "$vm" ssh "printf '[keyfile]\\nunmanaged-devices=*\\n' > /etc/NetworkManager/conf.d/99-yoq-test-off.conf"
    "$vm" ssh "/usr/local/bin/os add --yes intel-ucode" | tail -n 1
    on_trial yes
    before=$(second_newest)
    show_env
    falls_back "$before"
    check "journalctl -b -1 -u yoq-health --no-pager -o cat | grep -c 'no network'" 1
fi
echo "trial ok"
