#!/bin/sh
# trial boots in a vm with generations: a change that needs a reboot boots
# once on trial, and becomes the default only if it comes up healthy.
# runs after rollback.sh, in the same vm.
set -eu
vm=tests/vm/vm.sh

check() {
    got=$("$vm" ssh "$1")
    if [ "$got" != "$2" ]; then
        echo "trial: $1 gave '$got', not '$2'"
        exit 1
    fi
    echo "ok: $1 -> $got"
}
# yoq-health runs after boot; wait for it to be done, but not forever.
settled() {
    "$vm" ssh "for i in \$(seq 150); do [ \"\$(systemctl show -p ActiveState --value yoq-health)\" = activating ] || exit 0; sleep 2; done; echo 'yoq-health still running after 5 minutes'; exit 1"
}
env() {
    "$vm" ssh "grub-editenv $VM_ESP/yoq/grubenv list | grep ^yoq_ | sort | tr '\\n' ' '"
}

# a healthy trial: microcode needs a reboot.
"$vm" ssh "/usr/local/bin/os add --yes amd-ucode" | tail -n 2
env
"$vm" reboot
settled
check "journalctl -b -u yoq-health --no-pager -o cat | grep -c 'the default now'" 1
check "grub-editenv $VM_ESP/yoq/grubenv list | grep -c -e ^yoq_trial -e ^yoq_default || true" 0

# an unhealthy trial: a service the config turns on that only starts
# while a marker file exists. the trial boot runs without the marker.
"$vm" ssh "touch /etc/yoq-flaky-ok && printf '[Unit]\\nDescription=flaky\\n[Service]\\nType=oneshot\\nRemainAfterExit=yes\\nExecStart=/usr/bin/test -e /etc/yoq-flaky-ok\\n[Install]\\nWantedBy=multi-user.target\\n' > /etc/systemd/system/yoq-flaky.service && systemctl daemon-reload"
"$vm" ssh "printf '\\n[services.flaky]\\nunit = \"yoq-flaky.service\"\\npackage = \"pacman\"\\n' >> /etc/yoq/machine.toml && /usr/local/bin/os apply --yes" | tail -n 2
before=$("$vm" ssh "ls /var/lib/yoq/generations | sort -n | tail -n 1 | cut -d. -f1")
"$vm" ssh "/usr/local/bin/os remove --yes amd-ucode" | tail -n 2
"$vm" ssh "rm /etc/yoq-flaky-ok"
env
"$vm" reboot
# the trial boot may answer before its health check reboots it, so wait
# for the boot after: the generation before, from its copy.
for _ in $(seq 60); do
    root=$(timeout 20 "$vm" ssh "findmnt -no FSROOT /" 2>/dev/null || true)
    [ "$root" = "/@roots/boot-$before" ] && break
    sleep 5
done
check "findmnt -no FSROOT /" "/@roots/boot-$before"
# and os took the fallback on as the newest generation, with its config,
# and says what happened.
settled
check "/usr/local/bin/os history | tail -n 1 | grep -c 'fell back from'" 1
check "grub-editenv $VM_ESP/yoq/grubenv list | grep -c -e ^yoq_trial -e ^yoq_default || true" 0
check "/usr/local/bin/os status | grep -c '^note: generation'" 1
check "/usr/local/bin/os plan" "nothing to do. this machine matches its config."

# a trial boot that hangs before it's up: the watchdog reboots it, and the
# machine falls back the same way. first onto the generation just adopted.
"$vm" reboot
settled
"$vm" ssh "/usr/local/bin/os add --yes intel-ucode" | tail -n 1
before=$("$vm" ssh "ls /var/lib/yoq/generations | sort -n | tail -n 2 | head -n 1 | cut -d. -f1")
"$vm" ssh "printf '[Unit]\nDescription=hang\nBefore=multi-user.target\n[Service]\nType=oneshot\nTimeoutStartSec=infinity\nExecStart=/usr/bin/sleep infinity\n[Install]\nWantedBy=multi-user.target\n' > /etc/systemd/system/yoq-hang.service && systemctl enable -q yoq-hang.service"
env
"$vm" reboot || true
for _ in $(seq 60); do
    root=$(timeout 20 "$vm" ssh "findmnt -no FSROOT /" 2>/dev/null || true)
    [ "$root" = "/@roots/boot-$before" ] && break
    sleep 10
done
if [ "$root" != "/@roots/boot-$before" ]; then
    echo "trial: the hung trial boot didn't fall back; what it shows:"
    "$vm" ssh "cat /proc/cmdline; systemctl is-active yoq-watchdog.timer yoq-hang.service multi-user.target; systemctl list-timers --all --no-pager | grep -i yoq; journalctl -b -u yoq-watchdog.timer -u yoq-watchdog.service --no-pager -o cat | tail -n 5" || true
fi
check "findmnt -no FSROOT /" "/@roots/boot-$before"
settled
check "/usr/local/bin/os history | tail -n 1 | grep -c 'fell back from'" 1

# a trial whose kernel can't boot: no initramfs, so it can't mount its
# root. grub's fallback or panic=10 brings back the generation before.
"$vm" reboot
settled
"$vm" ssh "/usr/local/bin/os add --yes intel-ucode" | tail -n 1
check "grub-editenv $VM_ESP/yoq/grubenv list | grep -c ^yoq_trial" 1
before=$("$vm" ssh "ls /var/lib/yoq/generations | sort -n | tail -n 2 | head -n 1 | cut -d. -f1")
"$vm" ssh "mv /boot/initramfs-linux.img /boot/initramfs-linux.img.away"
env
"$vm" reboot || true
for _ in $(seq 60); do
    root=$(timeout 20 "$vm" ssh "findmnt -no FSROOT /" 2>/dev/null || true)
    [ "$root" = "/@roots/boot-$before" ] && break
    sleep 10
done
check "findmnt -no FSROOT /" "/@roots/boot-$before"
settled
check "/usr/local/bin/os history | tail -n 1 | grep -c 'fell back from'" 1
echo "trial ok"
