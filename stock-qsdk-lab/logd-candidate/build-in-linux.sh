#!/bin/sh
set -eu

[ "$(uname -s)" = Linux ] || {
	printf 'ERROR: this helper must run in Linux.\n' >&2
	exit 1
}
[ "$#" -eq 3 ] || {
	printf 'usage: %s QSDK_SOURCE_ROOT CACHE_DIR OUTPUT_DIR\n' "$0" >&2
	exit 2
}
source_root=$1
cache_dir=$2
output_dir=$3
candidate_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$candidate_dir/sources.lock"

toolchain_dir=$source_root/qsdk/staging_dir/toolchain-aarch64_cortex-a73+neon-vfpv4_gcc-7.5.0_musl
target_dir=$source_root/qsdk/staging_dir/target-aarch64_cortex-a73+neon-vfpv4_musl
cross=$toolchain_dir/bin/aarch64-openwrt-linux-musl-
cc=${cross}gcc
strip=${cross}strip
readelf=${cross}readelf
strings=${cross}strings
export STAGING_DIR=$source_root/qsdk/staging_dir

for required in "$cc" "$strip" "$readelf" "$strings"; do
	[ -x "$required" ] || {
		printf 'ERROR: required QSDK toolchain component is absent: %s\n' "$required" >&2
		exit 1
	}
done
for required in \
	"$target_dir/usr/include/libubus.h" \
	"$target_dir/usr/include/libubox/uloop.h" \
	"$target_dir/usr/lib/libubox.so" \
	"$target_dir/usr/lib/libubus.so" \
	"$target_dir/usr/lib/libblobmsg_json.so" \
	"$target_dir/usr/lib/libjson-c.so"; do
	[ -e "$required" ] || {
		printf 'ERROR: required locked QSDK header or library is absent: %s\n' "$required" >&2
		exit 1
	}
done
"$candidate_dir/verify-sources.sh" "$cache_dir" "$source_root"

work_root=$(mktemp -d /tmp/sbe-logd-candidate.XXXXXX)
cleanup() {
	rm -rf "$work_root"
}
trap cleanup EXIT HUP INT TERM

common_cflags="-Os -pipe -mcpu=cortex-a73+crypto -fPIE -fstack-protector-strong -D_FORTIFY_SOURCE=2 -Wformat -Wformat-security -Wall -Werror --std=gnu99 -Wmissing-declarations"
common_ldflags="-Wl,-z,relro -Wl,-z,now -pie -L$target_dir/usr/lib -Wl,-rpath-link,$target_dir/usr/lib"

build_once() {
	run=$1
	run_root=$work_root/run-$run
	mkdir -p "$run_root"
	tar -xJf "$cache_dir/$UBOX_ARCHIVE" -C "$run_root"
	source_dir=$run_root/ubox-2019-06-16-4df34a4d
	[ -f "$source_dir/log/logd.c" ] && [ -f "$source_dir/log/logread.c" ] || {
		printf 'ERROR: unexpected ubox source archive layout.\n' >&2
		exit 1
	}
	prefix_map=-fdebug-prefix-map=$source_dir=.

	"$cc" $common_cflags "$prefix_map" -I"$target_dir/usr/include" \
		-o "$run_root/logd" "$source_dir/log/logd.c" "$source_dir/log/syslog.c" \
		$common_ldflags -lubox -lubus
	"$cc" $common_cflags "$prefix_map" -I"$target_dir/usr/include" \
		-o "$run_root/logread" "$source_dir/log/logread.c" \
		$common_ldflags -lubox -lubus -ljson-c -lblobmsg_json
	"$strip" --strip-all "$run_root/logd" "$run_root/logread"
	chmod 0755 "$run_root/logd" "$run_root/logread"
}

build_once 1
build_once 2

for program in logd logread; do
	hash1=$(sha256sum "$work_root/run-1/$program" | awk '{print $1}')
	hash2=$(sha256sum "$work_root/run-2/$program" | awk '{print $1}')
	[ "$hash1" = "$hash2" ] && cmp -s "$work_root/run-1/$program" "$work_root/run-2/$program" || {
		printf 'ERROR: two clean %s builds were not byte-identical: %s != %s\n' "$program" "$hash1" "$hash2" >&2
		exit 1
	}

	"$readelf" -h "$work_root/run-1/$program" > "$work_root/$program.elf-header.txt"
	"$readelf" -W -l "$work_root/run-1/$program" > "$work_root/$program.elf-program-headers.txt"
	"$readelf" -W -d "$work_root/run-1/$program" > "$work_root/$program.elf-dynamic.txt"
	grep -q 'Machine:.*AArch64' "$work_root/$program.elf-header.txt"
	grep -q 'Type:.*DYN' "$work_root/$program.elf-header.txt"
	grep -q 'Requesting program interpreter: /lib/ld-musl-aarch64.so.1' "$work_root/$program.elf-program-headers.txt"
	grep -q 'GNU_RELRO' "$work_root/$program.elf-program-headers.txt"
	grep -q 'BIND_NOW' "$work_root/$program.elf-dynamic.txt"
	if grep -Eq '\((RPATH|RUNPATH)\)' "$work_root/$program.elf-dynamic.txt"; then
		printf 'ERROR: %s unexpectedly contains RPATH or RUNPATH.\n' "$program" >&2
		exit 1
	fi
	stack_flags=$(awk '$1 == "GNU_STACK" {print $7}' "$work_root/$program.elf-program-headers.txt")
	[ -n "$stack_flags" ] && ! printf '%s\n' "$stack_flags" | grep -q E || {
		printf 'ERROR: %s GNU_STACK is missing or executable.\n' "$program" >&2
		exit 1
	}

	"$strings" -a "$work_root/run-1/$program" > "$work_root/$program.strings"
	if grep -E -i '(/Users/yangzhg|yangzhg|/Users/|sbe-logd-candidate\.|opensync|plume|warehouse|sshm|cujo|BEGIN (RSA |OPENSSH )?PRIVATE KEY)' \
		"$work_root/$program.strings" > "$work_root/$program.privacy-rejects.txt"; then
		printf 'ERROR: %s contains a private build path, identity or operator-control marker.\n' "$program" >&2
		cat "$work_root/$program.privacy-rejects.txt" >&2
		exit 1
	fi
done

grep -q 'Shared library: \[libubox.so\]' "$work_root/logd.elf-dynamic.txt"
grep -q 'Shared library: \[libubus.so.20210603\]' "$work_root/logd.elf-dynamic.txt"
grep -q 'Shared library: \[libubox.so\]' "$work_root/logread.elf-dynamic.txt"
grep -q 'Shared library: \[libubus.so.20210603\]' "$work_root/logread.elf-dynamic.txt"
grep -q 'Shared library: \[libjson-c.so.2\]' "$work_root/logread.elf-dynamic.txt"
grep -q 'Shared library: \[libblobmsg_json.so\]' "$work_root/logread.elf-dynamic.txt"

mkdir -p "$output_dir"
cp "$work_root/run-1/logd" "$output_dir/logd"
cp "$work_root/run-1/logread" "$output_dir/logread"
cp "$work_root/"*.elf-*.txt "$output_dir/"

payload_root=$work_root/rootfs-payload
mkdir -p "$payload_root/sbin" "$payload_root/etc/init.d" "$payload_root/etc/rc.d"
install -m 0755 "$work_root/run-1/logd" "$payload_root/sbin/logd"
install -m 0755 "$work_root/run-1/logread" "$payload_root/sbin/logread"
install -m 0755 "$candidate_dir/rootfs-payload/etc/init.d/log" "$payload_root/etc/init.d/log"
ln -s ../init.d/log "$payload_root/etc/rc.d/S12log"
ln -s ../init.d/log "$payload_root/etc/rc.d/K89log"
tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner \
	-C "$payload_root" -cf "$output_dir/logd-rootfs-payload.tar" .
tar -tf "$output_dir/logd-rootfs-payload.tar" > "$output_dir/logd-rootfs-payload.list"
if grep -Eq '^\./(lib|usr/lib)/' "$output_dir/logd-rootfs-payload.list"; then
	printf 'ERROR: payload unexpectedly contains an ABI library.\n' >&2
	exit 1
fi
grep -qx './sbin/logd' "$output_dir/logd-rootfs-payload.list"
grep -qx './sbin/logread' "$output_dir/logd-rootfs-payload.list"
grep -qx './etc/init.d/log' "$output_dir/logd-rootfs-payload.list"
grep -qx './etc/rc.d/S12log' "$output_dir/logd-rootfs-payload.list"
grep -qx './etc/rc.d/K89log' "$output_dir/logd-rootfs-payload.list"

"$candidate_dir/test-in-linux.sh" "$source_root" "$output_dir"

logd_sha=$(sha256sum "$output_dir/logd" | awk '{print $1}')
logread_sha=$(sha256sum "$output_dir/logread" | awk '{print $1}')
payload_sha=$(sha256sum "$output_dir/logd-rootfs-payload.tar" | awk '{print $1}')
{
	printf 'UBOX_SOURCE_DATE=%s\n' "$UBOX_SOURCE_DATE"
	printf 'UBOX_SOURCE_VERSION=%s\n' "$UBOX_SOURCE_VERSION"
	printf 'QSDK_UBOX_PACKAGE_RELEASE=%s\n' "$QSDK_UBOX_PACKAGE_RELEASE"
	printf 'UBOX_SOURCE_SHA256=%s\n' "$UBOX_SHA256"
	printf 'TOOLCHAIN_TRIPLE=aarch64-openwrt-linux-musl\n'
	printf 'TOOLCHAIN_GCC_VERSION=7.5.0\n'
	printf 'LOGD_SHA256=%s\n' "$logd_sha"
	printf 'LOGD_SIZE=%s\n' "$(wc -c < "$output_dir/logd" | tr -d ' ')"
	printf 'LOGREAD_SHA256=%s\n' "$logread_sha"
	printf 'LOGREAD_SIZE=%s\n' "$(wc -c < "$output_dir/logread" | tr -d ' ')"
	printf 'LOGD_ROOTFS_PAYLOAD_SHA256=%s\n' "$payload_sha"
	printf 'BUILD_REPETITIONS=2\n'
	printf 'BUILD_BYTE_IDENTICAL=yes\n'
	printf 'RUNTIME_MEMORY_TEST=pass\n'
	printf 'RUNTIME_FILE_TEST=pass\n'
	printf 'RUNTIME_UDP_TEST=pass\n'
	printf 'RUNTIME_TCP_TEST=pass\n'
	printf 'ABI_LIBRARIES_INCLUDED=no\n'
	printf 'ROOTFS_INTEGRATED=no\n'
	printf 'DEVICE_WRITTEN=no\n'
} > "$output_dir/build-manifest.env"
(
	cd "$output_dir"
	sha256sum logd logread logd-rootfs-payload.tar
) > "$output_dir/SHA256SUMS"

printf 'logd/logread candidate passed deterministic build, ELF, privacy and isolated runtime gates.\n'
printf 'Candidate payload: %s\n' "$output_dir/logd-rootfs-payload.tar"
printf 'It remains quarantined and has not been integrated into a rootfs.\n'
