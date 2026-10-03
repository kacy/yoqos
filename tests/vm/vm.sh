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
#   snapper      archinstall's defaults again, for tests/vm/snapper.sh to
#                set up snapper and boot a root its rollback made
#   sdboot       archinstall with systemd-boot
#
#   vm.sh image              make the base image, once
#   vm.sh start              boot a fresh overlay and wait for ssh; with
#                            VM_DISK2=1, a blank second disk too, and with
#                            VM_DISK3=1, a third
#   vm.sh start-iso <iso>    boot a live iso with a blank disk, as a new
#                            machine would
#   vm.sh start-installed [disk3]
#                            power off and boot the second disk alone, or
#                            the third, with blank firmware variables, like
#                            a new machine
#   vm.sh ssh <command>      run a command in the vm as root
#   vm.sh copy <file> <dest> copy a file into the vm
#   vm.sh reboot             reboot and wait for ssh
#   vm.sh reboot-answer <prompt> <text>
#                            reboot, type <text> at the serial console once
#                            it shows <prompt>, like a luks passphrase, and
#                            wait for ssh. needs VM_SERIAL_IN. with
#                            VM_ANSWER_MAYBE=1, a boot that comes up
#                            without the prompt is fine too. it prints
#                            "answered" when it typed
#   vm.sh diagnose           ask the serial console's root shell for the
#                            vm's network and sshd state, as a vm that
#                            stops answering over ssh does by itself.
#                            needs VM_SERIAL_IN
#   vm.sh stop               power off and throw the overlay away
#
# VM_TPM=1 gives the vm a tpm 2.0, from swtpm. a start or start-iso begins
# with a blank one, and start-installed keeps it, so a key the vm put there
# is still there for the disk it boots.
#
# VM_SECBOOT=1 boots firmware that can enforce secure boot, with smm, on
# the same firmware variables, which have no keys: it starts in setup
# mode, where it enforces nothing until keys are enrolled.
#
# VM_SERIAL_IN=1 makes the serial console a socket as well as the log, so
# reboot-answer can type at it.
#
# needs qemu, edk2-ovmf, xorriso, and openssh, swtpm for VM_TPM, and socat
# for VM_SERIAL_IN. VM_DIR sets where the images and the running vm's
# files live.
set -eu

dir=${VM_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/yos-vm}
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
    diagnose
    exit 1
}

# asks the serial console of a vm that doesn't answer over ssh what it
# says about its network and sshd. needs VM_SERIAL_IN, and a root shell
# there, which test.sh's autologin gives every vm.
diagnose() {
    [ -S "$dir/serial.sock" ] || return 0
    from=$(($(wc -c < "$dir/console.log") + 1))
    for line in "" "export SYSTEMD_COLORS=0 SYSTEMD_PAGER=; echo yos-diag-start; ip -br addr; ip route; systemctl is-active sshd NetworkManager systemd-networkd; systemctl --failed --no-legend; ss -tln; journalctl -b --no-pager -o short-monotonic -u NetworkManager -u systemd-networkd -u sshd | tail -n 40; echo yos-diag-end"; do
        printf '%s\r' "$line" | socat - UNIX-CONNECT:"$dir/serial.sock" || return 0
        sleep 3
    done
    sleep 10
    echo "--- what the vm says, from its serial console" >&2
    # the shell marks its prompts and commands with escape sequences of its
    # own (osc 3008), which come off with the colors.
    tail -c +"$from" "$dir/console.log" | tr -d '\r' |
        sed -e 's/\x1b\[[0-9;?=!]*[a-zA-Z]//g' -e 's/\x1b\][^\x07\x1b]*\(\x07\|\x1b\\\)//g' |
        sed -n '/yos-diag-start$/,/yos-diag-end$/p' >&2
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
    printf 'instance-id: yos-test\nlocal-hostname: yos-test\n' > "$dir/seed/meta-data"
    xorriso -as mkisofs -quiet -o "$dir/seed.iso" -V cidata -J -r "$dir/seed/user-data" "$dir/seed/meta-data"
}

# whether qemu is still running. it removes its pid file when it stops.
running() {
    [ -f "$dir/qemu.pid" ] && kill -0 "$(cat "$dir/qemu.pid")" 2>/dev/null
}

# starts swtpm for the next qemu, on the tpm state in $dir/tpm. it stops
# when qemu lets go of it.
start_tpm() {
    stop_tpm
    mkdir -p "$dir/tpm"
    rm -f "$dir/tpm.sock"
    swtpm socket --tpm2 --tpmstate dir="$dir/tpm" --ctrl type=unixio,path="$dir/tpm.sock" \
        --terminate --daemon --pid file="$dir/swtpm.pid" --log file="$dir/swtpm.log"
    for _ in $(seq 50); do [ -S "$dir/tpm.sock" ] && return 0; sleep 0.1; done
    echo "vm: swtpm didn't start; its log is $dir/swtpm.log" >&2
    exit 1
}

stop_tpm() {
    if [ -f "$dir/swtpm.pid" ]; then kill "$(cat "$dir/swtpm.pid")" 2>/dev/null || true; fi
    rm -f "$dir/swtpm.pid"
}

# boots <disk> with the firmware variables in <vars>, plus any extra qemu
# arguments, and waits for ssh.
boot() {
    disk=$1 vars=$2
    shift 2
    if [ -n "${VM_TPM:-}" ]; then
        start_tpm
        set -- "$@" -chardev socket,id=chrtpm,path="$dir/tpm.sock" -tpmdev emulator,id=tpm0,chardev=chrtpm -device tpm-tis,tpmdev=tpm0
    fi
    code=OVMF_CODE.4m.fd machine=q35
    if [ -n "${VM_SECBOOT:-}" ]; then
        # the secure boot build keeps its variables behind smm.
        code=OVMF_CODE.secboot.4m.fd machine=q35,smm=on
        set -- "$@" -global driver=cfi.pflash01,property=secure,value=on
    fi
    if [ -n "${VM_SERIAL_IN:-}" ]; then
        rm -f "$dir/serial.sock"
        set -- "$@" -chardev socket,id=serial,path="$dir/serial.sock",server=on,wait=off,logfile="$dir/console.log",logappend=off -serial chardev:serial
    else
        set -- "$@" -serial file:"$dir/console.log"
    fi
    seed
    qemu-system-x86_64 -enable-kvm -cpu host -machine "$machine" -smp 2 -m 2048 \
        -drive if=pflash,format=raw,readonly=on,file="$ovmf/$code" \
        -drive if=pflash,format=raw,file="$vars" \
        -drive if=virtio,file="$disk" \
        -drive media=cdrom,file="$dir/seed.iso" \
        -netdev user,id=net,hostfwd=tcp:127.0.0.1:"$port"-:22 -device virtio-net-pci,netdev=net \
        -display none \
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

# the test image's root password, "yos". tests log in with the key.
root_hash='$6$yostest$JTDVgwmpDH/rIv3Uo09iioZFrv.xRS4jXLHm6TdyrCFjurZ4wyGrGdWEHX/aTSBS2X.cl9ymPESR953IFz1az0'

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
    snapper) archinstall ;;
    sdboot) archinstall -e 's|"bootloader": "Grub"|"bootloader": "Systemd-boot"|' ;;
    *) echo "vm: no image called $image" >&2; exit 2 ;;
    esac
    ;;
start)
    [ -f "$dir/$image.qcow2" ] || { echo "vm: no $image image; run vm.sh image" >&2; exit 1; }
    fresh "$image"
    rm -rf "$dir/tpm"
    set --
    if [ -n "${VM_DISK2:-}" ]; then
        qemu-img create -q -f qcow2 "$dir/disk2.qcow2" 20G
        set -- "$@" -drive if=virtio,file="$dir/disk2.qcow2"
    fi
    if [ -n "${VM_DISK3:-}" ]; then
        qemu-img create -q -f qcow2 "$dir/disk3.qcow2" 20G
        set -- "$@" -drive if=virtio,file="$dir/disk3.qcow2"
    fi
    boot "$dir/overlay.qcow2" "$dir/vars.fd" "$@"
    ;;
start-iso)
    mkdir -p "$dir"
    rm -rf "$dir/tpm"
    qemu-img create -q -f qcow2 "$dir/disk2.qcow2" 20G
    cp "$ovmf/OVMF_VARS.4m.fd" "$dir/vars.fd"
    boot "$dir/disk2.qcow2" "$dir/vars.fd" -drive media=cdrom,readonly=on,file="$2"
    ;;
start-installed)
    if running; then kill "$(cat "$dir/qemu.pid")"; fi
    for _ in $(seq 60); do running || break; sleep 1; done
    cp "$ovmf/OVMF_VARS.4m.fd" "$dir/vars.fd"
    boot "$dir/${2:-disk2}.qcow2" "$dir/vars.fd"
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
reboot-answer)
    old=$(run cat /proc/sys/kernel/random/boot_id)
    from=$(($(stat -c %s "$dir/console.log") + 1))
    run systemctl reboot || true
    for _ in $(seq 100); do
        tail -c +"$from" "$dir/console.log" | grep -a -- "$2" >/dev/null && break
        if [ -n "${VM_ANSWER_MAYBE:-}" ]; then
            id=$(timeout 20 ssh $ssh_opts -p "$port" root@127.0.0.1 cat /proc/sys/kernel/random/boot_id 2>/dev/null || true)
            if [ -n "$id" ] && [ "$id" != "$old" ]; then exit 0; fi
        fi
        sleep 3
    done
    if ! tail -c +"$from" "$dir/console.log" | grep -a -- "$2" >/dev/null; then
        echo "vm: no '$2' on the console after 5 minutes; the console log is $dir/console.log" >&2
        exit 1
    fi
    # VM_ANSWER_DELAY waits that many seconds first, like someone slow.
    sleep "${VM_ANSWER_DELAY:-1}"
    printf '%s\r' "$3" | socat - UNIX-CONNECT:"$dir/serial.sock"
    wait_boot "$old"
    echo answered
    ;;
diagnose)
    # the same report a vm that stops answering gets, on demand, then out
    # of the serial console's shell again.
    diagnose
    printf 'exit\r' | socat - UNIX-CONNECT:"$dir/serial.sock"
    ;;
stop)
    if [ -f "$dir/qemu.pid" ]; then kill "$(cat "$dir/qemu.pid")" 2>/dev/null || true; fi
    stop_tpm
    rm -rf "$dir/qemu.pid" "$dir/overlay.qcow2" "$dir/vars.fd" "$dir/disk2.qcow2" "$dir/disk3.qcow2" "$dir/tpm"
    ;;
*)
    sed -n '2,48p' "$0" | sed 's/^# \{0,1\}//'
    exit 2
    ;;
esac
