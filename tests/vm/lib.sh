# helpers the vm tests share. failures are named after the script that
# sources this. a failing command in a pipe fails the test, here and in
# the vm, where vm.sh runs commands with pipefail too. that means
# `x | grep -c ... || true` also hides x failing, so a check that counts
# nothing saves x's output first, or writes `x | { grep -c ... || true; }`.
# and no pipe ends in `grep -q`: it stops reading at the first match,
# which can kill x with sigpipe.
set -o pipefail
vm=tests/vm/vm.sh
name=$(basename "$0" .sh)

# runs a command in the vm and compares what it prints. it has to exit 0
# as well: a command that fails on purpose says so, with `|| true` or
# `echo $?`.
check() {
    rc=0
    got=$("$vm" ssh "$1") || rc=$?
    if [ "$got" != "$2" ] || [ "$rc" != 0 ]; then
        echo "$name: $1 gave '$got' (exit $rc), not '$2' (exit 0)"
        # a script can name a command whose output explains a failure.
        if [ -n "${on_failure:-}" ]; then "$vm" ssh "$on_failure" || true; fi
        exit 1
    fi
    echo "ok: $1 -> $got"
}

# puts the serial port in the boot menu an install wrote on the esp at $1,
# so a first boot that fails shows in the console log. yos install only
# passes on the live system's consoles, and a live iso may have none.
serial_console() {
    "$vm" ssh "mkdir -p /run/yos-esp && mount $1 /run/yos-esp && sed -i '/^[[:space:]]*linux /{/console=ttyS0/!s/\$/ console=ttyS0,115200/}' /run/yos-esp/grub/grub.cfg && grep -c 'console=ttyS0' /run/yos-esp/grub/grub.cfg; umount /run/yos-esp"
}

# check, with the btrfs top level mounted at /run/yos-top for the command.
# the command's exit status counts, not umount's.
check_top() {
    check "mkdir -p /run/yos-top && mount -o subvolid=5 \$(findmnt -no SOURCE / | sed 's/\\[.*//') /run/yos-top && { $1; }; top_rc=\$?; umount /run/yos-top; exit \$top_rc" "$2"
}

# a command that counts the files in the initramfs at $1 that match $2.
# lsinitcpio has to read it, or a broken image would count 0 as well.
initramfs_count() {
    echo "lsinitcpio $1 >/tmp/initramfs.list && { grep -c '$2' /tmp/initramfs.list || true; }"
}

# a command that runs yos's report $1, like `/usr/local/bin/yos doctor`,
# with what it prints in /tmp/report for a check to grep. status and
# doctor exit 1 when they find something to fix, which a test may not care
# about here. any other exit, or a report without the line $2 (a grep
# pattern) that every whole one has, is yos failing.
report() {
    echo "$1 >/tmp/report; rc=\$?; [ \$rc -le 1 ] && grep -q -e '$2' /tmp/report || { echo \"$1 exited \$rc:\"; cat /tmp/report; exit 1; }"
}

# status's report, from yos at $1 if given. it always says what's failing,
# if only "none".
status_report() {
    report "${1:-/usr/local/bin/yos} status" '^failing '
}

# doctor's report, from yos at $1 if given. it ends saying what to do about
# its checks, if anything.
doctor_report() {
    report "${1:-/usr/local/bin/yos} doctor" '^nothing to fix\|^the lines under each'
}

# a command that prints one of the firmware's secure boot variables,
# 1 or 0: its value comes after 4 bytes of attributes.
efivar() {
    echo "tail -c 1 /sys/firmware/efi/efivars/$1-8be4df61-93ca-11d2-aa0d-00e098032b8c | od -An -tu1 | tr -d ' '"
}

# yos-health runs once per boot, after the rest; wait until it has run
# this boot, but not forever, and fail unless it exited $1, 0 by default.
# a boot that falls back from a trial, or ends one only grub's env file
# names, exits 1 there on purpose.
settled() {
    want=${1:-0}
    got=$("$vm" ssh "for i in \$(seq 150); do [ \"\$(systemctl show -p ExecMainExitTimestampMonotonic --value yos-health)\" != 0 ] && exec echo \$(systemctl show -p Result --value yos-health) \$(systemctl show -p ExecMainStatus --value yos-health); sleep 2; done; echo 'no yos-health run after 5 minutes'; exit 1") || { echo "$name: $got"; exit 1; }
    case $want in 0) expected="success 0" ;; *) expected="exit-code $want" ;; esac
    if [ "$got" != "$expected" ]; then
        echo "$name: yos-health ended '$got' this boot, not '$expected'"
        "$vm" ssh "journalctl -b -u yos-health --no-pager -o cat | tail -n 20" || true
        exit 1
    fi
}

# what the bootloader will boot next, on one line. it's only for the log,
# so it never fails the test.
show_env() {
    case $VM_LOADER in
    grub) "$vm" ssh "grub-editenv $VM_ESP/yos/grubenv list | grep ^yos_ | sort | tr '\\n' ' '" || true ;;
    limine | systemd-boot) "$vm" ssh "cat /var/lib/yos/trial 2>/dev/null; ls /sys/firmware/efi/efivars | grep ^LoaderEntry | tr '\\n' ' '" || true ;;
    refind) "$vm" ssh "cat /var/lib/yos/trial 2>/dev/null; efibootmgr | sed -n 1,3p | tr '\\n' ' '" || true ;;
    *) ;;
    esac
}

# "yes" while a generation is on trial, or "no".
on_trial() {
    case $VM_LOADER in
    grub) check "grub-editenv $VM_ESP/yos/grubenv list >/tmp/grubenv && { grep -q -e ^yos_trial -e ^yos_default /tmp/grubenv && echo yes || echo no; }" "$1" ;;
    *) check "test -e /var/lib/yos/trial && echo yes || echo no" "$1" ;;
    esac
}

# the loader's config with yos's entries.
menu_file() {
    case $VM_LOADER in
    grub) echo "$VM_ESP/grub/grub.cfg" ;;
    # only one of the places limine reads is there.
    limine) "$vm" ssh "{ ls $VM_ESP/EFI/*/limine.conf $VM_ESP/limine.conf 2>/dev/null || true; } | sed -n 1p" ;;
    refind) "$vm" ssh "ls $VM_ESP/EFI/*/yos.conf | sed -n 1p" ;;
    systemd-boot) echo "$VM_ESP/loader/entries" ;;
    esac
}

# a command that counts the generations the boot menu lists.
menu_count() {
    f=$(menu_file)
    case $VM_LOADER in
    grub) echo "grep -c -e '--id head' -e '--id gen-' $f" ;;
    limine) echo "grep -c '^/yos [0-9]' $f" ;;
    refind) echo "grep -c '^menuentry \"yos [0-9]' $f" ;;
    systemd-boot) echo "ls $f | grep -c -e '^yos-head.conf' -e '^yos-gen-'" ;;
    esac
}

# how many generations the boot menu lists.
menu_generations() {
    check "$(menu_count)" "$1"
}

# runs $1 in the vm, which loses power partway through, and waits for the
# boot after. $1 finishing with the machine still up fails the test.
crash() {
    old=$("$vm" ssh "cat /proc/sys/kernel/random/boot_id")
    rc=0
    "$vm" ssh "$1" || rc=$?
    # ssh says 255 when the connection goes with the machine.
    if [ "$rc" != 255 ]; then
        echo "$name: $1 exited $rc, and the machine stayed up"
        exit 1
    fi
    for _ in $(seq 60); do
        id=$(timeout 20 "$vm" ssh "cat /proc/sys/kernel/random/boot_id" 2>/dev/null || true)
        if [ -n "$id" ] && [ "$id" != "$old" ]; then return 0; fi
        sleep 5
    done
    echo "$name: no boot after the power loss"
    # from the serial console, for a boot that came up without a network.
    "$vm" diagnose || true
    exit 1
}

# takes yos's entries out of the boot menu, the way another tool that
# rewrites the bootloader's config would.
drop_menu() {
    f=$(menu_file)
    case $VM_LOADER in
    grub) "$vm" ssh "echo '# someone else' > $f" ;;
    limine) "$vm" ssh "sed -i '/^# yos: generations/,/^# yos: end/d' $f" ;;
    refind) "$vm" ssh "sed -i '/^include yos.conf/d' \$(dirname $f)/refind.conf" ;;
    systemd-boot) "$vm" ssh "rm $f/yos-head.conf" ;;
    esac
}

# makes the next boot run generation $1 from the menu, as if picked by
# hand. refind has no one-shot boot, so its default moves there until
# boot_done moves it back.
boot_once() {
    case $VM_LOADER in
    grub) "$vm" ssh "grub-editenv $VM_ESP/yos/grubenv set yos_next=gen-$1" ;;
    systemd-boot) "$vm" ssh "bootctl set-oneshot yos-gen-$1.conf" ;;
    limine) "$vm" ssh "bootctl set-oneshot \"\$(grep '^/yos $1 ' $(menu_file) | cut -c2- | sed 's/[^A-Za-z0-9+_.@-]/-/g')\"" ;;
    refind)
        f=$(menu_file)
        "$vm" ssh "cp $f /root/yos.conf.saved && sed -i \"s|^default_selection .*|default_selection \\\"\$(grep -o '^menuentry \"yos $1 [^\"]*' $f | cut -c12-)\\\"|\" $f && grep ^default_selection $f"
        ;;
    esac
}

# after boot_once, the next boot is the newest generation again.
boot_done() {
    [ "$VM_LOADER" = refind ] || return 0
    "$vm" ssh "cp /root/yos.conf.saved $(menu_file)"
}

# waits up to 10 minutes for the vm to come up running the root $1. a boot
# that doesn't answer, or answers from another root, is waited out. if it
# never comes, this shows what the machine is doing and fails.
wait_root() {
    for _ in $(seq 60); do
        root=$(timeout 20 "$vm" ssh "findmnt -no FSROOT /" 2>/dev/null || true)
        [ "$root" = "$1" ] && return 0
        sleep 10
    done
    echo "$name: no boot into $1 after 10 minutes; the machine shows:"
    "$vm" ssh "findmnt -no FSROOT /; cat /proc/cmdline; systemctl is-active yos-watchdog.timer multi-user.target; journalctl -b -u yos-health -u yos-watchdog.timer -u yos-watchdog.service --no-pager -o cat | tail -n 10" || true
    if [ -n "${on_failure:-}" ]; then "$vm" ssh "$on_failure" || true; fi
    # the same from the serial console, which doesn't need the network.
    "$vm" diagnose || true
    exit 1
}

# the vm's serial console, as vm.sh logs it on this side. reboots keep
# writing to the same file.
console=${VM_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/yos-vm}/console.log

# after a trial that shouldn't come up: the next boot runs generation $1
# from its copy, and yos took it on as the newest generation. the trial
# has to have been tried, or a machine that never left the default would
# pass too. by default the boot before this one is the trial's, whose
# kernel logged its command line with the trial's root and yos.trial. a
# trial that leaves no journal names its own proof in $2:
# "console:<pattern>", for what the bootloader or a panicking kernel
# printed, or "journal:<pattern>", for the boot before this one.
falls_back() {
    proof=${2:-}
    if [ -z "$proof" ]; then
        trial_root=$(newest_root)
        proof="journal:Command line:.*subvol=/$trial_root[ ,].*yos\\.trial"
    fi
    mark=$(wc -c < "$console" 2>/dev/null || echo 0)
    "$vm" reboot || true
    wait_root "/@roots/boot-$1"
    # the fallback ends the trial and says so with exit 1.
    settled 1
    check "/usr/local/bin/yos history | tail -n 1 | grep -c 'fell back from'" 1
    case $proof in
    console:*)
        # grep reads it all, not -q: an early exit would kill tail with
        # sigpipe, and pipefail would call that a miss.
        if ! tail -c +"$((mark + 1))" "$console" | tr -d '\r' | grep -a -E -e "${proof#console:}" >/dev/null; then
            echo "$name: the trial wasn't tried: nothing on the console matches '${proof#console:}'"
            # the boots since, without the journal's own lines (see
            # test.sh), which would bury the bootloader's and the kernel's.
            echo "--- the console since the reboot"
            tail -c +"$((mark + 1))" "$console" | tr -d '\r' | sed 's/\x1b\[[0-9;?=!]*[a-zA-Z]//g' | grep -a -v -E '^\[ *[0-9.]+\] [A-Za-z0-9_.@-]+\[[0-9]+\]:' | head -n 150
            exit 1
        fi
        ;;
    journal:*) check "journalctl -b -1 --no-pager -o cat | grep -E -c -e '${proof#journal:}' | sed 's/^[1-9][0-9]*\$/seen/'" seen ;;
    esac
    echo "ok: the trial was tried ($proof)"
}

# the newest generation's number.
newest() {
    "$vm" ssh "ls /var/lib/yos/generations | sort -n | tail -n 1 | cut -d. -f1"
}

# makes the next trial boot's initramfs garbage, so its kernel can't
# start and panics, and panic=10 reboots into the generation before. grub
# and refind boot the staged root's own /boot, so that file is broken.
# limine and systemd-boot share boot files on the esp between generations
# with the same content, and breaking one could break the fallback too;
# there, the trial entry points at a garbage file of its own.
break_trial_boot() {
    case $VM_LOADER in
    limine) "$vm" ssh "echo not an initramfs > $VM_ESP/yos/boot/garbage.img && sed -i '/^\/yos trial boot/,/cmdline/ s|module_path: boot():[^ ]*initramfs[^ ]*|module_path: boot():/yos/boot/garbage.img|' $(menu_file) && grep -A5 '^/yos trial boot' $(menu_file)" ;;
    systemd-boot) "$vm" ssh "echo not an initramfs > $VM_ESP/yos/boot/garbage.img && sed -i 's|^initrd .*initramfs.*|initrd /yos/boot/garbage.img|' $VM_ESP/loader/entries/yos-trial*.conf && cat $VM_ESP/loader/entries/yos-trial*.conf" ;;
    *)
        staged=$(newest_root)
        "$vm" ssh "mkdir -p /run/yos-top && mount -o subvolid=5 \$(findmnt -no SOURCE / | sed 's/\\[.*//') /run/yos-top && echo not an initramfs > /run/yos-top/$staged/boot/initramfs-linux.img; umount /run/yos-top"
        ;;
    esac
}

# makes the next trial boot's kernel one the bootloader can't load: gone
# ($1 = missing), not a kernel at all ($1 = garbage), or on systemd-boot,
# a whole kernel marked for another machine, arm64 ($1 = foreign), which
# looks fine until the firmware won't start it. grub and refind read it
# from the staged root's /boot; limine and systemd-boot get a path of
# their own on the esp, so the fallback's copies stay whole.
break_trial_kernel() {
    esp_file=/yos/boot/$1-kernel
    case $VM_LOADER in
    limine) "$vm" ssh "echo not a kernel > $VM_ESP/yos/boot/garbage-kernel && sed -i '/^\/yos trial boot/,/cmdline/ s|^    path: boot():.*|    path: boot():$esp_file|' $(menu_file) && grep -A5 '^/yos trial boot' $(menu_file)" ;;
    systemd-boot)
        if [ "$1" = foreign ]; then
            # the pe header's machine field, after "PE\0\0", says arm64.
            "$vm" ssh "f=$VM_ESP$esp_file && cp $VM_ESP\$(sed -n 's|^linux ||p' $VM_ESP/loader/entries/yos-trial*.conf) \$f && pe=\$(od -An -tu4 -j60 -N4 \$f | tr -d ' ') && printf '\\144\\252' | dd of=\$f bs=1 seek=\$((pe + 4)) conv=notrunc 2>/dev/null && od -An -tx2 -j\$((pe + 4)) -N2 \$f"
        else
            "$vm" ssh "echo not a kernel > $VM_ESP/yos/boot/garbage-kernel"
        fi
        "$vm" ssh "sed -i 's|^linux .*|linux $esp_file|' $VM_ESP/loader/entries/yos-trial*.conf && cat $VM_ESP/loader/entries/yos-trial*.conf"
        ;;
    *)
        staged=$(newest_root)
        if [ "$1" = missing ]; then breakage="mv /run/yos-top/$staged/boot/vmlinuz-linux /run/yos-top/$staged/boot/vmlinuz-linux.gone"; else breakage="echo not a kernel > /run/yos-top/$staged/boot/vmlinuz-linux"; fi
        "$vm" ssh "mkdir -p /run/yos-top && mount -o subvolid=5 \$(findmnt -no SOURCE / | sed 's/\\[.*//') /run/yos-top && $breakage; umount /run/yos-top"
        ;;
    esac
}

# makes the next trial boot hang before yos's watchdog would ordinarily
# be there: the initramfs can't mount the root ($1 = root, the trial's
# command line names a subvolume that isn't there), the root's fstab has
# a mount that never comes ($1 = fstab, so it drops to an emergency
# shell), or a unit holds up sysinit.target for good ($1 = sysinit).
break_trial_early() {
    if [ "$1" = root ]; then
        sub="s|subvol=/@roots/[0-9]*|subvol=/@roots/999|"
        case $VM_LOADER in
        grub) "$vm" ssh "sed -i '/--id head/,/^}/ $sub' $(menu_file) && sed -n '/--id head/,/^}/p' $(menu_file)" ;;
        limine) "$vm" ssh "sed -i '/^\/yos trial boot/,/cmdline/ $sub' $(menu_file) && grep -A5 '^/yos trial boot' $(menu_file)" ;;
        systemd-boot) "$vm" ssh "sed -i '/^options / $sub' $VM_ESP/loader/entries/yos-trial*.conf && cat $VM_ESP/loader/entries/yos-trial*.conf" ;;
        refind) "$vm" ssh "sed -i '/menuentry \"yos trial boot\"/,/^}/ $sub' $VM_ESP/EFI/yos-trial/refind.conf && grep -A4 'menuentry \"yos trial boot\"' $VM_ESP/EFI/yos-trial/refind.conf" ;;
        esac
        return
    fi
    staged=$(newest_root)
    case $1 in
    fstab) breakage="echo 'UUID=00000000-0000-4000-8000-000000000000 /mnt/yos-missing ext4 defaults 0 2' >> /run/yos-top/$staged/etc/fstab" ;;
    sysinit) breakage="printf '[Unit]\\nDescription=hang before sysinit\\nDefaultDependencies=no\\nBefore=sysinit.target\\n[Service]\\nType=oneshot\\nTimeoutStartSec=infinity\\nExecStart=/usr/bin/sleep infinity\\n[Install]\\nWantedBy=sysinit.target\\n' > /run/yos-top/$staged/etc/systemd/system/yos-test-hang.service && mkdir -p /run/yos-top/$staged/etc/systemd/system/sysinit.target.wants && ln -sf ../yos-test-hang.service /run/yos-top/$staged/etc/systemd/system/sysinit.target.wants/" ;;
    esac
    "$vm" ssh "mkdir -p /run/yos-top && mount -o subvolid=5 \$(findmnt -no SOURCE / | sed 's/\\[.*//') /run/yos-top && $breakage; umount /run/yos-top"
}

# the newest generation's root, like @roots/7.
newest_root() {
    n=$(newest)
    "$vm" ssh "sed -n 's/.*\"root\":\"\\([^\"]*\\)\".*/\\1/p' /var/lib/yos/generations/$n.json"
}

# the number of the generation before the newest.
second_newest() {
    "$vm" ssh "ls /var/lib/yos/generations | sort -n | tail -n 2 | sed -n 1p | cut -d. -f1"
}

# the running kernel is the root's own linux, and its modules are there.
kernel_matches() {
    check "test -d /usr/lib/modules/\$(uname -r) && echo modules" modules
    check "[ \"\$(uname -r)\" = \"\$(pacman -Q linux | cut -d' ' -f2 | sed 's/\\.arch/-arch/')\" ] && echo same || { uname -r; pacman -Q linux; }" same
}

# puts tests/vm/older.sh in the vm, and prints what it finds for $1.
older() {
    "$vm" copy tests/vm/older.sh /root/older.sh
    "$vm" ssh "sh /root/older.sh $1"
}

# installs the newest linux older than the one installed, from the
# archive, with pacman -U. the archive is one server, with no mirror to go
# on to when it stalls, so the download gets a second try.
older_linux() {
    url=$(older linux)
    [ -n "$url" ] || { echo "$name: no older linux in the archive"; exit 1; }
    "$vm" ssh "pacman -U --noconfirm --noprogressbar $url >/dev/null || { echo 'pacman -U failed; once more' >&2; sleep 10; pacman -U --noconfirm --noprogressbar $url >/dev/null; }"
}
