#!/bin/sh
set -eu

build_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$build_dir/../.." && pwd)
. "$build_dir/sources.lock"
output=${1:-"$build_dir/candidate-out/ubus-security"}
report=$output/ARTIFACT-AUDIT.txt
abi_reference_tree_rel=stock-qsdk-lab/work/audit-current
abi_reference_tree=$repo_root/$abi_reference_tree_rel
factory_lib=$abi_reference_tree/lib/libubus.so.20210603
factory_libubox=$abi_reference_tree/lib/libubox.so
factory_libc=$abi_reference_tree/lib/libc.so
factory_libgcc=$abi_reference_tree/lib/libgcc_s.so.1
elf_dynsym=$repo_root/stock-qsdk-lab/luci-maintenance/elf-dynsym.py

fail() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

[ "$(uname -s)" = Linux ] || fail 'artifact audit must run inside Linux'
[ -d "$output" ] || fail "candidate directory is missing: $output"
rm -f "$report"
for tool in awk cmp comm file grep paste python3 readelf sed sha256sum sort strings tar; do
	command -v "$tool" >/dev/null 2>&1 || fail "$tool is required"
done
[ -f "$factory_lib" ] || fail "factory libubus baseline is missing: $factory_lib"
[ "$(sha256sum "$factory_lib" | awk '{print $1}')" = "$UBUS_FACTORY_LIB_SHA256" ] ||
	fail 'factory libubus hash differs from the reviewed rootfs baseline'
[ "$(sha256sum "$factory_libubox" | awk '{print $1}')" = "$UBUS_FACTORY_LIBUBOX_SHA256" ] ||
	fail 'factory libubox hash differs from the reviewed rootfs baseline'
[ "$(sha256sum "$factory_libc" | awk '{print $1}')" = "$UBUS_FACTORY_LIBC_SHA256" ] ||
	fail 'factory libc hash differs from the reviewed rootfs baseline'
[ "$(sha256sum "$factory_libgcc" | awk '{print $1}')" = "$UBUS_FACTORY_LIBGCC_SHA256" ] ||
	fail 'factory libgcc_s hash differs from the reviewed rootfs baseline'
[ -x "$elf_dynsym" ] || fail 'sectionless ELF dynamic-symbol parser is missing'

tmp=$(mktemp -d /tmp/sbe-ubus-audit.XXXXXX)
cleanup() {
	case "$tmp" in
		/tmp/sbe-ubus-audit.*|/var/tmp/sbe-ubus-audit.*)
			rm -rf "$tmp"
			;;
	esac
}
trap cleanup EXIT HUP INT TERM

cat > "$tmp/expected-packages" <<'EOF'
sbe-libubus-lua2022-comparison-only
sbe-libubus20210603-security-candidate
sbe-ubus2022-security-candidate
sbe-ubusd2022-security-candidate
EOF
cat > "$tmp/expected-ipk-members" <<'EOF'
./control.tar.gz
./data.tar.gz
./debian-binary
EOF
cat > "$tmp/expected-control-members" <<'EOF'
./
./control
./postinst
./prerm
EOF

find "$output" -maxdepth 1 -type f -name '*.ipk' -print | LC_ALL=C sort > "$tmp/ipks"
[ "$(wc -l < "$tmp/ipks" | tr -d ' ')" -eq 4 ] ||
	fail 'expected exactly four candidate IPKs'

leak_re='/repo/|/workspace/|/Users/|/Volumes/|/private/tmp/|/home/|BEGIN [A-Z0-9 ]*PRIVATE KEY|OPENSSH PRIVATE KEY|Proc-Type: 4,ENCRYPTED'
: > "$tmp/packages"
: > "$tmp/elfs"

while IFS= read -r ipk; do
	[ -n "$ipk" ] || continue
	tar -tzf "$ipk" | LC_ALL=C sort > "$tmp/ipk-members"
	cmp -s "$tmp/expected-ipk-members" "$tmp/ipk-members" ||
		fail "IPK container members escaped the allowlist: $ipk"

	data_archive=$tmp/data.tar.gz
	control_archive=$tmp/control.tar.gz
	tar -xOzf "$ipk" ./data.tar.gz > "$data_archive"
	tar -xOzf "$ipk" ./control.tar.gz > "$control_archive"
	tar -tzf "$control_archive" | LC_ALL=C sort > "$tmp/control-members"
	cmp -s "$tmp/expected-control-members" "$tmp/control-members" ||
		fail "control archive members escaped the allowlist: $ipk"
	control_root=$tmp/control-root
	rm -rf "$control_root"
	mkdir -p "$control_root"
	tar -xzf "$control_archive" -C "$control_root"
	for control_member in control postinst prerm; do
		[ -f "$control_root/$control_member" ] && [ ! -L "$control_root/$control_member" ] ||
			fail "control archive member is not a regular file: $ipk:$control_member"
	done
	if LC_ALL=C grep -R -E "$leak_re" "$control_root" >/dev/null 2>&1; then
		fail "control archive leaks a host path or private-key marker: $ipk"
	fi
	control=$(tar -xOzf "$control_archive" ./control) ||
		fail "cannot read control metadata: $ipk"
	pkg=$(printf '%s\n' "$control" | sed -n 's/^Package: //p')
	case "$pkg" in
		sbe-ubus2022-security-candidate)
			expected_payload=/bin/ubus
			;;
		sbe-ubusd2022-security-candidate)
			expected_payload=/sbin/ubusd
			;;
		sbe-libubus20210603-security-candidate)
			expected_payload=/lib/libubus.so.20210603
			;;
		sbe-libubus-lua2022-comparison-only)
			expected_payload=/usr/lib/lua/ubus.so
			;;
		*)
			fail "unexpected Package field in $ipk: ${pkg:-missing}"
			;;
	esac
	expected_filename=${pkg}_${UBUS_PACKAGE_VERSION}-${UBUS_PACKAGE_RELEASE}_${UBUS_PACKAGE_ARCH}.ipk
	[ "$(basename "$ipk")" = "$expected_filename" ] ||
		fail "filename does not match the locked package identity: $ipk"
	[ "$(printf '%s\n' "$control" | sed -n 's/^Architecture: //p')" = \
		"$UBUS_PACKAGE_ARCH" ] || fail "unexpected package architecture: $ipk"
	[ "$(printf '%s\n' "$control" | sed -n 's/^Version: //p')" = \
		"$UBUS_PACKAGE_VERSION-$UBUS_PACKAGE_RELEASE" ] || fail "unexpected package version: $ipk"
	[ "$(printf '%s\n' "$control" | sed -n 's/^Source: //p')" = "$UBUS_ARCHIVE" ] ||
		fail "unexpected Source metadata: $ipk"
	printf '%s\n' "$pkg" >> "$tmp/packages"

	tar -tzf "$data_archive" > "$tmp/$pkg.members"
	while IFS= read -r member; do
		case "$member" in
			.|./|./*/) ;;
			./*)
				relative=${member#./}
				case "$relative" in
					''|/*|..|../*|*/..|*/../*)
						fail "unsafe payload member in $ipk: $member"
						;;
				esac
				;;
			*) fail "non-canonical payload member in $ipk: $member" ;;
		esac
	done < "$tmp/$pkg.members"

	pkgroot=$tmp/root-$pkg
	mkdir -p "$pkgroot"
	tar -xzf "$data_archive" -C "$pkgroot"
	find "$pkgroot" ! -type d -print | sed "s#^$pkgroot##" | LC_ALL=C sort > \
		"$tmp/$pkg.payload"
	printf '%s\n' "$expected_payload" > "$tmp/$pkg.expected"
	cmp -s "$tmp/$pkg.expected" "$tmp/$pkg.payload" ||
		fail "$pkg payload differs from the single locked path $expected_payload"
	elf=$pkgroot$expected_payload
	[ -f "$elf" ] && [ ! -L "$elf" ] ||
		fail "$pkg payload is not one regular ELF file"
	printf '%s\n' "$elf" >> "$tmp/elfs"
	strings -a "$elf" | LC_ALL=C grep -E "$leak_re" >/dev/null 2>&1 &&
		fail "payload leaks a host path or private-key marker: $pkg"
done < "$tmp/ipks"

LC_ALL=C sort "$tmp/packages" > "$tmp/packages.sorted"
cmp -s "$tmp/expected-packages" "$tmp/packages.sorted" ||
	fail 'candidate package set differs from the locked four-package set'

while IFS= read -r elf; do
	header=$(readelf -W -h "$elf")
	printf '%s\n' "$header" | grep -Eq 'Machine:[[:space:]]+AArch64' ||
		fail "non-AArch64 ELF: $elf"
	printf '%s\n' "$header" | grep -Eq 'Type:[[:space:]]+DYN' ||
		fail "ELF is not PIE/shared-object type: $elf"
	program=$(readelf -W -l "$elf")
	printf '%s\n' "$program" | grep -q 'GNU_RELRO' || fail "missing GNU_RELRO: $elf"
	stack=$(printf '%s\n' "$program" | grep 'GNU_STACK' || true)
	[ -n "$stack" ] || fail "missing GNU_STACK: $elf"
	printf '%s\n' "$stack" | grep -Eq '[[:space:]]RWE([[:space:]]|$)' &&
		fail "executable stack: $elf"
	dynamic=$(readelf -W -d "$elf")
	printf '%s\n' "$dynamic" | grep -Eq 'BIND_NOW|FLAGS.*NOW' ||
		fail "missing full RELRO NOW binding: $elf"
	printf '%s\n' "$dynamic" | grep -Eq '\((RPATH|RUNPATH)\)' &&
		fail "RPATH/RUNPATH present: $elf"
done < "$tmp/elfs"

ubus=$tmp/root-sbe-ubus2022-security-candidate/bin/ubus
ubusd=$tmp/root-sbe-ubusd2022-security-candidate/sbin/ubusd
libubus=$tmp/root-sbe-libubus20210603-security-candidate/lib/libubus.so.20210603
lua=$tmp/root-sbe-libubus-lua2022-comparison-only/usr/lib/lua/ubus.so
for executable in "$ubus" "$ubusd"; do
	readelf -W -l "$executable" | grep -q 'Requesting program interpreter' ||
		fail "DYN executable is not a PIE program: $executable"
done
readelf -W -d "$libubus" | grep -Eq '\(SONAME\).+\[libubus\.so\.20210603\]' ||
	fail 'candidate libubus changed the factory SONAME'
for consumer in "$ubus" "$lua"; do
	readelf -W -d "$consumer" | grep -Eq '\(NEEDED\).+\[libubus\.so\.20210603\]' ||
		fail "candidate consumer changed the factory libubus ABI: $consumer"
done
if readelf -W -d "$ubusd" | grep -Eq '\(NEEDED\).+\[libubus\.so'; then
	fail 'daemon unexpectedly links libubus; daemon-only promotion is no longer isolated'
fi

python3 "$elf_dynsym" --kind defined "$factory_lib" > "$tmp/factory.defined"
python3 "$elf_dynsym" --kind defined "$libubus" > "$tmp/candidate.defined"
cmp -s "$tmp/factory.defined" "$tmp/candidate.defined" ||
	fail 'candidate libubus exported symbol ABI differs from the factory library'
readelf -W -d "$factory_lib" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p' |
	LC_ALL=C sort > "$tmp/factory.needed"
readelf -W -d "$libubus" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p' |
	LC_ALL=C sort > "$tmp/candidate.needed"
comm -13 "$tmp/factory.needed" "$tmp/candidate.needed" > "$tmp/needed.added"
comm -23 "$tmp/factory.needed" "$tmp/candidate.needed" > "$tmp/needed.removed"
[ ! -s "$tmp/needed.added" ] ||
	fail 'candidate libubus adds a dependency outside the factory closure'
needed_removed=$(paste -sd, "$tmp/needed.removed")
[ -n "$needed_removed" ] || needed_removed=none

# Prove that a removed DT_NEEDED is genuinely unused rather than assuming that
# a smaller dynamic section is safe.  Only strong undefined symbols must be
# supplied by a provider; weak frame-registration hooks are optional by ELF
# contract and are intentionally recorded separately.
python3 "$elf_dynsym" --kind undefined "$libubus" |
	awk -F '\t' '$2 != "WEAK" { print $5 }' | LC_ALL=C sort -u > "$tmp/candidate.strong-undefined"
python3 "$elf_dynsym" --kind undefined "$libubus" |
	awk -F '\t' '$2 == "WEAK" { print $5 }' | LC_ALL=C sort -u > "$tmp/candidate.weak-undefined"
{
	python3 "$elf_dynsym" --kind defined "$factory_libubox"
	python3 "$elf_dynsym" --kind defined "$factory_libc"
} | awk -F '\t' '{ print $5 }' | LC_ALL=C sort -u > "$tmp/retained-provider.defined"
python3 "$elf_dynsym" --kind defined "$factory_libgcc" |
	awk -F '\t' '{ print $5 }' | LC_ALL=C sort -u > "$tmp/libgcc.defined"
comm -23 "$tmp/candidate.strong-undefined" "$tmp/retained-provider.defined" > \
	"$tmp/candidate.unresolved-strong"
[ ! -s "$tmp/candidate.unresolved-strong" ] || {
	printf 'ERROR: candidate has strong undefined symbols outside retained DT_NEEDED providers:\n' >&2
	cat "$tmp/candidate.unresolved-strong" >&2
	exit 1
}
comm -12 "$tmp/candidate.strong-undefined" "$tmp/libgcc.defined" > \
	"$tmp/candidate.libgcc-required"
[ ! -s "$tmp/candidate.libgcc-required" ] || {
	printf 'ERROR: candidate still requires GCC runtime symbols despite removing libgcc_s:\n' >&2
	cat "$tmp/candidate.libgcc-required" >&2
	exit 1
}

{
	printf 'factory DT_NEEDED:\n'
	sed 's/^/  /' "$tmp/factory.needed"
	printf 'candidate DT_NEEDED:\n'
	sed 's/^/  /' "$tmp/candidate.needed"
	printf 'added:\n'
	if [ -s "$tmp/needed.added" ]; then sed 's/^/  /' "$tmp/needed.added"; else printf '  none\n'; fi
	printf 'removed:\n'
	if [ -s "$tmp/needed.removed" ]; then sed 's/^/  /' "$tmp/needed.removed"; else printf '  none\n'; fi
	printf 'reason: the QSDK candidate link uses --as-needed; libgcc_s.so.1 supplied no candidate strong undefined symbol and was dropped.\n'
} > "$output/ABI-NEEDED-DIFF.txt"
{
	printf 'candidate strong undefined symbols: %s\n' "$(wc -l < "$tmp/candidate.strong-undefined" | tr -d ' ')"
	printf 'unresolved by retained providers libubox.so + libc.so: 0\n'
	printf 'candidate strong undefined symbols supplied by libgcc_s.so.1: 0\n'
	printf 'candidate weak undefined symbols (optional ELF hooks):\n'
	if [ -s "$tmp/candidate.weak-undefined" ]; then sed 's/^/  /' "$tmp/candidate.weak-undefined"; else printf '  none\n'; fi
	printf 'provider hashes:\n'
	printf '  libubox.so %s\n' "$UBUS_FACTORY_LIBUBOX_SHA256"
	printf '  libc.so %s\n' "$UBUS_FACTORY_LIBC_SHA256"
	printf '  libgcc_s.so.1 %s\n' "$UBUS_FACTORY_LIBGCC_SHA256"
} > "$output/GCC-RUNTIME-RESOLUTION.txt"
{
	printf 'factory and candidate defined dynamic-symbol tables: byte-identical\n'
	printf 'defined symbol rows: %s\n' "$(wc -l < "$tmp/candidate.defined" | tr -d ' ')"
} > "$output/ABI-EXPORT-DIFF.txt"

: > "$tmp/libubus-consumers"
find "$abi_reference_tree" -type f -print | LC_ALL=C sort | while IFS= read -r consumer; do
	file "$consumer" | grep -q 'ELF 64-bit.*ARM aarch64' || continue
	readelf -W -d "$consumer" 2>/dev/null |
		grep -q '\(NEEDED\).*\[libubus\.so\.20210603\]' || continue
	printf '%s\n' "${consumer#"$abi_reference_tree"}"
done > "$tmp/libubus-consumers"
consumer_count=$(wc -l < "$tmp/libubus-consumers" | tr -d ' ')
[ "$consumer_count" -gt 0 ] || fail 'no ABI-reference-tree libubus consumer was found'

(cd "$output" && sha256sum ./*.ipk | LC_ALL=C sort -k2) > "$tmp/PACKAGE_SHA256SUMS"
[ -f "$output/PACKAGE_SHA256SUMS" ] || fail 'PACKAGE_SHA256SUMS is missing'
cmp -s "$tmp/PACKAGE_SHA256SUMS" "$output/PACKAGE_SHA256SUMS" ||
	fail 'PACKAGE_SHA256SUMS does not match the exact four IPKs'
if [ -f "$output/CANDIDATE_BUILD_CONFIG" ] &&
	LC_ALL=C grep -E "$leak_re" "$output/CANDIDATE_BUILD_CONFIG" >/dev/null 2>&1; then
	fail 'candidate build configuration leaks a host path or private-key marker'
fi

"$build_dir/promotion-policy.sh" native-atomic \
	sbe-ubus2022-security-candidate \
	sbe-ubusd2022-security-candidate \
	sbe-libubus20210603-security-candidate >/dev/null
"$build_dir/promotion-policy.sh" comparison-only \
	sbe-libubus-lua2022-comparison-only >/dev/null

{
	printf 'ubus-security artifact audit: PASS\n'
	printf 'packages=4\n'
	printf 'payload_members=4\n'
	printf 'elf_machine=AArch64\n'
	printf 'pie_executables=yes\n'
	printf 'nx_full_relro=yes\n'
	printf 'rpath_runpath=none\n'
	printf 'host_path_private_key_leaks=none\n'
	printf 'libubus_soname=libubus.so.20210603\n'
	printf 'libubus_exports=exact-factory-match\n'
	printf 'libubus_needed_added=none\n'
	printf 'libubus_needed_removed=%s\n' "$needed_removed"
	printf 'libubus_removed_dependency_reason=linker-as-needed-dropped-unused-libgcc_s.so.1\n'
	printf 'candidate_unresolved_strong_symbols=none\n'
	printf 'candidate_required_gcc_runtime_symbols=none\n'
	printf 'consumer_scan_scope=abi-reference-minimal-extraction\n'
	printf 'consumer_dependency_kind=direct-DT_NEEDED-libubus.so.20210603\n'
	printf 'abi_reference_tree=%s\n' "$abi_reference_tree_rel"
	printf 'abi_reference_tree_direct_libubus_consumer_count=%s\n' "$consumer_count"
	sed 's/^/abi_reference_tree_direct_consumer=/' "$tmp/libubus-consumers"
	printf 'native_atomic=sbe-ubus2022-security-candidate,sbe-ubusd2022-security-candidate,sbe-libubus20210603-security-candidate\n'
	printf 'comparison_only=sbe-libubus-lua2022-comparison-only\n'
	printf 'release_approval=NOT_GRANTED\n'
} > "$report"

printf 'PASS: four exact ubus payloads are AArch64 PIE/shared, NX/full-RELRO and path-clean.\n'
