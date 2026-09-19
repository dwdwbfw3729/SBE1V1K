#!/bin/bash
set -euo pipefail

candidate_dir=$(cd -- "$(dirname -- "$0")" && pwd)
output_dir=${1:?usage: audit-in-linux.sh OUTPUT_DIR TOOLCHAIN_DIR}
toolchain_dir=${2:?usage: audit-in-linux.sh OUTPUT_DIR TOOLCHAIN_DIR}
. "$candidate_dir/sources.lock"

readelf_bin="$toolchain_dir/bin/aarch64-openwrt-linux-musl-readelf"
[ -x "$readelf_bin" ] || {
	printf 'ERROR: target readelf is missing: %s\n' "$readelf_bin" >&2
	exit 1
}

fail() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

curl_bin="$output_dir/runtime-curl/usr/bin/curl-sbe"
openssl_bin="$output_dir/runtime-openssl/usr/bin/openssl3"
ssl_lib="$output_dir/runtime-openssl/usr/lib/libssl.so.3"
crypto_lib="$output_dir/runtime-openssl/usr/lib/libcrypto.so.3"

expected_payload='runtime-curl/usr/bin/curl-sbe
runtime-openssl/etc/ssl3/openssl.cnf
runtime-openssl/usr/bin/openssl3
runtime-openssl/usr/lib/libcrypto.so.3
runtime-openssl/usr/lib/libssl.so.3'
actual_payload=$(cd "$output_dir" && find runtime-curl runtime-openssl -type f | sort)
[ "$actual_payload" = "$expected_payload" ] ||
	fail 'runtime payload is not the five-file allowlist'

for file in "$curl_bin" "$openssl_bin" "$ssl_lib" "$crypto_lib"; do
	[ -f "$file" ] || fail "missing runtime file: $file"
	file "$file" | grep -F 'ELF 64-bit' >/dev/null || fail "$file is not a 64-bit ELF"
	"$readelf_bin" -h "$file" | grep -F 'Machine:                           AArch64' >/dev/null ||
		fail "$file has the wrong architecture"
	"$readelf_bin" -W -l "$file" | grep -F 'GNU_RELRO' >/dev/null || fail "$file lacks GNU_RELRO"
	stack=$("$readelf_bin" -W -l "$file" | awk '$1 == "GNU_STACK" {print $NF}')
	[ -n "$stack" ] || fail "$file lacks GNU_STACK metadata"
	case "$stack" in *E*) fail "$file has an executable stack" ;; esac
	"$readelf_bin" -d "$file" | grep -F '(BIND_NOW)' >/dev/null || fail "$file lacks BIND_NOW"
	if "$readelf_bin" -d "$file" | grep -Eq '\((RPATH|RUNPATH)\)'; then
		fail "$file contains RPATH/RUNPATH"
	fi
	if "$readelf_bin" -S "$file" | grep -Eq '\.debug(_|$)'; then
		fail "$file still contains debug sections"
	fi
done
[ "$(stat -c '%a' "$curl_bin")" = 755 ] || fail 'curl-sbe has the wrong mode'
[ "$(stat -c '%a' "$openssl_bin")" = 755 ] || fail 'openssl3 has the wrong mode'
[ "$(stat -c '%a' "$ssl_lib")" = 644 ] || fail 'libssl.so.3 has the wrong mode'
[ "$(stat -c '%a' "$crypto_lib")" = 644 ] || fail 'libcrypto.so.3 has the wrong mode'
[ "$(stat -c '%a' "$output_dir/runtime-openssl/etc/ssl3/openssl.cnf")" = 644 ] ||
	fail 'openssl.cnf has the wrong mode'

for file in "$curl_bin" "$openssl_bin"; do
	"$readelf_bin" -h "$file" | grep -F 'Type:                              DYN (Shared object file)' >/dev/null ||
		fail "$file is not PIE"
	"$readelf_bin" -W -l "$file" | grep -F '[Requesting program interpreter: /lib/ld-musl-aarch64.so.1]' >/dev/null ||
		fail "$file has the wrong ELF interpreter"
done

"$readelf_bin" -d "$ssl_lib" | grep -F '(SONAME)' | grep -F '[libssl.so.3]' >/dev/null ||
	fail 'libssl candidate has the wrong SONAME'
"$readelf_bin" -d "$crypto_lib" | grep -F '(SONAME)' | grep -F '[libcrypto.so.3]' >/dev/null ||
	fail 'libcrypto candidate has the wrong SONAME'

assert_needed() {
	file=$1
	expected=$2
	actual=$("$readelf_bin" -d "$file" |
		sed -n 's/.*Shared library: \[\(.*\)\]/\1/p' | sort)
	[ "$actual" = "$expected" ] || {
		printf 'Unexpected NEEDED set for %s:\n%s\n' "$file" "$actual" >&2
		fail 'ELF dependency whitelist mismatch'
	}
}
assert_needed "$curl_bin" 'libc.so
libcrypto.so.3
libgcc_s.so.1
libssl.so.3
libz.so.1'
assert_needed "$openssl_bin" 'libc.so
libcrypto.so.3
libgcc_s.so.1
libssl.so.3'
assert_needed "$ssl_lib" 'libc.so
libcrypto.so.3
libgcc_s.so.1'
assert_needed "$crypto_lib" 'libc.so
libgcc_s.so.1'

if find "$output_dir/runtime-openssl" "$output_dir/runtime-curl" -type l -print -quit | grep . >/dev/null; then
	fail 'runtime payload contains a symlink and could shadow a factory ABI'
fi
if find "$output_dir/runtime-openssl" "$output_dir/runtime-curl" -perm -002 -print -quit | grep . >/dev/null; then
	fail 'runtime payload contains a world-writable path'
fi
if find "$output_dir/runtime-openssl" "$output_dir/runtime-curl" -type f \
	\( -name 'libssl.so' -o -name 'libcrypto.so' -o -name 'libcurl.so*' \
	-o -name 'libssl.so.1.1' -o -name 'libcrypto.so.1.1' \) -print -quit | grep . >/dev/null; then
	fail 'runtime payload shadows a factory or development ABI name'
fi

for file in "$curl_bin" "$openssl_bin" "$ssl_lib" "$crypto_lib"; do
	if strings "$file" | grep -E '/(tmp/sbe-tls|repo/|qsdk/|[U]sers/|workspace/|private/var/folders/|home/|root/)' >/dev/null; then
		fail "$file leaks a build/user path"
	fi
done

if grep -R -I -E 'BEGIN (RSA |EC |OPENSSH |)?PRIVATE KEY|/[U]sers/|/workspace/|/repo/|/private/var/folders/|/home/[^/]+/' \
	"$output_dir/runtime-openssl" "$output_dir/runtime-curl" >/dev/null; then
	fail 'runtime payload contains private-key material or a personal/build path'
fi

openssl_ipk=$(find "$output_dir" -maxdepth 1 -name 'sbe-openssl35-candidate_*.ipk' -print -quit)
curl_ipk=$(find "$output_dir" -maxdepth 1 -name 'sbe-curl822-candidate_*.ipk' -print -quit)
[ -n "$openssl_ipk" ] && [ -n "$curl_ipk" ] || fail 'candidate IPKs are missing'

ipk_tmp=$(mktemp -d /tmp/sbe-tls-ipk-audit.XXXXXX)
trap 'rm -rf "$ipk_tmp"' EXIT HUP INT TERM
audit_ipk() {
	ipk=$1
	expected_package=$2
	expected_version=$3
	expected_source=$4
	expected_depends=$5
	runtime_root=$6
	expected_paths=$7
	name=$(basename "$ipk" .ipk)
	extract="$ipk_tmp/$name"
	mkdir -p "$extract"
	outer=$(tar -tzf "$ipk" | sort)
	[ "$outer" = './control.tar.gz
./data.tar.gz
./debian-binary' ] || fail "$ipk has an unexpected outer member"
	control_members=$(tar -xOzf "$ipk" ./control.tar.gz | tar -tzf - | sort)
	[ "$control_members" = './control' ] || fail "$ipk has an unexpected control script/member"
	control=$(tar -xOzf "$ipk" ./control.tar.gz | tar -xOzf - ./control)
	actual_package=$(printf '%s\n' "$control" | sed -n 's/^Package: //p')
	[ "$actual_package" = "$expected_package" ] || fail "$ipk has wrong Package metadata"
	actual_version=$(printf '%s\n' "$control" | sed -n 's/^Version: //p')
	[ "$actual_version" = "$expected_version-1" ] || fail "$ipk has wrong Version metadata"
	actual_arch=$(printf '%s\n' "$control" | sed -n 's/^Architecture: //p')
	[ "$actual_arch" = 'aarch64_cortex-a73_neon-vfpv4' ] || fail "$ipk has wrong Architecture metadata"
	actual_source=$(printf '%s\n' "$control" | sed -n 's/^Source: //p')
	[ "$actual_source" = "$expected_source" ] || fail "$ipk has wrong Source metadata"
	actual_depends=$(printf '%s\n' "$control" | sed -n 's/^Depends: //p')
	[ "$actual_depends" = "$expected_depends" ] || fail "$ipk has wrong Depends metadata"
	if printf '%s\n' "$control" | grep -E '/(Users|workspace|repo|tmp|private/var/folders|home|root)/' >/dev/null; then
		fail "$ipk leaks a path in control metadata"
	fi
	data_archive="$extract/data.tar.gz"
	tar -xOzf "$ipk" ./data.tar.gz >"$data_archive"
	actual_paths=$(tar -tzf "$data_archive" | sed '/\/$/d' | sort)
	[ "$actual_paths" = "$expected_paths" ] || fail "$ipk data payload is outside its allowlist"
	tar -xzf "$data_archive" -C "$extract"
	printf '%s\n' "$actual_paths" | while IFS= read -r member; do
		relative=${member#./}
		cmp "$extract/$relative" "$runtime_root/$relative" >/dev/null ||
			fail "$ipk data differs from audited runtime file: $relative"
		[ "$(stat -c '%a' "$extract/$relative")" = "$(stat -c '%a' "$runtime_root/$relative")" ] ||
			fail "$ipk mode differs from audited runtime file: $relative"
	done
}

audit_ipk "$openssl_ipk" sbe-openssl35-candidate "$OPENSSL_VERSION" \
	"$OPENSSL_ARCHIVE" 'libc, libgcc1' \
	"$output_dir/runtime-openssl" './etc/ssl3/openssl.cnf
./usr/bin/openssl3
./usr/lib/libcrypto.so.3
./usr/lib/libssl.so.3'
audit_ipk "$curl_ipk" sbe-curl822-candidate "$CURL_VERSION" \
	"$CURL_ARCHIVE" 'libc, libgcc1, zlib, sbe-openssl35-candidate' \
	"$output_dir/runtime-curl" './usr/bin/curl-sbe'

(
	cd "$output_dir"
	sha256sum -c SHA256SUMS >/dev/null
)

printf 'ELF ABI, hardening, payload, privacy and IPK metadata: PASS\n'
