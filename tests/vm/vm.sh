#!/bin/sh
# a throwaway arch vm for tests: arch's cloud image (grub on btrfs), booted
# under uefi with kvm, on a copy-on-write overlay so every start is fresh.
#
#   vm.sh image              download the base image, once
#   vm.sh start              boot a fresh overlay and wait for ssh
#   vm.sh ssh <command>      run a command in the vm as root
#   vm.sh copy <file> <dest> copy a file into the vm
#   vm.sh reboot             reboot and wait for ssh
#   vm.sh stop               power off and throw the overlay away
#
# needs qemu, edk2-ovmf, xorriso, and openssh. VM_DIR sets where the image
# and the running vm's files live.
set -eu

dir=${VM_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/yoq-vm}
image_url=https://geo.mirror.pkgbuild.com/images/latest/Arch-Linux-x86_64-cloudimg.qcow2
ovmf=${OVMF_DIR:-/usr/share/edk2/x64}
port=${VM_SSH_PORT:-2222}

ssh_opts="-i $dir/key -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5"

run() {
    # shellcheck disable=SC2086
    ssh $ssh_opts -p "$port" root@127.0.0.1 "$@"
}

# waits until the vm answers over ssh with a boot id other than $1.
wait_boot() {
    for _ in $(seq 120); do
        id=$(run cat /proc/sys/kernel/random/boot_id 2>/dev/null || true)
        if [ -n "$id" ] && [ "$id" != "$1" ]; then return 0; fi
        sleep 3
    done
    echo "vm: no ssh after 6 minutes; the console log is $dir/console.log" >&2
    exit 1
}

seed() {
    [ -f "$dir/key" ] || ssh-keygen -q -t ed25519 -N '' -f "$dir/key"
    mkdir -p "$dir/seed"
    cat > "$dir/seed/user-data" <<EOF
#cloud-config
disable_root: false
users:
  - name: root
    ssh_authorized_keys:
      - $(cat "$dir/key.pub")
EOF
    printf 'instance-id: yoq-test\nlocal-hostname: yoq-test\n' > "$dir/seed/meta-data"
    xorriso -as mkisofs -quiet -o "$dir/seed.iso" -V cidata -J -r "$dir/seed/user-data" "$dir/seed/meta-data"
}

case ${1:-} in
image)
    mkdir -p "$dir"
    [ -f "$dir/base.qcow2" ] || curl -fsSL -o "$dir/base.qcow2" "$image_url"
    ;;
start)
    [ -f "$dir/base.qcow2" ] || { echo "vm: no base image; run vm.sh image" >&2; exit 1; }
    seed
    qemu-img create -q -f qcow2 -b "$dir/base.qcow2" -F qcow2 "$dir/overlay.qcow2" 12G
    cp "$ovmf/OVMF_VARS.4m.fd" "$dir/vars.fd"
    qemu-system-x86_64 -enable-kvm -cpu host -machine q35 -smp 2 -m 2048 \
        -drive if=pflash,format=raw,readonly=on,file="$ovmf/OVMF_CODE.4m.fd" \
        -drive if=pflash,format=raw,file="$dir/vars.fd" \
        -drive if=virtio,file="$dir/overlay.qcow2" \
        -drive media=cdrom,file="$dir/seed.iso" \
        -netdev user,id=net,hostfwd=tcp:127.0.0.1:"$port"-:22 -device virtio-net-pci,netdev=net \
        -display none -serial file:"$dir/console.log" \
        -daemonize -pidfile "$dir/qemu.pid"
    wait_boot ""
    run cloud-init status --wait >/dev/null || true
    ;;
ssh)
    shift
    run "$@"
    ;;
copy)
    # shellcheck disable=SC2086
    scp -q $ssh_opts -P "$port" "$2" root@127.0.0.1:"$3"
    ;;
reboot)
    old=$(run cat /proc/sys/kernel/random/boot_id)
    run systemctl reboot || true
    wait_boot "$old"
    ;;
stop)
    if [ -f "$dir/qemu.pid" ]; then kill "$(cat "$dir/qemu.pid")" 2>/dev/null || true; fi
    rm -f "$dir/qemu.pid" "$dir/overlay.qcow2" "$dir/vars.fd"
    ;;
*)
    sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'
    exit 2
    ;;
esac
