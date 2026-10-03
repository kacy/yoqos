#!/bin/sh
# failures made on purpose: each one checks that os stops cleanly with the
# machine as it was, or finishes the job the next time, and then puts back
# what it broke, so later scripts in the vm still work. the arguments pick
# which run:
#
#   crash     the power goes during a live apply
#   committed the power goes after a live apply's transaction, before os
#             records it as done
#   download  no network during an apply and an update
#   disk      the disk fills up while the next generation builds
#   esp       a new generation's boot files don't fit on the esp, where
#             limine and systemd-boot need copies of them
#   restore   with grub and the esp at /boot, a rolled-back generation's
#             boot files don't fit on the esp
#   trial     the power goes while a trial is set up, while one that
#             passed is made the default, and while a fallback ends one
#
# runs after the smoke test; on a machine with generations, after
# rollback.sh. disk, esp, restore, and trial need generations.
set -eu
. tests/vm/lib.sh

os=/usr/local/bin/os
empty="nothing to do. this machine matches its config."
"$vm" ssh "$os init >/dev/null 2>&1 || true"
generations=$("$vm" ssh "test -d /var/lib/yoq/generations && echo yes || echo no")
newest_cmd="ls /var/lib/yoq/generations 2>/dev/null | sort -n | tail -n 1 | cut -d. -f1"
# the journal's last apply line. os's other events, like commits and
# generations, go in the journal too, with a kind instead of an event.
last_apply="grep '\"event\":' /var/lib/yoq/journal | tail -n 1"
if [ "$generations" = yes ]; then
    # a boot of a menu copy, or a trial that fell back, takes no changes
    # until the machine runs its newest generation.
    "$vm" reboot
    settled
    menu_cmd=$(menu_count)
else
    menu_cmd="echo none"
fi
# the scripts before can leave the lock ahead of the machine.
"$vm" ssh "$os apply --yes" | tail -n 1
check "$os plan" "$empty"
# when a check fails, what os printed last and what the journal says.
on_failure="echo '--- /tmp/out'; cat /tmp/out 2>/dev/null; echo '--- journal'; tail -n 5 /var/lib/yoq/journal 2>/dev/null"

# the btrfs top level's @roots, listed.
roots() {
    "$vm" ssh "mkdir -p /run/yoq-top && mount -o subvolid=5 \$(findmnt -no SOURCE / | sed 's/\\[.*//') /run/yoq-top && ls /run/yoq-top/@roots | tr '\\n' ' '; umount /run/yoq-top"
}

# fails unless @roots is what it was, $1: a failed build leaves nothing.
same_roots() {
    got=$(roots)
    if [ "$got" != "$1" ]; then
        echo "$name: @roots was '$1' before, and '$got' after"
        "$vm" ssh "$on_failure" || true
        exit 1
    fi
}

# a microcode package this machine doesn't have. adding one needs a
# reboot, so the change is staged.
ucode() {
    "$vm" ssh "for p in intel-ucode amd-ucode; do pacman -Q \$p >/dev/null 2>&1 || { echo \$p; exit 0; }; done; exit 1" || {
        echo "$name: both microcode packages are installed already" >&2
        exit 1
    }
}

# routes that make everything past the vm's own subnet unreachable. ssh
# and dns come from that subnet, so they keep working.
offline() {
    "$vm" ssh "ip route add unreachable 0.0.0.0/1 && ip route add unreachable 128.0.0.0/1 && { ip -6 route add unreachable ::/1 && ip -6 route add unreachable 8000::/1 || true; }"
}

online() {
    "$vm" ssh "ip route del unreachable 0.0.0.0/1; ip route del unreachable 128.0.0.0/1; ip -6 route del unreachable ::/1; ip -6 route del unreachable 8000::/1; true" 2>/dev/null
}

# the power goes after sl has downloaded and pacman's lock is taken, but
# before anything is installed: a pacman hook pulls the plug. the next
# apply notices the journal's unfinished run, clears the stale lock, and
# finishes the job.
crash_apply() {
    "$vm" ssh "$os add --no-apply sl" | tail -n 1
    check "grep -cF '[packages.sl]' /etc/yoq/machine.lock" 1
    # the hook takes itself out first, so the next boot's apply goes
    # through. sync stands in for a disk that kept what was written
    # before the power went.
    "$vm" ssh "mkdir -p /etc/pacman.d/hooks && printf '#!/bin/sh\\nrm -f /etc/pacman.d/hooks/00-yoq-power-loss.hook\\nsync\\necho b > /proc/sysrq-trigger\\n' > /root/power-loss && chmod +x /root/power-loss && printf '[Trigger]\\nOperation = Install\\nType = Package\\nTarget = sl\\n\\n[Action]\\nDescription = losing power\\nWhen = PreTransaction\\nExec = /root/power-loss\\n' > /etc/pacman.d/hooks/00-yoq-power-loss.hook && sync"
    before=$("$vm" ssh "$newest_cmd")
    menu=$("$vm" ssh "$menu_cmd")
    crash "$os apply --yes"
    if [ "$generations" = yes ]; then settled; fi
    check "test -e /var/lib/pacman/db.lck && echo locked" locked
    check "pacman -Q sl >/dev/null 2>&1 || echo not yet" "not yet"
    check "$last_apply | grep -c '\"event\":\"begin\"'" 1
    # the menu still boots the generation from before the apply.
    check "$newest_cmd" "$before"
    check "$menu_cmd" "$menu"
    check "$os apply --yes 2>&1 | grep -c -e 'the last apply .* didn.t finish' -e 'left from before this boot'" 2
    check "pacman -Q sl >/dev/null && echo installed" installed
    check "$last_apply | grep -c '\"event\":\"done\"'" 1
    check "$os plan" "$empty"
    if [ "$generations" = yes ]; then check "test \$($newest_cmd) -gt $before && echo recorded" recorded; fi
    "$vm" ssh "$os remove --yes sl" | tail -n 1
    check "$os plan" "$empty"
}

# the power goes once pacman has installed sl, before os writes "done" in
# the journal: a PostTransaction hook pulls the plug. the next apply finds
# nothing to do, so it records the cut-off apply as done, and on a machine
# with generations, records the generation that apply never got to.
crash_committed() {
    "$vm" ssh "$os add --no-apply sl" | tail -n 1
    check "grep -cF '[packages.sl]' /etc/yoq/machine.lock" 1
    "$vm" ssh "mkdir -p /etc/pacman.d/hooks && printf '#!/bin/sh\\nrm -f /etc/pacman.d/hooks/00-yoq-power-loss.hook\\nsync\\necho b > /proc/sysrq-trigger\\n' > /root/power-loss && chmod +x /root/power-loss && printf '[Trigger]\\nOperation = Install\\nType = Package\\nTarget = sl\\n\\n[Action]\\nDescription = losing power\\nWhen = PostTransaction\\nExec = /root/power-loss\\n' > /etc/pacman.d/hooks/00-yoq-power-loss.hook && sync"
    before=$("$vm" ssh "$newest_cmd")
    crash "$os apply --yes"
    if [ "$generations" = yes ]; then settled; fi
    check "pacman -Qq sl" sl
    check "$last_apply | grep -c '\"event\":\"begin\"'" 1
    check "$newest_cmd" "$before"
    check "$os apply --yes >/tmp/out 2>&1; echo \$?" 0
    check "grep -c 'was cut off after it made its changes. the machine matches the config, so it.s recorded as done' /tmp/out" 1
    check "grep -c 'didn.t finish' /tmp/out || true" 0
    check "test -e /var/lib/pacman/db.lck && echo locked || echo clear" clear
    check "$last_apply | grep -c '\"event\":\"done\"'" 1
    if [ "$generations" = yes ]; then
        check "test \$($newest_cmd) -gt $before && echo recorded" recorded
        check "grep -c '\"reason\":\"apply\"' /var/lib/yoq/generations/\$($newest_cmd).json" 1
    fi
    # settled: the next apply has nothing to say, and records nothing.
    after=$("$vm" ssh "$newest_cmd")
    check "$os apply --yes 2>&1" "$empty"
    check "$newest_cmd" "$after"
    check "$os plan" "$empty"
    "$vm" ssh "$os remove --yes sl" | tail -n 1
    check "$os plan" "$empty"
}

# no network: an apply can't download figlet, and an update can't fetch
# today's databases. neither changes the machine, the lock, the config's
# history, or the generations, and both say why.
download() {
    "$vm" ssh "$os add --no-apply figlet" | tail -n 1
    check "grep -cF '[packages.figlet]' /etc/yoq/machine.lock" 1
    "$vm" ssh "rm -f /var/cache/yoq/pkg/figlet-*"
    before=$("$vm" ssh "$newest_cmd")
    menu=$("$vm" ssh "$menu_cmd")
    offline
    check "$os apply --yes >/tmp/out 2>&1; echo \$?" 1
    "$vm" ssh "tail -n 4 /tmp/out"
    check "grep -q 'failed to retrieve some files' /tmp/out && echo named" named
    check "pacman -Q figlet >/dev/null 2>&1 || echo not installed" "not installed"
    check "$last_apply | grep -c '\"event\":\"failed\"'" 1
    check "$newest_cmd" "$before"
    check "$menu_cmd" "$menu"

    # today's databases, if they're cached, go aside so the update has to
    # fetch them.
    today=$("$vm" ssh "date -u +%F")
    lock=$("$vm" ssh "sha256sum < /etc/yoq/machine.lock")
    commits=$("$vm" ssh "git -C /etc/yoq rev-list --count HEAD")
    "$vm" ssh "cd /var/cache/yoq/sync && if [ -d $today ]; then mv $today $today.aside; fi"
    check "$os update --yes >/tmp/out 2>&1; echo \$?" 1
    "$vm" ssh "tail -n 4 /tmp/out"
    check "grep -c 'can.t download the core database from any server' /tmp/out" 1
    check "sha256sum < /etc/yoq/machine.lock" "$lock"
    check "git -C /etc/yoq rev-list --count HEAD" "$commits"
    check "$newest_cmd" "$before"
    online
    "$vm" ssh "cd /var/cache/yoq/sync && if [ -d $today.aside ]; then rm -rf $today && mv $today.aside $today; fi"
    "$vm" ssh "$os remove --yes figlet" | tail -n 1
    check "$os plan" "$empty"
}

# the disk fills up, then a change that needs a reboot builds the next
# generation beside the running system. the build fails, says the disk is
# full, and leaves no half-built root behind.
disk_full() {
    pkg=$(ucode)
    # the config changes first: its files are on the same filesystem.
    "$vm" ssh "$os add --no-apply $pkg" | tail -n 1
    before=$("$vm" ssh "$newest_cmd")
    menu=$("$vm" ssh "$menu_cmd")
    was=$(roots)
    # preallocated, so compression can't make room.
    "$vm" ssh "avail=\$(df --output=avail -B1M /var | tail -n 1); fallocate -l \$((avail - 64))M /var/yoq-filler-0 || true; i=1; while fallocate -l 16M /var/yoq-filler-\$i 2>/dev/null; do i=\$((i + 1)); done; while fallocate -l 1M /var/yoq-filler-\$i 2>/dev/null; do i=\$((i + 1)); done; sync; df -m /var | tail -n 1"
    check "$os apply --yes >/tmp/out 2>&1; echo \$?" 1
    "$vm" ssh "tail -n 6 /tmp/out"
    check "grep -c 'which is likely why' /tmp/out" 1
    check "$newest_cmd" "$before"
    check "$menu_cmd" "$menu"
    on_trial no
    check "pacman -Q $pkg >/dev/null 2>&1 || echo not installed" "not installed"
    check "findmnt -rn -o TARGET | grep -c /run/yoq/next || true" 0
    "$vm" ssh "rm -f /var/yoq-filler-*; sync"
    same_roots "$was"
    "$vm" ssh "$os remove --no-apply $pkg" | tail -n 1
    check "$os plan" "$empty"
}

# fills the esp up, leaving 2 MiB: less than a new initramfs, or a
# kernel.
fill_esp() {
    "$vm" ssh "avail=\$(df --output=avail -B1M $VM_ESP | tail -n 1); dd if=/dev/zero of=$VM_ESP/yoq-filler bs=1M count=\$((avail - 2)) status=none; sync; df -m $VM_ESP | tail -n 1"
}

# the esp fills up, then a change that needs a reboot would build the next
# generation. its new initramfs doesn't fit on the esp, so the plan says
# so, with the generations to collect for room, and apply stops before it
# builds anything.
esp_full() {
    pkg=$(ucode)
    "$vm" ssh "$os add --no-apply $pkg" | tail -n 1
    before=$("$vm" ssh "$newest_cmd")
    menu=$("$vm" ssh "$menu_cmd")
    was=$(roots)
    fill_esp
    check "$os plan >/tmp/out 2>&1; echo \$?" 1
    "$vm" ssh "tail -n 4 /tmp/out"
    check "grep -c 'error.E0131.: the esp at $VM_ESP has .* MiB free' /tmp/out" 1
    check "grep -c 'os gc --keep 1. removes generation' /tmp/out" 1
    check "$os apply --yes >/tmp/out 2>&1; echo \$?" 1
    check "grep -c 'error.E0131.' /tmp/out" 1
    check "grep -c 'building generation' /tmp/out || true" 0
    check "$newest_cmd" "$before"
    check "$menu_cmd" "$menu"
    on_trial no
    check "ls $VM_ESP/yoq/boot | grep -c yoq-new || true" 0
    check "pacman -Q $pkg >/dev/null 2>&1 || echo not installed" "not installed"
    "$vm" ssh "rm -f $VM_ESP/yoq-filler; sync"
    same_roots "$was"
    "$vm" ssh "$os remove --no-apply $pkg" | tail -n 1
    check "$os plan" "$empty"
}

# with grub and the esp at /boot, only the running root's boot files are
# on the esp, and a rollback puts the target's there. kernel.sh left a
# pinned generation with an older kernel than today's. with the esp full,
# the rollback to it goes ahead all the same, copies nothing, and says so;
# the new generation boots the older kernel from its own root, where its
# modules are, and the first good boot once there's room puts its files on
# the esp. then forward again, to the newest.
esp_restore() {
    target=$("$vm" ssh "cat /root/old-kernel-gen")
    back=$("$vm" ssh "$newest_cmd")
    running=$("$vm" ssh "uname -r")
    check "$os plan" "$empty"
    fill_esp
    check "$os rollback --yes $target >/tmp/out 2>&1; echo \$?" 0
    "$vm" ssh "tail -n 4 /tmp/out"
    check "grep -c 'boot files don.t fit on the esp, so nothing was copied there' /tmp/out" 1
    check "grep -c 'the esp at $VM_ESP has .* MiB free, and the new boot files need' /tmp/out" 1
    check "grep -c 'removing generations won.t help' /tmp/out" 1
    check "ls $VM_ESP | grep -c yoq-new || true" 0
    root=$(newest_root)
    check "cat /var/lib/yoq/unsettled" "/$root"
    "$vm" ssh "rm -f $VM_ESP/yoq-filler; sync"
    "$vm" reboot
    settled
    check "findmnt -no FSROOT /" "/$root"
    # the older kernel, from the root's own /boot, not today's on the esp,
    # and its modules with it.
    check "test \"\$(uname -r)\" != $running && echo older" older
    check "grep -c 'BOOT_IMAGE=[^ ]*/$root/boot/vmlinuz-linux' /proc/cmdline" 1
    kernel_matches
    check "test -e /var/lib/yoq/unsettled && echo noted || echo none" none
    check "$os plan" "$empty"
    "$vm" ssh "$os rollback --yes $back" | tail -n 1
    "$vm" reboot
    settled
    check "uname -r" "$running"
    kernel_matches
    check "$os plan" "$empty"
}

# a stand-in for $1 in /usr/local/bin, ahead of the real one in PATH,
# that cuts the power the first time os runs it with arguments that match
# the case pattern $2, before that call runs. it takes itself out first,
# so the boot after runs the real one. /usr/local is shared by every root,
# so os health sees it at boot too.
power_cut_on() {
    f=$(mktemp)
    cat > "$f" <<EOF
#!/bin/sh
case "\$*" in
$2)
    rm -f /usr/local/bin/$1
    sync
    echo b > /proc/sysrq-trigger
    sleep 60
    ;;
esac
exec /usr/bin/$1 "\$@"
EOF
    "$vm" copy "$f" "/usr/local/bin/$1"
    rm -f "$f"
    "$vm" ssh "chmod 755 /usr/local/bin/$1 && sync"
}

# waits for the boot after power_cut_on's stand-in for $1 cut the power:
# the stand-in is gone, the machine runs the root $2, and yoq-health has
# finished. the boot the power went out on had the health check running
# when it did.
wait_cut() {
    for _ in $(seq 60); do
        got=$(timeout 20 "$vm" ssh "test ! -e /usr/local/bin/$1 && test \"\$(systemctl show -p ExecMainExitTimestampMonotonic --value yoq-health)\" != 0 && findmnt -no FSROOT /" 2>/dev/null || true)
        [ "$got" = "$2" ] && return 0
        sleep 10
    done
    echo "$name: no boot into $2 with the health check done after the power cut"
    "$vm" ssh "findmnt -no FSROOT /; ls /usr/local/bin; journalctl -b -u yoq-health --no-pager -o cat | tail -n 10" || true
    exit 1
}

# the trial's own steps, with the power cut at each: while the trial is
# set up, while a trial that passed is made the default, and while a
# fallback ends the trial it fell back from. each step is one call os
# makes to the bootloader's tool, and the cut comes just before it.
trial_cuts() {
    case $VM_LOADER in
    grub) arm_tool=grub-editenv arm_cut='*yoq_next=head*' end_tool=grub-editenv end_cut='*"unset yoq_default"*' ;;
    limine | systemd-boot) arm_tool=bootctl arm_cut='"set-oneshot "*trial*' end_tool=bootctl end_cut='"set-oneshot "' ;;
    refind) arm_tool=efibootmgr arm_cut='*"-n "*' end_tool=efibootmgr end_cut='*-B*' ;;
    esac
    fell="$os history | grep -c 'fell back from' || true"
    pkg=$(ucode)

    # arming: the menu holds the default on the generation before, and the
    # power goes before the bootloader is told to try the new one. that
    # boot runs the generation before, whose health check sets the trial
    # up again, and the boot after tries it.
    before=$("$vm" ssh "$newest_cmd")
    falls=$("$vm" ssh "$fell")
    power_cut_on "$arm_tool" "$arm_cut"
    crash "$os add --yes $pkg"
    wait_cut "$arm_tool" "/@roots/boot-$before"
    check "journalctl -b -u yoq-health --no-pager -o cat | grep -c 'trial wasn.t set up before the machine went down'" 1
    on_trial yes
    "$vm" reboot
    settled
    check "findmnt -no FSROOT /" "/$(newest_root)"
    check "journalctl -b -u yoq-health --no-pager -o cat | grep -c 'the default now'" 1
    on_trial no
    check "pacman -Q $pkg >/dev/null && echo installed" installed
    check "$fell" "$falls"

    # blessing: the trial comes up healthy, and the power goes while it's
    # made the default. the bootloader still boots the generation before,
    # whose health check finishes the job instead of falling back.
    before=$("$vm" ssh "$newest_cmd")
    "$vm" ssh "$os remove --yes $pkg" | tail -n 1
    on_trial yes
    power_cut_on "$end_tool" "$end_cut"
    "$vm" reboot || true
    wait_cut "$end_tool" "/@roots/boot-$before"
    check "journalctl -b -u yoq-health --no-pager -o cat | grep -c 'machine went down before it was the default'" 1
    on_trial no
    check "$fell" "$falls"
    "$vm" reboot
    settled
    check "findmnt -no FSROOT /" "/$(newest_root)"
    check "pacman -Q $pkg >/dev/null 2>&1 || echo removed" removed
    check "$os plan" "$empty"

    # falling back: a trial that can't boot, then the power goes as the
    # fallback ends the trial, after it made its generation. the boot after
    # finds that generation made, and only ends the trial.
    "$vm" ssh "$os add --yes $pkg" | tail -n 1
    on_trial yes
    before=$(second_newest)
    break_trial_boot
    power_cut_on "$end_tool" "$end_cut"
    "$vm" reboot || true
    wait_cut "$end_tool" "/@roots/boot-$before"
    check "$fell" "$((falls + 1))"
    check "/usr/local/bin/os history | tail -n 1 | grep -c 'fell back from'" 1
    on_trial no
    "$vm" reboot
    settled
    check "findmnt -no FSROOT /" "/$(newest_root)"
    check "$os plan" "$empty"
}

for what in "$@"; do
    case $what in
    crash) crash_apply ;;
    trial) trial_cuts ;;
    committed) crash_committed ;;
    download) download ;;
    disk) disk_full ;;
    esp) esp_full ;;
    restore) esp_restore ;;
    *)
        echo "$name: no failure called $what"
        exit 2
        ;;
    esac
done
echo "failures ok: $*"
