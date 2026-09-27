# helpers the vm tests share. failures are named after the script that
# sources this.
vm=tests/vm/vm.sh
name=$(basename "$0" .sh)

# runs a command in the vm and compares what it prints.
check() {
    got=$("$vm" ssh "$1")
    if [ "$got" != "$2" ]; then
        echo "$name: $1 gave '$got', not '$2'"
        exit 1
    fi
    echo "ok: $1 -> $got"
}

# check, with the btrfs top level mounted at /run/yoq-top for the command.
check_top() {
    check "mkdir -p /run/yoq-top && mount -o subvolid=5 \$(findmnt -no SOURCE / | sed 's/\\[.*//') /run/yoq-top && { $1; }; umount /run/yoq-top" "$2"
}

# yoq-health runs after boot; wait for it to be done, but not forever.
settled() {
    "$vm" ssh "for i in \$(seq 150); do [ \"\$(systemctl show -p ActiveState --value yoq-health)\" = activating ] || exit 0; sleep 2; done; echo 'yoq-health still running after 5 minutes'; exit 1"
}

# grub's env on the esp, on one line.
show_env() {
    "$vm" ssh "grub-editenv $VM_ESP/yoq/grubenv list | grep ^yoq_ | sort | tr '\\n' ' '"
}

# waits up to 10 minutes for the vm to come up running the root $1. a boot
# that doesn't answer, or answers from another root, is waited out.
wait_root() {
    for _ in $(seq 60); do
        root=$(timeout 20 "$vm" ssh "findmnt -no FSROOT /" 2>/dev/null || true)
        [ "$root" = "$1" ] && return 0
        sleep 10
    done
}

# the number of the generation before the newest.
second_newest() {
    "$vm" ssh "ls /var/lib/yoq/generations | sort -n | tail -n 2 | head -n 1 | cut -d. -f1"
}
