#!/bin/sh
# Final-image checks in a disposable offline root; no device or service access.
set -eu
[ "$#" -eq 2 ] && [ -f "$1" ] && [ -d "$2" ] || {
	echo 'usage: test_preinstalled_rootfs.sh FINAL.root.squashfs RELEASE_FEED' >&2
	exit 2
}
image_dir=$(CDPATH= cd -- "$(dirname -- "$1")" && pwd)
image_name=$(basename -- "$1")
feed_dir=$(CDPATH= cd -- "$2" && pwd)
lab=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
docker run --rm --network none --read-only --tmpfs /tmp:exec,dev \
	--platform linux/arm64 -e PYTHONDONTWRITEBYTECODE=1 \
	-v "$image_dir:/input:ro" -v "$feed_dir:/feed:ro" -v "$lab:/lab:ro" \
	--entrypoint sh sbe1v1k-stock-rootfs-builder:ubuntu-24.04 -eu -c '
	work=$(mktemp -d /tmp/sbe-preinstalled.XXXXXX)
	root=$work/root
	unsquashfs -d "$root" "$1" >/dev/null
	[ -z "$(find "$root" -name "*.ipk" -print -quit)" ]
	[ ! -e "$root/usr/share/sbe-feed" ]
	[ ! -e "$root/usr/share/sbe-offline-feed" ]
	! grep -r "file:///usr/share/sbe-feed" "$root/etc/opkg.conf" "$root/etc/opkg"
	grep -qx external "$root/usr/share/sbe-build/feed-policy"
	sh /lab/feed/verify-feed.sh --feed /feed
	mkdir -p "$root/tmp/lock" "$root/tmp/opkg-lists" "$root/tmp/log"
	mknod -m 666 "$root/dev/null" c 1 3
	# Empty sources must finish normally; installed package discovery needs no feed.
	timeout 30 chroot "$root" /bin/opkg update
	[ ! -e "$root/usr/bin/sing-box" ]
	! chroot "$root" /bin/opkg status sing-box | grep -q "^Status: install .* installed$"
	for package in luci-app-passwall luci-i18n-passwall-zh-cn xray-core shadowsocks-rust-sslocal; do
		chroot "$root" /bin/opkg status "$package" | grep -q "^Status: install .* installed$"
	done
	python3 /lab/tests/check_kernel_rootfs.py "$root" /feed /lab/sources/kernel-support-1.5.3.json
	# Test normal upload/local-IPK reinstall using the separately delivered feed.
	set -- /feed/sing-box_*.ipk
	[ "$#" -eq 1 ] && [ -f "$1" ]
	cp "$1" "$root/tmp/sing-box.ipk"
	IPKG_INSTROOT=/ timeout 30 chroot "$root" /bin/opkg install /tmp/sing-box.ipk
	chroot "$root" /usr/bin/sing-box version
	IPKG_INSTROOT=/ timeout 30 chroot "$root" /bin/opkg remove sing-box
	[ ! -e "$root/usr/bin/sing-box" ]
	# Preserved-config migration removes just our obsolete local source.
	cp "$root/etc/opkg.conf" "$work/opkg.before"
	printf "%s\n" "src/gz sbe_local file:///usr/share/sbe-feed" >> "$root/etc/opkg.conf"
	printf "%s\n" "src/gz custom https://example.invalid/feed" "src/gz sbe_local file:///custom-feed" > "$work/custom.expected"
	cp "$work/custom.expected" "$root/etc/opkg/customfeeds.conf"
	printf "%s\n" "  src/gz sbe_local file:///usr/share/sbe-feed  " >> "$root/etc/opkg/customfeeds.conf"
	chroot "$root" /bin/sh /etc/uci-defaults/52-sbe-external-feed
	chroot "$root" /bin/sh /etc/uci-defaults/52-sbe-external-feed
	cmp "$work/opkg.before" "$root/etc/opkg.conf"
	cmp "$work/custom.expected" "$root/etc/opkg/customfeeds.conf"
	echo "PASS: no IPK cache, installed package discovery, external IPK reinstall and preserved-config migration"
' sh "/input/$image_name"
