#!/bin/sh
# trial boots in a vm with generations: a change that needs a reboot boots
# once on trial, and becomes the default only if it comes up healthy.
# runs after rollback.sh, in the same vm.
set -eu
. tests/vm/lib.sh

# a healthy trial: microcode needs a reboot, so it's built into the next
# root, and the running system doesn't change until then.
# a user made in the same change gets a home on /home's subvolume, not in
# the directory under the new root it hides.
"$vm" ssh "printf '\\n[users.stagehome]\\nshell = \"bash\"\\n' >> /etc/yos/machine.toml"
"$vm" ssh "/usr/local/bin/yos add --yes amd-ucode" | tail -n 3
check "pacman -Q amd-ucode >/dev/null 2>&1 || echo not yet" "not yet"
# a change to the running system now stays behind, and status says so.
"$vm" ssh "echo made after staging > /etc/yos-after-staging"
check "$(status_report); grep -c 'changed since the next generation was built' /tmp/report" 1
show_env
# until that reboot, the machine can't hibernate: resuming would start the
# new kernel with the old one's memory.
check "grep -c AllowHibernation=no /run/systemd/sleep.conf.d/yos.conf" 1
"$vm" reboot
settled
# what the trial boot was, for when it isn't what the checks expect.
"$vm" ssh "findmnt -no FSROOT /; cat /proc/cmdline; journalctl -b -u yos-health --no-pager -o cat | tail -n 8; efibootmgr 2>/dev/null | head -n 3" || true
check "journalctl -b -u yos-health --no-pager -o cat | grep -c 'the default now'" 1
check "/usr/local/bin/yos events | grep '\"kind\":\"trial\"' | tail -n 1 | grep -c '\"step\":\"passed\"'" 1
on_trial no
check "test -e /run/systemd/sleep.conf.d/yos.conf && echo blocked || echo free" free
check "pacman -Q amd-ucode >/dev/null && echo installed" installed
check "stat -c %U /home/stagehome" stagehome
check "test -e /etc/yos-after-staging && echo came along || echo left behind" "left behind"
# a good boot puts its boot files where /boot is, the esp included.
check "test -e /boot/amd-ucode.img && echo there" there

# an unhealthy trial: a service the config turns on that only starts
# while a marker file exists. the trial boot runs without the marker.
"$vm" ssh "touch /etc/yos-flaky-ok && printf '[Unit]\\nDescription=flaky\\n[Service]\\nType=oneshot\\nRemainAfterExit=yes\\nExecStart=/usr/bin/test -e /etc/yos-flaky-ok\\n[Install]\\nWantedBy=multi-user.target\\n' > /etc/systemd/system/yos-flaky.service && systemctl daemon-reload"
"$vm" ssh "printf '\\n[services.flaky]\\nunit = \"yos-flaky.service\"\\npackage = \"pacman\"\\n' >> /etc/yos/machine.toml && /usr/local/bin/yos apply --yes" | tail -n 2
before=$(newest)
# the marker goes first, so the next root, a snapshot of this one, lacks it.
"$vm" ssh "rm /etc/yos-flaky-ok"
"$vm" ssh "/usr/local/bin/yos remove --yes amd-ucode" | tail -n 2
show_env
# the trial boot may answer before its health check reboots it, so this
# waits for the boot after: the generation before, from its copy, taken
# on as the newest generation with its config.
falls_back "$before"
on_trial no
check "$(status_report); grep -c '^note: generation' /tmp/report" 1
check "/usr/local/bin/yos events | grep '\"kind\":\"trial\"' | tail -n 1 | grep -c '\"step\":\"failed\"'" 1
check "/usr/local/bin/yos plan" "nothing to do. this machine matches its config."

# a trial boot that hangs before it's up: the watchdog reboots it, and the
# machine falls back the same way. first onto the generation just adopted.
"$vm" reboot
settled
# the hang goes in first, so the next root, a snapshot of this one, has it.
"$vm" ssh "printf '[Unit]\nDescription=hang\nBefore=multi-user.target\n[Service]\nType=oneshot\nTimeoutStartSec=infinity\nExecStart=/usr/bin/sleep infinity\n[Install]\nWantedBy=multi-user.target\n' > /etc/systemd/system/yos-hang.service && systemctl enable -q yos-hang.service"
"$vm" ssh "/usr/local/bin/yos add --yes intel-ucode" | tail -n 1
before=$(second_newest)
show_env
falls_back "$before"

# a trial whose kernel can't start: its initramfs is garbage, so the kernel
# panics, and panic=10 brings back the generation before.
"$vm" reboot
settled
"$vm" ssh "/usr/local/bin/yos add --yes intel-ucode" | tail -n 1
on_trial yes
before=$(second_newest)
break_trial_boot
show_env
falls_back "$before" "console:Kernel panic"
# a trial that comes up without a network, on a config that turns on
# networkmanager: it manages no devices there, so there's no default
# route, and the machine falls back to the generation before.
if "$vm" ssh "systemctl is-active -q NetworkManager.service"; then
    "$vm" reboot
    settled
    "$vm" ssh "printf '[keyfile]\\nunmanaged-devices=*\\n' > /etc/NetworkManager/conf.d/99-yos-test-off.conf"
    "$vm" ssh "/usr/local/bin/yos add --yes intel-ucode" | tail -n 1
    on_trial yes
    before=$(second_newest)
    show_env
    falls_back "$before"
    check "journalctl -b -1 -u yos-health --no-pager -o cat | grep -c 'no network'" 1
fi
# a trial only grub's env file names, as anything that can write the esp
# could plant, boots an older generation once, and rolls nothing back.
if [ "$VM_LOADER" = grub ]; then
    "$vm" reboot
    settled
    last=$(newest)
    # the generation the last fallback went to, which came up with its
    # network. the one just before the newest is the trial that failed,
    # without one, so ssh would never reach its boot.
    before=$("$vm" ssh "/usr/local/bin/yos history | grep 'fell back from' | tail -n 1 | sed 's/.* to \\([0-9]*\\).*/\\1/'")
    on_failure="grub-editenv $VM_ESP/yos/grubenv list; grep -e '^menuentry' -e '^set default' $VM_ESP/grub/grub.cfg"
    "$vm" ssh "grub-editenv $VM_ESP/yos/grubenv set yos_next=gen-$before yos_default=gen-$before yos_trial=$last yos_tried=1"
    # what grub boots next, for when that boot doesn't come up.
    "$vm" ssh "$on_failure"
    "$vm" reboot || true
    wait_root "/@roots/boot-$before"
    settled
    check "journalctl -b -u yos-health --no-pager -o cat | grep -c 'yos never armed one'" 1
    check "ls /var/lib/yos/generations | sort -n | tail -n 1 | cut -d. -f1" "$last"
    on_trial no
    on_failure=
fi
echo "trial ok"
