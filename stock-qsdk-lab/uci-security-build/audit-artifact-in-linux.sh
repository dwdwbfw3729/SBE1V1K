#!/bin/sh
set -eu

build_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$build_dir/../.." && pwd)
. "$build_dir/sources.lock"

output=${1:-$build_dir/candidate-out/libuci-security}
factory=$repo_root/stock-qsdk-lab/work/v5-root-inspect/lib/libuci.so
candidate=$output/libuci.so
elf=$build_dir/scripts/elf_dynamic.py

fail() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

sha256_file() {
	sha256sum "$1" | awk '{print $1}'
}

[ "$(uname -s)" = Linux ] || fail 'artifact audit must run in Linux'
[ "$(sha256_file "$factory")" = "$FACTORY_LIBUCI_SHA256" ] || fail 'factory libuci hash mismatch'
[ -f "$candidate" ] || fail 'candidate libuci.so is missing'
ipk_count=$(find "$output" -maxdepth 1 -type f -name '*.ipk' -print | wc -l | tr -d ' ')
[ "$ipk_count" -eq 1 ] || fail "expected exactly one candidate IPK, found $ipk_count"
ipk=$(find "$output" -maxdepth 1 -type f -name '*.ipk' -print -quit)

tmp=$(mktemp -d /tmp/sbe-uci-abi.XXXXXX)
cleanup() {
	case "$tmp" in /tmp/sbe-uci-abi.*|/var/tmp/sbe-uci-abi.*) rm -rf "$tmp" ;; esac
}
trap cleanup EXIT HUP INT TERM

python3 "$elf" soname "$factory" > "$tmp/factory.soname"
python3 "$elf" soname "$candidate" > "$tmp/candidate.soname"
cmp -s "$tmp/factory.soname" "$tmp/candidate.soname" || fail 'DT_SONAME differs from factory'
[ "$(cat "$tmp/candidate.soname")" = libuci.so ] || fail 'candidate SONAME is not libuci.so'

python3 "$elf" needed "$factory" > "$tmp/factory.needed"
python3 "$elf" needed "$candidate" > "$tmp/candidate.needed"
cmp -s "$tmp/factory.needed" "$tmp/candidate.needed" || {
	diff -u "$tmp/factory.needed" "$tmp/candidate.needed" >&2 || true
	fail 'DT_NEEDED differs from factory'
}

python3 "$elf" abi "$factory" > "$tmp/factory.abi"
python3 "$elf" abi "$candidate" > "$tmp/candidate.abi"
cmp -s "$tmp/factory.abi" "$tmp/candidate.abi" || {
	diff -u "$tmp/factory.abi" "$tmp/candidate.abi" >&2 || true
	fail 'exported dynamic ABI differs from factory'
}
cp "$tmp/factory.abi" "$output/FACTORY-EXPORTED-ABI.tsv"
cp "$tmp/candidate.abi" "$output/CANDIDATE-EXPORTED-ABI.tsv"
cp "$tmp/factory.needed" "$output/FACTORY-DT_NEEDED.txt"
cp "$tmp/candidate.needed" "$output/CANDIDATE-DT_NEEDED.txt"

header=$(readelf -W -h "$candidate")
printf '%s\n' "$header" | grep -Eq 'Machine:[[:space:]]+AArch64' || fail 'candidate is not AArch64'
printf '%s\n' "$header" | grep -Eq 'Type:[[:space:]]+DYN' || fail 'candidate is not ET_DYN'
program=$(readelf -W -l "$candidate")
printf '%s\n' "$program" | grep -q 'GNU_RELRO' || fail 'candidate lacks GNU_RELRO'
stack=$(printf '%s\n' "$program" | grep 'GNU_STACK' || true)
[ -n "$stack" ] || fail 'candidate lacks GNU_STACK'
printf '%s\n' "$stack" | grep -Eq '[[:space:]]RWE([[:space:]]|$)' && fail 'candidate stack is executable'
dynamic=$(readelf -W -d "$candidate")
printf '%s\n' "$dynamic" | grep -Eq 'BIND_NOW|FLAGS.*NOW' || fail 'candidate lacks full RELRO/NOW'
printf '%s\n' "$dynamic" | grep -Eq '\((RPATH|RUNPATH)\)' && fail 'candidate contains RPATH/RUNPATH'

tar -xzf "$ipk" -C "$tmp"
tar -tzf "$tmp/data.tar.gz" | LC_ALL=C sort > "$tmp/payload-members"
cat > "$tmp/expected-members" <<'EOF'
./
./lib/
./lib/libuci.so
EOF
cmp -s "$tmp/expected-members" "$tmp/payload-members" || {
	cat "$tmp/payload-members" >&2
	fail 'IPK payload differs from the exact /lib/libuci.so allowlist'
}
control=$(tar -xOzf "$tmp/control.tar.gz" ./control)
[ "$(printf '%s\n' "$control" | sed -n 's/^Package: //p')" = libuci20130104 ] || fail 'Package field lost ABI suffix'
[ "$(printf '%s\n' "$control" | sed -n 's/^Version: //p')" = 2019-09-01-415f9e48-5 ] || fail 'Version field mismatch'
[ "$(printf '%s\n' "$control" | sed -n 's/^Architecture: //p')" = aarch64_cortex-a73_neon-vfpv4 ] || fail 'Architecture field mismatch'
printf '%s\n' "$control" | grep -Eq '^Depends: .*libubox' || fail 'libubox dependency is missing'

leak_re='/repo/|/workspace/|/Users/|/Volumes/|/private/tmp/|/home/|BEGIN [A-Z0-9 ]*PRIVATE KEY|OPENSSH PRIVATE KEY'
strings -a "$candidate" | grep -E "$leak_re" >/dev/null 2>&1 && fail 'candidate leaks a build path or key marker'
printf '%s\n' "$control" | grep -E "$leak_re" >/dev/null 2>&1 && fail 'control metadata leaks a path or key marker'

{
	printf 'libuci ABI/artifact audit: PASS\n'
	printf 'package=libuci20130104\n'
	printf 'version=2019-09-01-415f9e48-5\n'
	printf 'architecture=aarch64_cortex-a73_neon-vfpv4\n'
	printf 'payload=/lib/libuci.so only\n'
	printf 'soname=libuci.so exact-factory-match\n'
	printf 'dt_needed=exact-factory-match\n'
	printf 'exported_symbol_tuples=exact-factory-match\n'
	printf 'exported_symbol_count=%s\n' "$(wc -l < "$tmp/candidate.abi" | tr -d ' ')"
	printf 'aarch64_et_dyn_nx_full_relro=yes\n'
	printf 'rpath_runpath=none\n'
	printf 'release_approval=NOT_GRANTED\n'
} > "$output/ABI-AUDIT.txt"
