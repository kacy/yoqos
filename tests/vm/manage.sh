#!/bin/sh
# a machine that can't have generations stays on the manage rung:
# enable-rollback names the check that fails ($1), and changes nothing.
# runs after the smoke test.
set -eu
. tests/vm/lib.sh

"$vm" ssh "/usr/local/bin/yos init >/dev/null 2>&1 || true"
check "/usr/local/bin/yos enable-rollback --yes >/tmp/out 2>&1; echo \$?" 1
check "grep -c '$1' /tmp/out" 1
check "test -e /var/lib/yos/generations && echo generations || echo none" none
check "/usr/local/bin/yos rollback --to-booted 2>&1 | grep -c 'no generations'" 1
# yos edit, through a terminal: a good edit is saved and committed, and a bad
# one that isn't edited again is put back.
"$vm" ssh "printf '#!/bin/sh\\necho \"# edited\" >> \"\$1\"\\n' > /root/good-edit && printf '#!/bin/sh\\necho \"bogus = 1\" >> \"\$1\"\\n' > /root/bad-edit && chmod +x /root/good-edit /root/bad-edit"
check "EDITOR=/root/good-edit script -qec '/usr/local/bin/yos edit --no-apply' /dev/null >/dev/null; git -C /etc/yos log -1 --format=%s" edit
check "tail -n 1 /etc/yos/machine.toml" "# edited"
check "echo n | EDITOR=/root/bad-edit script -qec '/usr/local/bin/yos edit --no-apply' /dev/null >/dev/null; grep -c bogus /etc/yos/machine.toml || true" 0
check "/usr/local/bin/yos edit 2>&1 | grep -c 'needs a terminal'" 1
# one yos changes the machine at a time: with the lock held elsewhere, an
# apply says so and stops.
"$vm" ssh "mkdir -p /run/yos && (setsid flock /run/yos/lock sleep 30 </dev/null >/dev/null 2>&1 &) ; sleep 1"
check "/usr/local/bin/yos apply --yes 2>&1 | grep -c 'is changing this machine'" 1
"$vm" ssh "sleep 30"
# a mkinitcpio drop-in yos writes rebuilds the initramfs once every file
# is in place: here it pulls in a marker file yos writes too.
"$vm" copy tests/vm/initramfs.toml /root/initramfs.toml
"$vm" ssh "cp /etc/yos/machine.toml /root/machine.toml.saved && cat /root/initramfs.toml >> /etc/yos/machine.toml && /usr/local/bin/yos apply --yes" | tail -n 2
check "lsinitcpio /boot/initramfs-linux.img | grep -c etc/yos-initramfs-marker" 1
# the drop-in changing again rebuilds it again, without the marker now.
"$vm" ssh "sed -i 's|^text = \"FILES+=.*|text = \"# nothing\\\\n\"|' /etc/yos/machine.toml && /usr/local/bin/yos apply --yes" | tail -n 2
check "lsinitcpio /boot/initramfs-linux.img | grep -c etc/yos-initramfs-marker" 0
# files taken out of the config stay, so they go by hand.
"$vm" ssh "cp /root/machine.toml.saved /etc/yos/machine.toml && rm /etc/mkinitcpio.conf.d/50-yos-test.conf /etc/yos-initramfs-marker"
check "/usr/local/bin/yos plan" "nothing to do. this machine matches its config."
# [firewall]: ufw lets in what the config allows, ssh here, and nothing
# else. a rule added with ufw shows in the plan, and the next apply drops it.
"$vm" ssh "printf '\\n[firewall]\\nbackend = \"ufw\"\\nallow = [\"22/tcp\", \"53/udp from 172.16.0.0/12 to 172.17.0.1\"]\\n' >> /etc/yos/machine.toml && /usr/local/bin/yos update --yes" | tail -n 3
check "systemctl is-active ufw.service" active
check "ufw status | grep -c ALLOW" 3
check "iptables -S ufw-user-input | grep -c -- '-s 172.16.0.0/12 -d 172.17.0.1/32 -p udp'" 1
check "/usr/local/bin/yos plan" "nothing to do. this machine matches its config."
"$vm" ssh "ufw allow 8080/tcp >/dev/null"
check "/usr/local/bin/yos plan | grep -c 'user.rules: rewrite'" 1
"$vm" ssh "/usr/local/bin/yos apply --yes" | tail -n 2
check "ufw status | grep -c 8080 || true" 0
# without [firewall], ufw goes and its files stay, as pacman leaves them.
"$vm" ssh "ufw disable >/dev/null && cp /root/machine.toml.saved /etc/yos/machine.toml && /usr/local/bin/yos update --yes" | tail -n 2
check "/usr/local/bin/yos plan" "nothing to do. this machine matches its config."
# a masked service is linked to /dev/null, and unmasked again when the
# config says so.
"$vm" ssh "printf '\\n[services.wait-online]\\nunit = \"systemd-networkd-wait-online.service\"\\npackage = \"systemd\"\\nmasked = true\\n' >> /etc/yos/machine.toml && /usr/local/bin/yos apply --yes" | tail -n 2
check "systemctl is-enabled systemd-networkd-wait-online.service || true" masked
check "/usr/local/bin/yos plan" "nothing to do. this machine matches its config."
"$vm" ssh "sed -i 's/^masked = true/enabled = false\\nmasked = false/' /etc/yos/machine.toml && /usr/local/bin/yos apply --yes" | tail -n 2
check "systemctl is-enabled systemd-networkd-wait-online.service | grep -c masked || true" 0
check "/usr/local/bin/yos plan" "nothing to do. this machine matches its config."
"$vm" ssh "cp /root/machine.toml.saved /etc/yos/machine.toml"
# leaving the manage rung takes only yos's state; the config stays.
check "/usr/local/bin/yos uninstall --yes >/dev/null; echo \$?" 0
check "test -e /var/lib/yos && echo state || echo none" none
check "test -f /etc/yos/machine.toml && echo config" config
echo "manage ok"
