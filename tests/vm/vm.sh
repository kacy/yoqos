#!/bin/sh
# a throwaway arch vm for tests, booted under uefi with kvm, on a
# copy-on-write overlay so every start is fresh. VM_IMAGE picks the base:
#
#   cloud        arch's cloud image: grub on btrfs, the root in the top level
#   archinstall  archinstall's defaults: the esp at /boot, grub, and btrfs
#                with @, @home, @log, and @pkg
#   ext4         archinstall's layout with an ext4 root: no generations
#   limine       archinstall with limine and snapper, like omarchy's boot
#                setup
#   refind       archinstall with refind
#
#   vm.sh image              make the base image, once
#   vm.sh start              boot a fresh overlay and wait for ssh; with
#                            VM_DISK2=1, a blank second disk too
#   vm.sh start-installed    power off and boot the second disk alone, with
#                            blank firmware variables, like a new machine
#   vm.sh ssh <command>      run a command in the vm as root
#   vm.sh copy <file> <dest> copy a file into the vm
#   vm.sh reboot             reboot and wait for ssh
#   vm.sh stop               power off and throw the overlay away
#
# needs qemu, edk2-ovmf, xorriso, and openssh. VM_DIR sets where the images
# and the running vm's files live.
set -eu

dir=${VM_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/yoq-vm}
image_url=https://geo.mirror.pkgbuild.com/images/latest/Arch-Linux-x86_64-cloudimg.qcow2
ovmf=${OVMF_DIR:-/usr/share/edk2/x64}
port=${VM_SSH_PORT:-2222}
image=${VM_IMAGE:-cloud}

ssh_opts="-i $dir/key -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5 -o ServerAliveInterval=5 -o ServerAliveCountMax=3"

run() {
    # shellcheck disable=SC2086
    ssh $ssh_opts -p "$port" root@127.0.0.1 "$@"
}

# waits until the vm answers over ssh with a boot id other than $1.
wait_boot() {
    for _ in $(seq 120); do
        # a guest stuck halfway through booting can hold a connection
        # open, so every probe has its own deadline.
        id=$(timeout 20 ssh $ssh_opts -p "$port" root@127.0.0.1 cat /proc/sys/kernel/random/boot_id 2>/dev/null || true)
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

# whether qemu is still running. it removes its pid file when it stops.
running() {
    [ -f "$dir/qemu.pid" ] && kill -0 "$(cat "$dir/qemu.pid")" 2>/dev/null
}

# boots <disk> with the firmware variables in <vars>, plus any extra qemu
# arguments, and waits for ssh.
boot() {
    disk=$1 vars=$2
    shift 2
    seed
    qemu-system-x86_64 -enable-kvm -cpu host -machine q35 -smp 2 -m 2048 \
        -drive if=pflash,format=raw,readonly=on,file="$ovmf/OVMF_CODE.4m.fd" \
        -drive if=pflash,format=raw,file="$vars" \
        -drive if=virtio,file="$disk" \
        -drive media=cdrom,file="$dir/seed.iso" \
        -netdev user,id=net,hostfwd=tcp:127.0.0.1:"$port"-:22 -device virtio-net-pci,netdev=net \
        -display none -serial file:"$dir/console.log" \
        -daemonize -pidfile "$dir/qemu.pid" "$@"
    wait_boot ""
    run cloud-init status --wait >/dev/null 2>&1 || true
}

# a fresh overlay on the base image. its firmware variables come from the
# image when it has its own boot entry, as archinstall's does.
fresh() {
    qemu-img create -q -f qcow2 -b "$dir/$1.qcow2" -F qcow2 "$dir/overlay.qcow2" 16G
    if [ -f "$dir/$1.vars" ]; then cp "$dir/$1.vars" "$dir/vars.fd"; else cp "$ovmf/OVMF_VARS.4m.fd" "$dir/vars.fd"; fi
}

# archinstall, run in the cloud vm against a second disk with the config
# in archinstall.json, edited by the sed arguments given. the disk and the
# firmware variables it wrote are the image.
archinstall() {
    VM_IMAGE=cloud "$0" image
    fresh cloud
    qemu-img create -q -f qcow2 "$dir/$image.part" 16G
    boot "$dir/overlay.qcow2" "$dir/vars.fd" -drive if=virtio,file="$dir/$image.part"
    here=$(dirname "$0")
    sed -e "s|KEY|$(cat "$dir/key.pub")|" "$@" "$here/archinstall.json" > "$dir/archinstall.json"
    printf '{"root_enc_password": "%s"}\n' "$root_hash" > "$dir/creds.json"
    scp -q $ssh_opts -P "$port" "$dir/archinstall.json" root@127.0.0.1:/root/config.json
    scp -q $ssh_opts -P "$port" "$dir/creds.json" root@127.0.0.1:/root/creds.json
    run pacman -Syu --noconfirm --noprogressbar --needed archinstall >/dev/null
    run archinstall --config /root/config.json --creds /root/creds.json --silent --skip-version-check
    run "umount -R /mnt/archinstall 2>/dev/null; sync"
    kill "$(cat "$dir/qemu.pid")"
    for _ in $(seq 60); do running || break; sleep 1; done
    if running; then echo "vm: qemu didn't stop" >&2; exit 1; fi
    mv "$dir/$image.part" "$dir/$image.qcow2"
    mv "$dir/vars.fd" "$dir/$image.vars"
    rm -f "$dir/qemu.pid" "$dir/overlay.qcow2"
}

# the test image's root password, "yoq". tests log in with the key.
root_hash='$6$yoqtest$1O8KkkgUFxpfgynUcFNHA3HfsIzEwgQTT08V4e4qLTP41SDhe6dXugxAvBde5MUV0ZSq9J/0tyDLUqA..mecu0'

case ${1:-} in
image)
    mkdir -p "$dir"
    [ -f "$dir/$image.qcow2" ] && exit 0
    case $image in
    cloud) curl -fsSL -o "$dir/cloud.qcow2" "$image_url" ;;
    archinstall) archinstall ;;
    ext4) archinstall -e 's|"fs_type": "btrfs"|"fs_type": "ext4"|' -e 's|"mountpoint": null|"mountpoint": "/"|' \
        -e 's|"compress=zstd"||' -e 's|"btrfs": \[{.*}\]|"btrfs": []|' ;;
    limine) archinstall -e 's|"bootloader": "Grub"|"bootloader": "Limine"|' \
        -e 's|"config_type": "default_layout",|"config_type": "default_layout", "btrfs_options": { "snapshot_config": { "type": "Snapper" } },|' ;;
    refind) archinstall -e 's|"bootloader": "Grub"|"bootloader": "Refind"|' ;;
    *) echo "vm: no image called $image" >&2; exit 2 ;;
    esac
    ;;
start)
    [ -f "$dir/$image.qcow2" ] || { echo "vm: no $image image; run vm.sh image" >&2; exit 1; }
    fresh "$image"
    if [ -n "${VM_DISK2:-}" ]; then
        qemu-img create -q -f qcow2 "$dir/disk2.qcow2" 20G
        boot "$dir/overlay.qcow2" "$dir/vars.fd" -drive if=virtio,file="$dir/disk2.qcow2"
    else
        boot "$dir/overlay.qcow2" "$dir/vars.fd"
    fi
    ;;
start-installed)
    if running; then kill "$(cat "$dir/qemu.pid")"; fi
    for _ in $(seq 60); do running || break; sleep 1; done
    cp "$ovmf/OVMF_VARS.4m.fd" "$dir/vars.fd"
    boot "$dir/disk2.qcow2" "$dir/vars.fd"
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
    rm -f "$dir/qemu.pid" "$dir/overlay.qcow2" "$dir/vars.fd" "$dir/disk2.qcow2"
    ;;
*)
    sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'
    exit 2
    ;;
esac
