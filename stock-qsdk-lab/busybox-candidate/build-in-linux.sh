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
cross=$toolchain_dir/bin/aarch64-openwrt-linux-musl-
cc=${cross}gcc
strip=${cross}strip
readelf=${cross}readelf
strings=${cross}strings
loader=$toolchain_dir/lib/ld-musl-aarch64.so.1
jobs=${BUSYBOX_JOBS:-4}
export STAGING_DIR=$source_root/qsdk/staging_dir
export KCONFIG_NOTIMESTAMP=1

for required in "$cc" "$strip" "$readelf" "$strings" "$loader"; do
	[ -x "$required" ] || {
		printf 'ERROR: required QSDK toolchain component is absent: %s\n' "$required" >&2
		exit 1
	}
done
"$candidate_dir/verify-sources.sh" "$cache_dir"

work_root=$(mktemp -d /tmp/sbe-busybox-candidate.XXXXXX)
cleanup() {
	rm -rf "$work_root"
}
trap cleanup EXIT HUP INT TERM

build_once() {
	run=$1
	run_root=$work_root/run-$run
	mkdir -p "$run_root"
	tar -xjf "$cache_dir/$BUSYBOX_ARCHIVE" -C "$run_root"
	source_dir=$run_root/busybox-$BUSYBOX_VERSION

	while IFS="	" read -r patch_name patch_sha extra; do
		case "$patch_name" in ''|'#'*) continue ;; esac
		patch --batch --forward -d "$source_dir" -p1 < "$cache_dir/$patch_name"
	done < "$candidate_dir/patches.lock"
	while IFS="	" read -r patch_name patch_sha provenance; do
		case "$patch_name" in ''|'#'*) continue ;; esac
		patch --batch --forward -d "$source_dir" -p1 \
			< "$candidate_dir/local-patches/$patch_name"
	done < "$candidate_dir/local-patches.lock"

	make -C "$source_dir" ARCH=arm64 CROSS_COMPILE="$cross" allnoconfig >/dev/null
	python3 "$candidate_dir/merge-config.py" "$source_dir/.config" "$candidate_dir/candidate.config"
	if ! yes '' | timeout 30 make -C "$source_dir" ARCH=arm64 CROSS_COMPILE="$cross" \
		oldconfig > "$run_root/config.log" 2>&1; then
		cat "$run_root/config.log" >&2
		printf 'ERROR: BusyBox config resolution failed or timed out.\n' >&2
		exit 1
	fi

	for symbol in BUSYBOX SYSLOGD KLOGD NSLOOKUP LOCK NETMSG \
		NTPD FEATURE_NTPD_SERVER \
		FEATURE_STAT_FORMAT FEATURE_TAR_CREATE FEATURE_TAR_FROM \
		FEATURE_TAR_GNU_EXTENSIONS FEATURE_NETSTAT_WIDE FEATURE_NETSTAT_PRG \
		FEATURE_XARGS_SUPPORT_CONFIRMATION FEATURE_XARGS_SUPPORT_QUOTES \
		FEATURE_XARGS_SUPPORT_TERMOPT FEATURE_XARGS_SUPPORT_ZERO_TERM \
		FEATURE_WGET_HTTPS FEATURE_WGET_OPENSSL FEATURE_START_STOP_DAEMON_FANCY; do
		grep -qx "CONFIG_${symbol}=y" "$source_dir/.config" || {
			printf 'ERROR: required config symbol was lost: CONFIG_%s\n' "$symbol" >&2
			exit 1
		}
	done
	for symbol in HALT POWEROFF REBOOT INIT FEATURE_SUID FEATURE_INSTALLER \
		FEATURE_NTPD_CONF FEATURE_NTP_AUTH \
		FEATURE_TFTP_BLOCKSIZE FEATURE_UDHCPC_ARPING FEATURE_UDHCP_PORT \
		FEATURE_HWIB FEATURE_TRACEROUTE_USE_ICMP FEATURE_WGET_TIMEOUT \
		FEATURE_PS_LONG FEATURE_PIDOF_SINGLE FEATURE_PIDOF_OMIT; do
		if grep -qx "CONFIG_${symbol}=y" "$source_dir/.config"; then
			printf 'ERROR: forbidden config symbol became enabled: CONFIG_%s\n' "$symbol" >&2
			exit 1
		fi
	done
	grep -qx 'CONFIG_FEATURE_DEFAULT_PASSWD_ALGO="sha512"' "$source_dir/.config"
	grep -qx 'CONFIG_UDHCPC_DEFAULT_INTERFACE=""' "$source_dir/.config"
	grep -q 'OPT_KERNELTZ' "$source_dir/coreutils/date.c"

	prefix_map=-fdebug-prefix-map=$source_dir=.
	if ! make -C "$source_dir" -j"$jobs" \
		ARCH=arm64 CROSS_COMPILE="$cross" \
		KBUILD_BUILD_TIMESTAMP='1970-01-01 00:00:00 UTC' \
		KBUILD_BUILD_USER=sbe-candidate KBUILD_BUILD_HOST=qsdk \
		EXTRA_CFLAGS="-Os -pipe -fPIE -fstack-protector-strong -D_FORTIFY_SOURCE=2 -Wformat -Wformat-security $prefix_map" \
		EXTRA_LDFLAGS='-Wl,-z,relro -Wl,-z,now -pie' \
		SKIP_STRIP=y busybox > "$run_root/build.log" 2>&1; then
		tail -n 200 "$run_root/build.log" >&2
		printf 'ERROR: BusyBox compilation failed.\n' >&2
		exit 1
	fi

	cp "$source_dir/busybox" "$work_root/busybox.run$run"
	"$strip" --strip-all "$work_root/busybox.run$run"
	chmod 0755 "$work_root/busybox.run$run"
	if [ "$run" -eq 1 ]; then
		cp "$source_dir/.config" "$work_root/candidate.config.full"
	fi
}

build_once 1
build_once 2

hash1=$(sha256sum "$work_root/busybox.run1" | awk '{print $1}')
hash2=$(sha256sum "$work_root/busybox.run2" | awk '{print $1}')
[ "$hash1" = "$hash2" ] && cmp -s "$work_root/busybox.run1" "$work_root/busybox.run2" || {
	printf 'ERROR: two clean builds were not byte-identical: %s != %s\n' "$hash1" "$hash2" >&2
	exit 1
}

binary=$work_root/busybox.run1
LD_LIBRARY_PATH=$toolchain_dir/lib \
	"$loader" "$binary" --list > "$work_root/candidate-applets.txt"
{
	grep -Ev '^(halt|poweroff|reboot)$' "$candidate_dir/factory-1.35.0-applets.txt"
	printf 'busybox\n'
	printf 'ntpd\n'
} | LC_ALL=C sort -u > "$work_root/expected-applets.txt"
diff -u "$work_root/expected-applets.txt" "$work_root/candidate-applets.txt" || {
	printf 'ERROR: candidate applet surface differs from the approved factory-compatible set.\n' >&2
	exit 1
}

"$readelf" -h "$binary" > "$work_root/elf-header.txt"
"$readelf" -W -l "$binary" > "$work_root/elf-program-headers.txt"
"$readelf" -W -d "$binary" > "$work_root/elf-dynamic.txt"
grep -q 'Machine:.*AArch64' "$work_root/elf-header.txt"
grep -q 'Type:.*DYN' "$work_root/elf-header.txt"
grep -q 'Requesting program interpreter: /lib/ld-musl-aarch64.so.1' "$work_root/elf-program-headers.txt"
grep -q 'GNU_RELRO' "$work_root/elf-program-headers.txt"
grep -q 'BIND_NOW' "$work_root/elf-dynamic.txt"
stack_flags=$(awk '$1 == "GNU_STACK" {print $7}' "$work_root/elf-program-headers.txt")
[ -n "$stack_flags" ] && ! printf '%s\n' "$stack_flags" | grep -q E || {
	printf 'ERROR: GNU_STACK is missing or executable.\n' >&2
	exit 1
}

"$strings" -a "$binary" > "$work_root/candidate.strings"
if grep -E -i '(/Users/yangzhg|yangzhg|/Users/|sbe-busybox-candidate\.|opensync|plume|warehouse|sshm|cujo|BEGIN (RSA |OPENSSH )?PRIVATE KEY)' \
	"$work_root/candidate.strings" > "$work_root/privacy-rejects.txt"; then
	printf 'ERROR: candidate contains a private build path, identity or operator-control marker.\n' >&2
	cat "$work_root/privacy-rejects.txt" >&2
	exit 1
fi

mkdir -p "$output_dir"
cp "$binary" "$output_dir/busybox-1.37.0-qsdk-candidate"
cp "$work_root/candidate.config.full" "$output_dir/candidate.config.full"
cp "$work_root/candidate-applets.txt" "$output_dir/candidate-applets.txt"
cp "$work_root/elf-header.txt" "$output_dir/elf-header.txt"
cp "$work_root/elf-program-headers.txt" "$output_dir/elf-program-headers.txt"
cp "$work_root/elf-dynamic.txt" "$output_dir/elf-dynamic.txt"

payload_root=$work_root/rootfs-payload
mkdir -p "$payload_root/etc/init.d" "$payload_root/etc/rc.d" \
	"$payload_root/usr/sbin"
install -m 0755 "$candidate_dir/rootfs-payload/etc/init.d/sysntpd" \
	"$payload_root/etc/init.d/sysntpd"
install -m 0755 "$candidate_dir/rootfs-payload/usr/sbin/ntpd-hotplug" \
	"$payload_root/usr/sbin/ntpd-hotplug"
ln -s ../../bin/busybox "$payload_root/usr/sbin/ntpd"
ln -s ../init.d/sysntpd "$payload_root/etc/rc.d/S98sysntpd"
tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner \
	-C "$payload_root" -cf "$output_dir/busybox-ntpd-rootfs-payload.tar" .
tar -tf "$output_dir/busybox-ntpd-rootfs-payload.tar" \
	> "$output_dir/busybox-ntpd-rootfs-payload.list"

payload_sha=$(sha256sum "$output_dir/busybox-ntpd-rootfs-payload.tar" | awk '{print $1}')
{
	printf 'BUSYBOX_VERSION=%s\n' "$BUSYBOX_VERSION"
	printf 'BUSYBOX_SHA256=%s\n' "$hash1"
	printf 'BUSYBOX_SIZE=%s\n' "$(wc -c < "$binary" | tr -d ' ')"
	printf 'BUSYBOX_APPLET_COUNT=%s\n' "$(wc -l < "$work_root/candidate-applets.txt" | tr -d ' ')"
	printf 'NTPD_ROOTFS_PAYLOAD_SHA256=%s\n' "$payload_sha"
	printf 'OPENWRT_PATCH_COMMIT=%s\n' "$OPENWRT_COMMIT"
	printf 'OPENWRT_DATE_K_ORIGIN_COMMIT=%s\n' "$OPENWRT_DATE_K_ORIGIN_COMMIT"
	printf 'OPENWRT_PATCH_COUNT=16\n'
	printf 'LOCAL_COMPAT_PATCH_COUNT=1\n'
	printf 'BUILD_REPETITIONS=2\n'
	printf 'BUILD_BYTE_IDENTICAL=yes\n'
	printf 'ROOTFS_INTEGRATED=no\n'
	printf 'DEVICE_WRITTEN=no\n'
} > "$output_dir/build-manifest.env"
(
	cd "$output_dir"
	sha256sum \
		busybox-1.37.0-qsdk-candidate \
		busybox-ntpd-rootfs-payload.tar \
		candidate.config.full \
		candidate-applets.txt
) > "$output_dir/SHA256SUMS"

printf 'BusyBox %s candidate passed two-build determinism, applet, ELF and privacy gates.\n' "$BUSYBOX_VERSION"
printf 'Candidate output: %s\n' "$output_dir/busybox-1.37.0-qsdk-candidate"
printf 'It is quarantined and has not been integrated into any rootfs.\n'
