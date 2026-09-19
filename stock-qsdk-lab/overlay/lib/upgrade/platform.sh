#!/bin/sh
# Strict same-layout upgrader for the SBE1V1K stock-QSDK replacement image.

PART_NAME=firmware
REQUIRE_IMAGE_METADATA=1

RAMFS_COPY_BIN='sha256sum head'
RAMFS_COPY_DATA='/usr/share/sbe-build/upgrade-source.env'

SBE_UPGRADE_PREFIX=sysupgrade-askey_sbe1v1k
SBE_CONTROL_BOARD=spectrum_sbe1v1k
SBE_CONTROL_LAYOUT=mainline
SBE_SOURCE_PROFILE=/usr/share/sbe-build/upgrade-source.env
[ -r "$SBE_SOURCE_PROFILE" ] && . "$SBE_SOURCE_PROFILE"
SBE_P25_SIZE=7340032
SBE_P25_SECTORS=14336
SBE_ROOT_MAX=127926272
SBE_P30_MOUNT=/tmp/sbe-upgrade-p30

sbe_upgrade_error() {
	echo "SBE1V1K upgrade: $*" >&2
	return 1
}

sbe_check_partition() {
	local name="$1" label="$2" start="$3" sectors="$4" sysfs
	sysfs="/sys/class/block/$name"
	[ -b "/dev/$name" ] || sbe_upgrade_error "missing /dev/$name" || return 1
	[ -r "$sysfs/uevent" ] || sbe_upgrade_error "missing $name identity" || return 1
	[ "$(sed -n 's/^PARTNAME=//p' "$sysfs/uevent")" = "$label" ] ||
		sbe_upgrade_error "$name label mismatch" || return 1
	[ "$(cat "$sysfs/start" 2>/dev/null)" = "$start" ] ||
		sbe_upgrade_error "$name start-sector mismatch" || return 1
	[ "$(cat "$sysfs/size" 2>/dev/null)" = "$sectors" ] ||
		sbe_upgrade_error "$name sector-count mismatch" || return 1
}

sbe_check_geometry() {
	sbe_check_partition mmcblk0p25 '0:HLOS' 81954 14336 &&
	sbe_check_partition mmcblk0p27 rootfs 110626 249856 &&
	sbe_check_partition mmcblk0p29 rootfs_data 610338 1048576 &&
	sbe_check_partition mmcblk0p30 rootfs_data_1 1658914 1048576
}

sbe_control_value() {
	local key="$1" control="$2" count value
	count=$(printf '%s\n' "$control" | grep -c "^${key}=" 2>/dev/null || true)
	[ "$count" = 1 ] || return 1
	value=$(printf '%s\n' "$control" | sed -n "s/^${key}=//p")
	[ -n "$value" ] || return 1
	printf '%s\n' "$value"
}

sbe_check_archive() {
	local image="$1" members control root_size root_hash actual_hash magic expected_control
	[ -f "$image" ] && [ ! -L "$image" ] ||
		sbe_upgrade_error 'image must be a regular non-link file' || return 1
	members=$(tar -tf "$image" 2>/dev/null) ||
		sbe_upgrade_error 'cannot read sysupgrade tar' || return 1
	[ "$members" = "${SBE_UPGRADE_PREFIX}/
${SBE_UPGRADE_PREFIX}/CONTROL
${SBE_UPGRADE_PREFIX}/kernel
${SBE_UPGRADE_PREFIX}/root" ] ||
		sbe_upgrade_error 'unexpected tar member order or names' || return 1
	control=$(tar -Oxf "$image" "${SBE_UPGRADE_PREFIX}/CONTROL" 2>/dev/null) ||
		sbe_upgrade_error 'cannot extract CONTROL' || return 1
	root_size=$(sbe_control_value SBE_ROOT_SIZE "$control") ||
		sbe_upgrade_error 'CONTROL has no unique root size' || return 1
	root_hash=$(sbe_control_value SBE_ROOT_SHA256 "$control") ||
		sbe_upgrade_error 'CONTROL has no unique root hash' || return 1
	case "$root_size" in ''|*[!0-9]*) sbe_upgrade_error 'invalid root size'; return 1 ;; esac
	[ "$root_size" -gt 0 ] && [ "$root_size" -le "$SBE_ROOT_MAX" ] &&
		[ $((root_size % 1024)) -eq 0 ] ||
		{ sbe_upgrade_error 'root size is outside p27 or not 1 KiB aligned'; return 1; }
	printf '%s\n' "$root_hash" | grep -Eq '^[0-9a-f]{64}$' ||
		{ sbe_upgrade_error 'invalid root SHA-256'; return 1; }
	expected_control="BOARD=${SBE_CONTROL_BOARD}
SBE1V1K_LAYOUT=${SBE_CONTROL_LAYOUT}
SBE_ROOT_SIZE=${root_size}
SBE_ROOT_SHA256=${root_hash}"
	[ "$control" = "$expected_control" ] ||
		{ sbe_upgrade_error 'CONTROL has unexpected or reordered fields'; return 1; }
	[ "$(tar -Oxf "$image" "${SBE_UPGRADE_PREFIX}/kernel" 2>/dev/null | wc -c)" = "$SBE_FIT_SIZE" ] ||
		{ sbe_upgrade_error 'kernel member size mismatch'; return 1; }
	actual_hash=$(tar -Oxf "$image" "${SBE_UPGRADE_PREFIX}/kernel" 2>/dev/null | sha256sum | awk '{print $1}')
	[ "$actual_hash" = "$SBE_FIT_SHA256" ] ||
		{ sbe_upgrade_error 'kernel member is not the locked QSDK FIT'; return 1; }
	[ "$(tar -Oxf "$image" "${SBE_UPGRADE_PREFIX}/root" 2>/dev/null | wc -c)" = "$root_size" ] ||
		{ sbe_upgrade_error 'root member size mismatch'; return 1; }
	actual_hash=$(tar -Oxf "$image" "${SBE_UPGRADE_PREFIX}/root" 2>/dev/null | sha256sum | awk '{print $1}')
	[ "$actual_hash" = "$root_hash" ] ||
		{ sbe_upgrade_error 'root member SHA-256 mismatch'; return 1; }
	magic=$(tar -Oxf "$image" "${SBE_UPGRADE_PREFIX}/root" 2>/dev/null |
		dd bs=4 count=1 2>/dev/null | hexdump -v -e '4/1 "%c"')
	[ "$magic" = hsqs ] || sbe_upgrade_error 'root member is not SquashFS' || return 1

	SBE_VALIDATED_ROOT_SIZE=$root_size
	SBE_VALIDATED_ROOT_SHA256=$root_hash
	export SBE_VALIDATED_ROOT_SIZE SBE_VALIDATED_ROOT_SHA256
}

platform_check_image() {
	local board
	[ -n "${SBE_FIT_SIZE:-}" ] && [ -n "${SBE_FIT_SHA256:-}" ] &&
		[ -n "${SBE_P25_CANONICAL_SHA256:-}" ] ||
		sbe_upgrade_error 'verified vendor kernel profile is missing' || return 1
	board=$(cat /tmp/sysinfo/board_name 2>/dev/null)
	[ "$board" = 'qcom,ipq9574-ap-al02-c4' ] ||
		sbe_upgrade_error "unsupported running board: ${board:-unknown}" || return 1
	sbe_check_geometry && sbe_check_archive "$1"
}

sbe_p30_mount() {
	mkdir -p "$SBE_P30_MOUNT" || return 1
	mount -t ext4 -o rw,noatime,nosuid,nodev /dev/mmcblk0p30 "$SBE_P30_MOUNT" || return 1
}

sbe_p30_unmount() {
	sync
	umount "$SBE_P30_MOUNT"
	rmdir "$SBE_P30_MOUNT" 2>/dev/null || true
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

sbe_check_vendor_wifi_layout() {
	local vendor="$SBE_P30_MOUNT/vendor" wifi="$SBE_P30_MOUNT/vendor/wifi" item name bytes
	[ -e "$vendor" ] || return 0
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

sbe_check_p30_layout() {
	local item name
	[ -d "$SBE_P30_MOUNT/openwrt" ] && [ ! -L "$SBE_P30_MOUNT/openwrt" ] || return 1
	for item in "$SBE_P30_MOUNT"/* "$SBE_P30_MOUNT"/.[!.]* "$SBE_P30_MOUNT"/..?*; do
		[ -e "$item" ] || [ -L "$item" ] || continue
		name=${item##*/}
		case "$name" in
			lost+found|openwrt) ;;
			vendor) sbe_check_vendor_wifi_layout || return 1 ;;
			*) return 1 ;;
		esac
	done
	[ ! -e "$SBE_P30_MOUNT/openwrt/.factory-reset-pending" ] &&
	[ ! -e "$SBE_P30_MOUNT/openwrt/.factory-reset-committed" ]
}

sbe_stage_upgrade_config() {
	sbe_p30_mount || sbe_upgrade_error 'cannot mount p30 for upgrade transaction' || return 1
	if ! sbe_check_p30_layout; then
		sbe_p30_unmount >/dev/null 2>&1 || true
		sbe_upgrade_error 'p30 overlay layout is not safe to migrate'
		return 1
	fi
	rm -f "$SBE_P30_MOUNT/openwrt/.sysupgrade.tgz.pending"
	if [ -n "${UPGRADE_BACKUP:-}" ]; then
		[ -f "$UPGRADE_BACKUP" ] && [ ! -L "$UPGRADE_BACKUP" ] || {
			sbe_p30_unmount >/dev/null 2>&1 || true
			sbe_upgrade_error 'requested configuration backup is unavailable'
			return 1
		}
		cp "$UPGRADE_BACKUP" "$SBE_P30_MOUNT/openwrt/.sysupgrade.tgz.pending" || {
			sbe_p30_unmount >/dev/null 2>&1 || true
			return 1
		}
		chmod 600 "$SBE_P30_MOUNT/openwrt/.sysupgrade.tgz.pending"
	fi
	sbe_p30_unmount || sbe_upgrade_error 'cannot sync and unmount p30 staging mount'
}

sbe_commit_upgrade_config() {
	sbe_p30_mount || sbe_upgrade_error 'cannot remount p30 to commit upgrade transaction' || return 1
	if [ -n "${UPGRADE_BACKUP:-}" ]; then
		mv "$SBE_P30_MOUNT/openwrt/.sysupgrade.tgz.pending" \
			"$SBE_P30_MOUNT/openwrt/.sysupgrade.tgz" || return 1
	else
		rm -f "$SBE_P30_MOUNT/openwrt/.sysupgrade.tgz" \
			"$SBE_P30_MOUNT/openwrt/.sysupgrade.tgz.pending"
	fi
	touch "$SBE_P30_MOUNT/openwrt/.factory-reset" || return 1
	sbe_p30_unmount || sbe_upgrade_error 'cannot commit p30 upgrade transaction'
}

sbe_hash_device_prefix() {
	local device="$1" bytes="$2"
	head -c "$bytes" "$device" | sha256sum | awk '{print $1}'
}

platform_do_upgrade() {
	local image="$1" root_hash
	platform_check_image "$image" || exit 1
	sbe_stage_upgrade_config || exit 1

	echo 'Invalidating p25 before writing p27...'
	dd if=/dev/zero of=/dev/mmcblk0p25 bs=4096 count=1 2>/dev/null || exit 1
	sync
	echo 'Writing and verifying p27 root filesystem...'
	tar -Oxf "$image" "${SBE_UPGRADE_PREFIX}/root" 2>/dev/null |
		dd of=/dev/mmcblk0p27 bs=1024 2>/dev/null || exit 1
	sync
	root_hash=$(sbe_hash_device_prefix /dev/mmcblk0p27 "$SBE_VALIDATED_ROOT_SIZE")
	[ "$root_hash" = "$SBE_VALIDATED_ROOT_SHA256" ] || {
		sbe_upgrade_error 'p27 read-back verification failed'
		exit 1
	}

	echo 'Clearing p25 and writing the verified boot FIT last...'
	dd if=/dev/zero of=/dev/mmcblk0p25 bs=512 count="$SBE_P25_SECTORS" 2>/dev/null || exit 1
	tar -Oxf "$image" "${SBE_UPGRADE_PREFIX}/kernel" 2>/dev/null |
		dd of=/dev/mmcblk0p25 bs=1024 2>/dev/null || exit 1
	sync
	[ "$(sbe_hash_device_prefix /dev/mmcblk0p25 "$SBE_FIT_SIZE")" = "$SBE_FIT_SHA256" ] || {
		sbe_upgrade_error 'p25 read-back verification failed'
		exit 1
	}
	[ "$(sbe_hash_device_prefix /dev/mmcblk0p25 "$SBE_P25_SIZE")" = "$SBE_P25_CANONICAL_SHA256" ] || {
		sbe_upgrade_error 'p25 canonical full-partition verification failed'
		exit 1
	}

	dd if=/dev/zero of=/dev/mmcblk0p29 bs=512 count=8 2>/dev/null || exit 1
	sbe_commit_upgrade_config || exit 1
	sync
}

# p30 is migrated transactionally by platform_do_upgrade(); the generic eMMC
# backup writer must never place a tar stream at the start of this ext4 volume.
platform_copy_config() {
	return 0
}
