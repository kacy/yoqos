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
# yoq-health runs after boot; wait for it to be done.
settled() {
    "$vm" ssh "while [ \"\$(systemctl show -p ActiveState --value yoq-health)\" = activating ]; do sleep 2; done"
}
env() {
    "$vm" ssh "grub-editenv /efi/yoq/grubenv list | grep ^yoq_ | sort | tr '\\n' ' '"
}

# a healthy trial: microcode needs a reboot.
"$vm" ssh "/usr/local/bin/os add --yes amd-ucode" | tail -n 2
env
"$vm" reboot
settled
check "journalctl -b -u yoq-health --no-pager -o cat | grep -c 'came up healthy'" 1
check "grub-editenv /efi/yoq/grubenv list | grep -c -e ^yoq_trial -e ^yoq_default || true" 0

# an unhealthy trial: a service the config turns on that only starts
# while a marker file exists. the trial boot runs without the marker.
"$vm" ssh "touch /etc/yoq-flaky-ok && printf '[Unit]\\nDescription=flaky\\n[Service]\\nType=oneshot\\nRemainAfterExit=yes\\nExecStart=/usr/bin/test -e /etc/yoq-flaky-ok\\n[Install]\\nWantedBy=multi-user.target\\n' > /etc/systemd/system/yoq-flaky.service && systemctl daemon-reload"
"$vm" ssh "printf '\\n[services.flaky]\\nunit = \"yoq-flaky.service\"\\npackage = \"pacman\"\\n' >> /etc/yoq/machine.toml && /usr/local/bin/os apply --yes" | tail -n 2
before=$("$vm" ssh "ls /var/lib/yoq/generations | sort -n | tail -n 1 | cut -d. -f1")
"$vm" ssh "/usr/local/bin/os remove --yes amd-ucode" | tail -n 2
"$vm" ssh "rm /etc/yoq-flaky-ok"
env
"$vm" reboot
# the trial boot finds the service down and reboots; this is the boot after.
settled
check "findmnt -no FSROOT /" "/@roots/boot-$before"
echo "trial ok"
