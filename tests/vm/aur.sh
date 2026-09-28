#!/bin/sh
# aur packages in a vm: a recipe from a local stand-in for the aur,
# reviewed, built in a clean chroot, installed from os's own repository,
# and pinned in the lock. runs after the smoke test.
set -eu
. tests/vm/lib.sh

"$vm" ssh "pacman -S --noconfirm --needed --noprogressbar devtools >/dev/null"
"$vm" ssh "/usr/local/bin/os init >/dev/null 2>&1 || true"

# a recipe in a git repository, where YOQ_AUR points.
recipe() {
    "$vm" ssh "mkdir -p /root/aur/yoq-hello.git && cd /root/aur/yoq-hello.git && git init -q 2>/dev/null; \
printf 'pkgname=yoq-hello\npkgver=%s\npkgrel=1\npkgdesc=\"a package os builds in tests\"\narch=(any)\nlicense=(MIT)\npackage() { install -Dm644 /dev/null \"\$pkgdir/usr/share/yoq-hello/v%s\"; }\n' $1 $1 > PKGBUILD && \
printf 'pkgbase = yoq-hello\n\tpkgdesc = a package os builds in tests\n\tpkgver = %s\n\tpkgrel = 1\n\tarch = any\n\tlicense = MIT\n\npkgname = yoq-hello\n' $1 > .SRCINFO && \
git add -A && git -c user.name=t -c user.email=t@localhost commit -q -m v$1"
}
aur_os() {
    "$vm" ssh "YOQ_AUR=file:///root/aur /usr/local/bin/os $1"
}
# runs os update with no terminal, shows what it said, and leaves its exit
# code in /tmp/rc and its output in /tmp/out.
update_quietly() {
    "$vm" ssh "YOQ_AUR=file:///root/aur /usr/local/bin/os update --yes >/tmp/out 2>&1; echo \$? >/tmp/rc; cat /tmp/out"
}

recipe 1
# a top-level key, so it goes before the config's first table.
"$vm" ssh "sed -i '/^version = /a aur = [\"yoq-hello\"]' /etc/yoq/machine.toml && grep -n '^aur' /etc/yoq/machine.toml"
# without a terminal, a new recipe isn't built unreviewed.
update_quietly
check "cat /tmp/rc" 1
check "grep -c 'review it in a terminal' /tmp/out" 1
check "pacman -Q yoq-hello >/dev/null 2>&1 || echo none" none
aur_os "update --yes --trust-aur"
check "pacman -Q yoq-hello" "yoq-hello 1-1"
check "test -e /usr/share/yoq-hello/v1 && echo built" built
check "grep -A4 '^\[packages.yoq-hello\]' /etc/yoq/machine.lock | grep -c '^recipe = '" 1
check "grep -c '^\[yoq-aur\]' /etc/pacman.d/yoq-repos.conf" 1
# plain pacman reads it too, through the line os added to pacman.conf.
check "grep -c '^Include = /etc/pacman.d/yoq-repos.conf' /etc/pacman.conf" 1
check "pacman -Sy >/dev/null && pacman -Sl yoq-aur | cut -d' ' -f2" yoq-hello
check "/usr/local/bin/os plan" "nothing to do. this machine matches its config."

# a changed recipe is reviewed again, then built and upgraded.
recipe 2
update_quietly
check "cat /tmp/rc" 1
check "grep -c 'recipe is changed' /tmp/out" 1
aur_os "update --yes --trust-aur"
check "pacman -Q yoq-hello" "yoq-hello 2-1"
check "/usr/local/bin/os plan" "nothing to do. this machine matches its config."
echo "aur ok"
