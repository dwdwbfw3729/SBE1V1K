#!/bin/sh
# Read-only p30 qualification.  Safe to run from the RAM trial.

set -eu

mode=${1:-unmounted}
case "$mode" in
	--mounted) mode=mounted ;;
	unmounted) ;;
	*) echo "usage: $0 [--mounted]" >&2; exit 2 ;;
esac

label=rootfs_data_1
expected_device=mmcblk0p30
expected_start=1658914
expected_sectors=1048576
mountpoint=/tmp/sbe-p30-audit

device=
for uevent in /sys/class/block/mmcblk0p*/uevent; do
	[ -r "$uevent" ] || continue
	[ "$(sed -n 's/^PARTNAME=//p' "$uevent")" = "$label" ] || continue
	name="${uevent%/uevent}"
	name="${name##*/}"
	device="/dev/$name"
	break
done

[ "$device" = "/dev/$expected_device" ] || {
	echo "FAIL: $label resolved to ${device:-nothing}, expected /dev/$expected_device" >&2
	exit 1
}
[ "$(cat "/sys/class/block/$expected_device/start")" = "$expected_start" ] || {
	echo "FAIL: p30 start sector mismatch" >&2
	exit 1
}
[ "$(cat "/sys/class/block/$expected_device/size")" = "$expected_sectors" ] || {
	echo "FAIL: p30 sector count mismatch" >&2
	exit 1
}

sbe_private_mode() {
	local mode
	mode=$(stat -c %a "$1" 2>/dev/null) || return 1
	case "$mode" in
		[0-7][2367][0-7]|[0-7][0-7][2367]) return 1 ;;
		[0-7][0-7][0-7]) return 0 ;;
		*) return 1 ;;
	esac
}

check_vendor_wifi_layout() {
	local vendor="$1/vendor" wifi="$1/vendor/wifi" item name bytes
	[ -d "$vendor" ] && [ ! -L "$vendor" ] && [ -O "$vendor" ] && sbe_private_mode "$vendor" || return 1
	for item in "$vendor"/* "$vendor"/.[!.]* "$vendor"/..?*; do
		[ -e "$item" ] || [ -L "$item" ] || continue
		[ "$item" = "$wifi" ] || return 1
	done
	[ -d "$wifi" ] && [ ! -L "$wifi" ] && [ -O "$wifi" ] && sbe_private_mode "$wifi" || return 1
	for item in "$wifi"/* "$wifi"/.[!.]* "$wifi"/..?*; do
		[ -e "$item" ] || [ -L "$item" ] || continue
		name=${item##*/}
		case "$name" in
			wlfw_cal_01_QCN9224_PCI1.bin|wlfw_cal_01_QCN9224_PCI2.bin|wlfw_cal_01_QCN9224_PCI3.bin) ;;
			*) return 1 ;;
		esac
		[ -f "$item" ] && [ ! -L "$item" ] && [ -O "$item" ] && sbe_private_mode "$item" || return 1
		bytes=$(stat -c %s "$item" 2>/dev/null) || return 1
		case "$bytes" in ''|*[!0-9]*) return 1 ;; esac
		[ "$bytes" -gt 0 ] && [ "$bytes" -le 8388608 ] || return 1
	done
}

check_private_layout() {
	root="$1"
	unexpected=0
	for item in "$root"/* "$root"/.[!.]* "$root"/..?*; do
		[ -e "$item" ] || [ -L "$item" ] || continue
		name="${item##*/}"
		case "$name" in
			lost+found|openwrt) ;;
			vendor) check_vendor_wifi_layout "$root" || {
				echo 'FAIL: unsafe vendor Wi-Fi calibration cache' >&2
				unexpected=1
			} ;;
			*) echo "FAIL: unexpected p30 entry: $name" >&2; unexpected=1 ;;
		esac
	done
	[ "$unexpected" -eq 0 ]
}

if [ "$mode" = mounted ]; then
	awk -v device="$device" '
		$1 == device && $2 == "/overlay" && $3 == "ext4" {
			n=split($4, option, ",")
			for (i=1; i<=n; i++) {
				if (option[i] == "rw") rw=1
				if (option[i] == "nodev") nodev=1
				if (option[i] == "nosuid") nosuid=1
			}
		}
		END { exit !(rw && nodev && nosuid) }
	' /proc/mounts || {
		echo "FAIL: p30 is not the verified rw,nodev,nosuid /overlay mount" >&2
		exit 1
	}
	check_private_layout /overlay || exit 1
	[ -d /overlay/openwrt/upper ] && [ ! -L /overlay/openwrt/upper ] || {
		echo "FAIL: persistent upperdir is missing or unsafe" >&2
		exit 1
	}
	[ -d /overlay/openwrt/work ] && [ ! -L /overlay/openwrt/work ] || {
		echo "FAIL: persistent workdir is missing or unsafe" >&2
		exit 1
	}
	echo "PASS: mounted p30 identity, geometry and private overlay layout are valid"
	exit 0
fi

grep -q "^$device " /proc/mounts && {
	echo "FAIL: p30 is already mounted; refusing to inspect through another mount" >&2
	exit 1
}

cleanup() {
	umount "$mountpoint" 2>/dev/null || true
	rmdir "$mountpoint" 2>/dev/null || true
}
trap cleanup EXIT INT TERM
mkdir -p "$mountpoint"

# noload is essential: an ext4 read-only mount may otherwise replay its journal.
mount -t ext4 -o ro,noload,nosuid,nodev,noexec "$device" "$mountpoint"
awk -v device="$device" -v target="$mountpoint" '
	$1 == device && $2 == target && $3 == "ext4" {
		n=split($4, option, ",")
		for (i=1; i<=n; i++) if (option[i] == "ro") readonly=1
	}
	END { exit !readonly }
' /proc/mounts || {
	echo "FAIL: p30 did not remain read-only" >&2
	exit 1
}

check_private_layout "$mountpoint" || exit 1

echo "PASS: p30 label, geometry, read-only ext4 mount and private layout are valid"
find "$mountpoint" -mindepth 1 -maxdepth 2 -print 2>/dev/null | sort
