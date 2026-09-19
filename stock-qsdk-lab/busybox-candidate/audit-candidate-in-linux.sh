#!/bin/sh
set -eu

[ "$#" -eq 4 ] || exit 2
stock_image=$1
candidate_binary=$2
source_root=$3
output_dir=$4
candidate_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$candidate_dir/factory-baseline.env"
. "$candidate_dir/sources.lock"

[ "$(sha256sum "$stock_image" | awk '{print $1}')" = "$FACTORY_P27_SHA256" ]
mkdir -p /scratch/root "$output_dir"
unsquashfs -no-progress -d /scratch/root "$stock_image" > "$output_dir/unsquashfs.txt"
install -m 0755 "$candidate_binary" /scratch/root/tmp/busybox-candidate

semantic_root=/scratch/root/tmp/busybox-semantic
mkdir -p /scratch/root/tmp/etc \
	"$semantic_root/tar/source" "$semantic_root/tar/extract" "$semantic_root/tar/deref"
# /dev is populated by tmpfs during a real boot; an extracted squashfs has an
# empty directory. Recreate only the devices required by OpenSSL/wget in the
# disposable chroot.
[ -e /scratch/root/dev/null ] || mknod -m 0666 /scratch/root/dev/null c 1 3
[ -e /scratch/root/dev/urandom ] || mknod -m 0666 /scratch/root/dev/urandom c 1 9
chroot /scratch/root /bin/busybox ash -c ': <>/dev/null; : </dev/urandom'
# Factory /etc/{passwd,shadow} are runtime symlinks into tmpfs. Populate only
# this throwaway extracted root so passwd can exercise its real update path.
printf 'root:x:0:0:root:/root:/bin/ash\n' > /scratch/root/tmp/etc/passwd
printf 'root::0:0:99999:7:::\n' > /scratch/root/tmp/etc/shadow
printf 'root:x:0:\n' > /scratch/root/tmp/etc/group
chmod 0600 /scratch/root/tmp/etc/shadow
printf 'candidate-stat\n' > "$semantic_root/stat-input"
chmod 0640 "$semantic_root/stat-input"
printf 'keep\n' > "$semantic_root/tar/source/keep.txt"
printf 'skip\n' > "$semantic_root/tar/source/skip.txt"
ln -s keep.txt "$semantic_root/tar/source/link.txt"
printf 'keep.txt\nskip.txt\n' > "$semantic_root/tar/include.list"
printf 'skip.txt\n' > "$semantic_root/tar/exclude.list"

chroot /scratch/root /bin/busybox --list > "$output_dir/factory-applets.txt"
diff -u "$candidate_dir/factory-1.35.0-applets.txt" "$output_dir/factory-applets.txt"
{
	grep -Ev '^(halt|poweroff|reboot)$' "$output_dir/factory-applets.txt"
	printf 'busybox\n'
	printf 'ntpd\n'
} | LC_ALL=C sort -u > "$output_dir/expected-candidate-applets.txt"
chroot /scratch/root /tmp/busybox-candidate --list > "$output_dir/candidate-applets.txt"
diff -u "$output_dir/expected-candidate-applets.txt" "$output_dir/candidate-applets.txt"
for applet in syslogd klogd nslookup lock netmsg ntpd; do
	grep -qx "$applet" "$output_dir/candidate-applets.txt"
done
for applet in halt poweroff reboot; do
	if grep -qx "$applet" "$output_dir/candidate-applets.txt"; then
		printf 'ERROR: forbidden shutdown applet is present: %s\n' "$applet" >&2
		exit 1
	fi
done

chroot /scratch/root /tmp/busybox-candidate > "$output_dir/candidate-banner.txt" 2>&1 || true
grep -q "BusyBox v$BUSYBOX_VERSION" "$output_dir/candidate-banner.txt"
chroot /scratch/root /tmp/busybox-candidate ash -c \
	'test "$(printf %s candidate)" = candidate && test "$((6 * 7))" -eq 42'
chroot /scratch/root /tmp/busybox-candidate sha256sum /etc/openwrt_release > "$output_dir/smoke-sha256.txt"
chroot /scratch/root /tmp/busybox-candidate syslogd --help > "$output_dir/smoke-syslogd-help.txt" 2>&1
chroot /scratch/root /tmp/busybox-candidate klogd --help > "$output_dir/smoke-klogd-help.txt" 2>&1
chroot /scratch/root /tmp/busybox-candidate nslookup --help > "$output_dir/smoke-nslookup-help.txt" 2>&1
grep -q -- '-K' "$output_dir/smoke-syslogd-help.txt"
grep -q -- '-s SIZE' "$output_dir/smoke-syslogd-help.txt"
grep -q -- '-b N' "$output_dir/smoke-syslogd-help.txt"
grep -q -- '-f FILE' "$output_dir/smoke-syslogd-help.txt"
grep -q -- 'QUERY_TYPE' "$output_dir/smoke-nslookup-help.txt"
for applet in syslogd klogd nslookup; do
	chroot /scratch/root /bin/busybox "$applet" --help \
		> "$output_dir/factory-$applet-help.txt" 2>&1
	sed '1d' "$output_dir/factory-$applet-help.txt" > "$output_dir/factory-$applet-help.normalized.txt"
	sed '1d' "$output_dir/smoke-$applet-help.txt" > "$output_dir/candidate-$applet-help.normalized.txt"
	diff -u "$output_dir/factory-$applet-help.normalized.txt" \
		"$output_dir/candidate-$applet-help.normalized.txt"
done
chroot /scratch/root /tmp/busybox-candidate netmsg 127.0.0.1 candidate-smoke
chroot /scratch/root /tmp/busybox-candidate lock -n /tmp/candidate-smoke.lock
chroot /scratch/root /tmp/busybox-candidate lock -u /tmp/candidate-smoke.lock

# Factory-facing option surfaces. Configurable 1.37 features must be a
# functional superset of every option used by stock or the project overlay.
for applet in date stat tar wget passwd netstat xargs start-stop-daemon arping ping udhcpc; do
	chroot /scratch/root /tmp/busybox-candidate "$applet" --help \
		> "$output_dir/smoke-$applet-help.txt" 2>&1 || true
done
grep -q -- '-k' "$output_dir/smoke-date-help.txt"
grep -q -- '-c FMT' "$output_dir/smoke-stat-help.txt"
grep -q -- 'c|x|t' "$output_dir/smoke-tar-help.txt"
grep -q -- '-T FILE' "$output_dir/smoke-tar-help.txt"
grep -q -- '-X FILE' "$output_dir/smoke-tar-help.txt"
grep -q -- '--no-check-certificate' "$output_dir/smoke-wget-help.txt"
grep -q -- 'default sha512' "$output_dir/smoke-passwd-help.txt"
grep -q -- '-W' "$output_dir/smoke-netstat-help.txt"
grep -q -- '-p' "$output_dir/smoke-netstat-help.txt"
grep -q -- '-0' "$output_dir/smoke-xargs-help.txt"
grep -q -- '-p' "$output_dir/smoke-xargs-help.txt"
grep -q -- '-x' "$output_dir/smoke-xargs-help.txt"
grep -q -- '-q' "$output_dir/smoke-start-stop-daemon-help.txt"

# The three unpublished factory extensions have no caller in stock p27 or the
# replacement overlay. Do not silently grow an unaudited OEM patch surface.
! grep -q -- '-B IFACE' "$output_dir/smoke-arping-help.txt"
! grep -q -- '-Q TOS' "$output_dir/smoke-ping-help.txt"
! grep -q -- 'receiving DHCP offer' "$output_dir/smoke-udhcpc-help.txt"

chroot /scratch/root /tmp/busybox-candidate stat -c '%a:%s' \
	/tmp/busybox-semantic/stat-input > "$output_dir/semantic-stat.txt"
[ "$(cat "$output_dir/semantic-stat.txt")" = '640:15' ]

chroot /scratch/root /tmp/busybox-candidate tar -czf \
	/tmp/busybox-semantic/tar/backup.tar.gz \
	-C /tmp/busybox-semantic/tar/source \
	-T /tmp/busybox-semantic/tar/include.list \
	-X /tmp/busybox-semantic/tar/exclude.list
chroot /scratch/root /tmp/busybox-candidate tar -tzf \
	/tmp/busybox-semantic/tar/backup.tar.gz > "$output_dir/semantic-tar-list.txt"
grep -qx 'keep.txt' "$output_dir/semantic-tar-list.txt"
! grep -q 'skip.txt' "$output_dir/semantic-tar-list.txt"
chroot /scratch/root /tmp/busybox-candidate tar -xzf \
	/tmp/busybox-semantic/tar/backup.tar.gz \
	-C /tmp/busybox-semantic/tar/extract
cmp -s "$semantic_root/tar/source/keep.txt" "$semantic_root/tar/extract/keep.txt"
chroot /scratch/root /tmp/busybox-candidate tar -chf \
	/tmp/busybox-semantic/tar/deref.tar \
	-C /tmp/busybox-semantic/tar/source link.txt
chroot /scratch/root /tmp/busybox-candidate tar -xf \
	/tmp/busybox-semantic/tar/deref.tar \
	-C /tmp/busybox-semantic/tar/deref
[ -f "$semantic_root/tar/deref/link.txt" ] && [ ! -L "$semantic_root/tar/deref/link.txt" ]
cmp -s "$semantic_root/tar/source/keep.txt" "$semantic_root/tar/deref/link.txt"

# The stock image carries the external OpenSSL client used for verified HTTPS.
# Use a deterministic loopback-only HTTP/TLS peer instead of `openssl s_server
# -www`: the latter can reset a bidirectional socketpair client after serving
# its diagnostic page and is not a faithful HTTP server semantic test.
test -x /scratch/root/usr/bin/openssl
chroot /scratch/root /usr/bin/openssl version > "$output_dir/semantic-openssl-version.txt"
rm -f "$semantic_root/https-server.ready"
python3 "$candidate_dir/https-test-server.py" \
	/scratch/root/etc/uhttpd.crt /scratch/root/etc/uhttpd.key \
	"$semantic_root/https-server.ready" \
	> "$output_dir/semantic-https-server.txt" 2>&1 &
https_server_pid=$!
ready_attempt=0
while [ ! -s "$semantic_root/https-server.ready" ]; do
	ready_attempt=$((ready_attempt + 1))
	[ "$ready_attempt" -lt 100 ] || {
		cat "$output_dir/semantic-https-server.txt" >&2
		exit 1
	}
	chroot /scratch/root /tmp/busybox-candidate usleep 20000
done
printf 'GET / HTTP/1.0\r\n\r\n' \
	| timeout 5 chroot /scratch/root /usr/bin/openssl s_client -quiet \
		-connect 127.0.0.1:18443 \
		> "$output_dir/semantic-openssl-client.txt" \
		2> "$output_dir/semantic-openssl-client-error.txt"
test -s "$output_dir/semantic-openssl-client.txt"
https_ok=0
for attempt in 1 2 3 4 5; do
	if chroot /scratch/root /tmp/busybox-candidate wget \
		--no-check-certificate -O /tmp/busybox-semantic/https-response \
		https://127.0.0.1:18443/ \
		> "$output_dir/semantic-wget-https.txt" 2>&1; then
		https_ok=1
		break
	fi
	chroot /scratch/root /tmp/busybox-candidate usleep 100000
done
kill "$https_server_pid" 2>/dev/null || true
wait "$https_server_pid" 2>/dev/null || true
[ "$https_ok" -eq 1 ]
grep -qx 'busybox-wget-https-semantic' "$semantic_root/https-response"

# Change only the throwaway extracted root, verify the configured default
# produces a SHA-512 shadow hash, then restore the original file.
cp /scratch/root/tmp/etc/shadow "$semantic_root/shadow.before"
printf 'Candidate-BusyBox-137!\nCandidate-BusyBox-137!\n' \
	| timeout 10 chroot /scratch/root /tmp/busybox-candidate passwd root \
		> "$output_dir/semantic-passwd.txt" 2>&1
root_hash=$(awk -F: '$1 == "root" {print $2}' /scratch/root/tmp/etc/shadow)
case "$root_hash" in
	\$6\$*) ;;
	*) printf 'ERROR: passwd did not create a SHA-512 shadow hash.\n' >&2; exit 1 ;;
esac
cp "$semantic_root/shadow.before" /scratch/root/tmp/etc/shadow

# Parse the patched -k path under Docker's default no-CAP_SYS_TIME profile.
# EPERM is expected; an option/usage error is not.
set +e
chroot /scratch/root /tmp/busybox-candidate date -k \
	> "$output_dir/semantic-date-k.txt" 2>&1
date_k_status=$?
set -e
[ "$date_k_status" -ne 2 ]
! grep -q '^Usage:' "$output_dir/semantic-date-k.txt"

# Syntax-check every shell overlay with the candidate ash. The copy is into
# tmpfs only; neither the source overlay nor a rootfs image is modified.
cp -a /overlay "$semantic_root/overlay"
overlay_script_count=0
find "$semantic_root/overlay" -type f -print | LC_ALL=C sort \
	> "$output_dir/overlay-files.txt"
while IFS= read -r script; do
	if head -n 1 "$script" | grep -Eq '^#! */bin/(ba)?sh([[:space:]]|$)|^#! */usr/bin/env (ba)?sh([[:space:]]|$)'; then
		chroot /scratch/root /tmp/busybox-candidate ash -n "${script#/scratch/root}"
		overlay_script_count=$((overlay_script_count + 1))
	fi
done < "$output_dir/overlay-files.txt"
[ "$overlay_script_count" -gt 0 ]
printf 'OVERLAY_SHELL_SCRIPTS_CHECKED=%s\n' "$overlay_script_count" \
	> "$output_dir/semantic-summary.env"
printf 'STAT_FORMAT_SEMANTICS=pass\n' >> "$output_dir/semantic-summary.env"
printf 'TAR_BACKUP_SEMANTICS=pass\n' >> "$output_dir/semantic-summary.env"
printf 'WGET_HTTPS_SEMANTICS=pass\n' >> "$output_dir/semantic-summary.env"
printf 'PASSWD_SHA512_SEMANTICS=pass\n' >> "$output_dir/semantic-summary.env"
printf 'DATE_K_COMPATIBILITY=pass\n' >> "$output_dir/semantic-summary.env"
printf 'OVERLAY_ASH_SYNTAX=pass\n' >> "$output_dir/semantic-summary.env"

toolchain_dir=$source_root/qsdk/staging_dir/toolchain-aarch64_cortex-a73+neon-vfpv4_gcc-7.5.0_musl
readelf=$toolchain_dir/bin/aarch64-openwrt-linux-musl-readelf
strings=$toolchain_dir/bin/aarch64-openwrt-linux-musl-strings
[ -x "$readelf" ] && [ -x "$strings" ]
"$readelf" -h "$candidate_binary" > "$output_dir/elf-header.txt"
"$readelf" -W -l "$candidate_binary" > "$output_dir/elf-program-headers.txt"
"$readelf" -W -d "$candidate_binary" > "$output_dir/elf-dynamic.txt"
grep -q 'Machine:.*AArch64' "$output_dir/elf-header.txt"
grep -q 'Type:.*DYN' "$output_dir/elf-header.txt"
grep -q 'Requesting program interpreter: /lib/ld-musl-aarch64.so.1' "$output_dir/elf-program-headers.txt"
grep -q 'GNU_RELRO' "$output_dir/elf-program-headers.txt"
grep -q 'BIND_NOW' "$output_dir/elf-dynamic.txt"

"$strings" -a "$candidate_binary" > "$output_dir/candidate.strings"
if grep -E -i '(/Users/yangzhg|yangzhg|/Users/|sbe-busybox-candidate\.|opensync|plume|warehouse|sshm|cujo|BEGIN (RSA |OPENSSH )?PRIVATE KEY)' \
	"$output_dir/candidate.strings" > "$output_dir/privacy-rejects.txt"; then
	printf 'ERROR: candidate privacy scan failed.\n' >&2
	exit 1
fi

{
	printf 'CANDIDATE_VERSION=%s\n' "$BUSYBOX_VERSION"
	printf 'CANDIDATE_SHA256=%s\n' "$(sha256sum "$candidate_binary" | awk '{print $1}')"
	printf 'CANDIDATE_APPLET_COUNT=%s\n' "$(wc -l < "$output_dir/candidate-applets.txt" | tr -d ' ')"
	printf 'FACTORY_ROOTFS_CHROOT_SMOKE=pass\n'
	printf 'FACTORY_APPLET_COMPATIBILITY=pass\n'
	printf 'FACTORY_CRITICAL_HELP_COMPATIBILITY=pass\n'
	printf 'FACTORY_CONFIGURABLE_OPTION_COMPATIBILITY=pass\n'
	printf 'FACTORY_AND_OVERLAY_SCRIPT_SEMANTICS=pass\n'
	printf 'SHUTDOWN_APPLETS_ABSENT=pass\n'
	printf 'ELF_ABI_GATE=pass\n'
	printf 'PRIVACY_GATE=pass\n'
	printf 'ROOTFS_INTEGRATED=no\n'
	printf 'DEVICE_WRITTEN=no\n'
} > "$output_dir/audit-summary.env"

printf 'Candidate passed factory-rootfs chroot smoke and ABI/privacy/applet gates.\n'
printf 'It remains quarantined; no rootfs or device was modified.\n'
