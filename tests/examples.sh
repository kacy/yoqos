#!/bin/sh
# checks every config in examples/: its includes merge and every value
# passes yos's checks. with --resolve, each one also resolves against
# today's arch packages into a lock, which catches a package arch doesn't
# have, or a provider the config should choose. that needs an arch machine
# and a build with -Dalpm, and it changes nothing there. examples with aur
# packages or repositories of their own are only checked, since resolving
# them builds aur packages or trusts another repository's key.
# usage: tests/examples.sh <path to yos> [--resolve]
set -eu

yos=$(realpath "$1")
resolve=${2:-}
failed=0

# resolving writes a lock next to each config, so it runs on a copy.
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cp -r examples "$work/"

for top in $(cd "$work" && find examples -name machine.toml | sort); do
    if ! out=$("$os" --config "$work/$top" config show 2>&1 >/dev/null); then
        echo "fail: $top"
        echo "$out"
        failed=1
        continue
    fi
    if [ "$resolve" != --resolve ]; then
        echo "ok: $top"
        continue
    fi
    if "$os" --config "$work/$top" --json config show | tr -d ' \n' | grep -q -e '"aur":\[{' -e '"repos":{"'; then
        echo "ok: $top (checked; it builds from the aur or trusts another repository)"
        continue
    fi
    if ! out=$("$os" --config "$work/$top" update --no-apply 2>&1); then
        echo "fail: $top doesn't resolve"
        echo "$out"
        failed=1
        continue
    fi
    echo "ok: $top ($(echo "$out" | grep -m 1 '^resolved'))"
done
exit "$failed"
