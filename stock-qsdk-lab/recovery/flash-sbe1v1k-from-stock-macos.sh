#!/bin/bash
# One-command SBE1V1K stock -> official OpenWrt initramfs -> QSDK install flow.
# The physical Reset/power-on step still has to be performed by the operator.
set -euo pipefail

readonly ROUTER_IP=192.168.1.1
readonly HOST_TFTP_IP=172.16.252.252
readonly HOST_RAM_IP=192.168.1.2
readonly OPENWRT_BASE_URL='https://downloads.openwrt.org/snapshots/targets/qualcommbe/ipq95xx'
readonly OPENWRT_INITRAMFS='openwrt-qualcommbe-ipq95xx-askey_sbe1v1k-initramfs-uImage.itb'
readonly DEFAULT_FIRMWARE_URL='https://github.com/yangzhg/SBE1V1K/releases/download/sbe1v1k-qsdk-1.5.3/sbe1v1k-qsdk-1.5.3-squashfs-sysupgrade.bin'
readonly SSH_TARGET="root@$ROUTER_IP"
readonly SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=5 -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no)

die() {
	printf 'error: %s\n' "$*" >&2
	exit 1
}

usage() {
	cat >&2 <<'EOF'
Usage:
  flash-sbe1v1k-from-stock-macos.sh ETHERNET_INTERFACE [FIRMWARE_URL]

Example:
  ./stock-qsdk-lab/recovery/flash-sbe1v1k-from-stock-macos.sh en7 \
    https://github.com/yangzhg/SBE1V1K/releases/download/sbe1v1k-qsdk-1.5.3/sbe1v1k-qsdk-1.5.3-squashfs-sysupgrade.bin

The published QSDK release is the default. Pass another firmware URL as the
second argument when testing a different release. Set SBE_FIRMWARE_SHA256 to
verify an externally supplied checksum; otherwise the script prints the
downloaded hash and relies on the target's sysupgrade image validation.
EOF
	exit 2
}

[ "$#" -ge 1 ] && [ "$#" -le 2 ] || usage
interface=$1
firmware_url=${2:-${SBE_FIRMWARE_URL:-$DEFAULT_FIRMWARE_URL}}
case "$interface" in en[0-9]*) ;; *) die "unexpected macOS Ethernet interface: $interface" ;; esac
[ "$(uname -s)" = Darwin ] || die 'this helper currently supports macOS only'

dnsmasq_bin=$(command -v dnsmasq 2>/dev/null || true)
if [ -z "$dnsmasq_bin" ] && [ -x /opt/homebrew/opt/dnsmasq/sbin/dnsmasq ]; then
	dnsmasq_bin=/opt/homebrew/opt/dnsmasq/sbin/dnsmasq
fi
[ -n "$dnsmasq_bin" ] || die 'missing command: dnsmasq (install it with Homebrew)'

for tool in curl dtc dumpimage ifconfig mkimage pgrep route scp shasum ssh sudo; do
	command -v "$tool" >/dev/null 2>&1 || \
		die "missing command: $tool (install dnsmasq, u-boot-tools and dtc with Homebrew)"
done
ifconfig "$interface" >/dev/null 2>&1 || die "network interface does not exist: $interface"

work_dir=$(mktemp -d /private/tmp/sbe1v1k-flash.XXXXXX)
tftp_root="$work_dir/tftp"
dnsmasq_log="$work_dir/dnsmasq.log"
sysupgrade_log="$work_dir/sysupgrade.log"
tftp_job=
finished=0

matching_tftp_pids() {
	pgrep -f "${dnsmasq_bin}.*--interface=${interface}.*--tftp-root=${tftp_root}" 2>/dev/null || true
}

stop_tftp() {
	local pids
	pids=$(matching_tftp_pids)
	if [ -n "$pids" ]; then
		# pgrep emits only decimal PIDs. shellcheck disable=SC2086
		sudo /bin/kill -TERM $pids 2>/dev/null || true
		for _ in 1 2 3 4 5; do
			[ -z "$(matching_tftp_pids)" ] && break
			sleep 1
		done
	fi
	[ -z "$tftp_job" ] || wait "$tftp_job" 2>/dev/null || true
	tftp_job=
}

cleanup() {
	stop_tftp
	if [ "$finished" -eq 1 ]; then
		rm -rf "$work_dir"
	else
		printf 'diagnostic files kept at %s\n' "$work_dir" >&2
	fi
}
trap cleanup EXIT HUP INT TERM

printf 'Checking sudo access and downloading inputs before changing the Ethernet interface...\n'
sudo -v
mkdir -p "$tftp_root"

curl --fail --location --retry 3 \
	"$OPENWRT_BASE_URL/$OPENWRT_INITRAMFS" \
	-o "$work_dir/$OPENWRT_INITRAMFS"
curl --fail --location --retry 3 \
	"$OPENWRT_BASE_URL/sha256sums" \
	-o "$work_dir/openwrt-sha256sums"
(
	cd "$work_dir"
	grep -F "$OPENWRT_INITRAMFS" openwrt-sha256sums | shasum -a 256 -c -
) || die 'official OpenWrt initramfs checksum verification failed'
initramfs_size=$(wc -c < "$work_dir/$OPENWRT_INITRAMFS" | tr -d ' ')
[ "$initramfs_size" -le 32505856 ] || die 'official initramfs exceeds the stock recovery size limit'

curl --fail --location --retry 3 "$firmware_url" -o "$work_dir/firmware.bin"
firmware_sha=$(shasum -a 256 "$work_dir/firmware.bin" | awk '{print $1}')
if [ -n "${SBE_FIRMWARE_SHA256:-}" ]; then
	[ "$firmware_sha" = "$SBE_FIRMWARE_SHA256" ] || die 'downloaded firmware SHA-256 mismatch'
fi
printf 'Firmware SHA-256: %s\n' "$firmware_sha"

cat > "$work_dir/boot.cmd" <<'EOF'
setenv serverip 172.16.252.252
tftpboot 0x80000000 initramfs.itb
bootm 0x80000000
EOF
cat > "$work_dir/auto.its" <<'EOF'
/dts-v1/;
/ {
	description = "SBE1V1K recovery launcher";
	#address-cells = <1>;
	images {
		RTQ7300T {
			description = "model marker";
			data = [00];
			type = "firmware";
			arch = "arm";
			compression = "none";
			hash-1 { algo = "sha256"; };
		};
		script {
			description = "boot OpenWrt initramfs";
			data = /incbin/("boot.cmd");
			type = "script";
			arch = "arm";
			compression = "none";
			hash-1 { algo = "sha256"; };
		};
	};
};
EOF
(
	cd "$work_dir"
	mkimage -f auto.its rtq7300t_boot_auto_upgrade_fw.img >/dev/null
	dumpimage -l rtq7300t_boot_auto_upgrade_fw.img >/dev/null
)
install -m 0644 "$work_dir/rtq7300t_boot_auto_upgrade_fw.img" \
	"$tftp_root/rtq7300t_boot_auto_upgrade_fw.img"
install -m 0644 "$work_dir/$OPENWRT_INITRAMFS" "$tftp_root/initramfs.itb"
chmod 0755 "$work_dir" "$tftp_root"

# Refuse a stale service on the selected interface; do not mix two recovery runs.
stale=$(pgrep -f "[d]nsmasq.*--interface=${interface}.*--enable-tftp" 2>/dev/null || true)
[ -z "$stale" ] || die "another dnsmasq recovery service is already using $interface (PID $stale)"

sudo /usr/sbin/ipconfig set "$interface" MANUAL "$HOST_TFTP_IP" 255.255.0.0
sudo ifconfig "$interface" inet "$HOST_TFTP_IP" netmask 255.255.0.0 up
sudo ifconfig "$interface" alias "$HOST_RAM_IP" netmask 255.255.255.0 2>/dev/null || true
route -n get "$ROUTER_IP" | grep -q "interface: $interface" || \
	die "$ROUTER_IP is not routed through $interface; remove the conflicting 192.168.1.0/24 route"

sudo "$dnsmasq_bin" \
	--keep-in-foreground \
	--interface="$interface" \
	--bind-interfaces \
	--port=0 \
	--dhcp-authoritative \
	--dhcp-broadcast \
	--dhcp-range=172.16.252.10,172.16.252.20,255.255.0.0,5m \
	--dhcp-option=43,askey \
	--dhcp-option=3 \
	--dhcp-option=6 \
	--enable-tftp \
	--tftp-root="$tftp_root" \
	--log-facility="$dnsmasq_log" \
	--log-dhcp &
tftp_job=$!

cat <<EOF

DHCP/TFTP is ready on $interface.
1. Connect the Mac directly to the router's 2.5G LAN port (not WAN).
2. Power the router off for five seconds.
3. Hold Reset, power it on, and release Reset after about 12 seconds.

The script will continue automatically when the official RAM system is ready.
EOF

ram_ready=0
for _ in $(seq 1 90); do
	if state=$(ssh "${SSH_OPTS[@]}" "$SSH_TARGET" \
		'printf "board="; cat /tmp/sysinfo/board_name 2>/dev/null; printf "root="; awk '\''$2=="/" {print $1,$3}'\'' /proc/mounts' 2>/dev/null); then
		if printf '%s\n' "$state" | grep -qx 'board=askey,sbe1v1k' && \
		   printf '%s\n' "$state" | grep -qx 'root=tmpfs tmpfs'; then
			ram_ready=1
			break
		fi
	fi
	sleep 4
done
[ "$ram_ready" -eq 1 ] || die 'official OpenWrt initramfs did not become ready within six minutes'
printf 'Official OpenWrt initramfs is ready. Stopping DHCP/TFTP before changing boot settings.\n'
stop_tftp
[ -z "$(matching_tftp_pids)" ] || die 'DHCP/TFTP did not stop'

# Only validate the inputs that decide whether this exact operation is valid.
ssh "${SSH_OPTS[@]}" "$SSH_TARGET" 'sh -s' <<'REMOTE'
set -eu
fail() { echo "input check failed: $*" >&2; exit 1; }
[ "$(cat /tmp/sysinfo/board_name)" = askey,sbe1v1k ] || fail 'wrong board'
awk '$2=="/" && $1=="tmpfs" && $3=="tmpfs" {ok=1} END {exit !ok}' /proc/mounts || fail 'not running from RAM'
for tool in fw_printenv fw_setenv sha256sum sysupgrade; do command -v "$tool" >/dev/null || fail "missing $tool"; done
check_part() {
	name=$1 label=$2 start=$3 sectors=$4
	[ "$(sed -n 's/^PARTNAME=//p' /sys/class/block/$name/uevent)" = "$label" ] || fail "$name label"
	[ "$(cat /sys/class/block/$name/start)" = "$start" ] || fail "$name start"
	[ "$(cat /sys/class/block/$name/size)" = "$sectors" ] || fail "$name size"
}
check_part mmcblk0p17 '0:APPSBLENV' 28706 512
check_part mmcblk0p25 '0:HLOS' 81954 14336
check_part mmcblk0p27 rootfs 110626 249856
check_part mmcblk0p29 rootfs_data 610338 1048576
check_part mmcblk0p30 rootfs_data_1 1658914 1048576
REMOTE

scp -O "${SSH_OPTS[@]}" "$work_dir/firmware.bin" "$SSH_TARGET:/tmp/firmware.bin"
remote_sha=$(ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "sha256sum /tmp/firmware.bin | cut -d ' ' -f1")
[ "$remote_sha" = "$firmware_sha" ] || die 'firmware changed during transfer'
ssh "${SSH_OPTS[@]}" "$SSH_TARGET" 'sysupgrade -n -T /tmp/firmware.bin' || \
	die 'sysupgrade rejected the firmware'

cat > "$work_dir/mainline.env" <<'EOF'
bootargs console=ttyMSM0,115200n8 rootwait root=/dev/mmcblk0p27
do_boot mmc read 0x44000000 0x00014022 0x3800; bootm 0x44000000
do_nothing echo "Boot aborted by user. You are now in the U-Boot shell."
bootcmd echo ""; echo "=== U-Boot Boot Sequence Start ==="; echo "Hit Ctrl+C within 3 seconds to enter shell."; echo ""; if sleep 3; then echo "No Ctrl+C detected - continuing automatic boot."; echo "Attempting TFTP boot (only available when RESET initialized Ethernet)..."; setenv ipaddr 192.168.1.1; setenv serverip 192.168.1.2; tftpboot 0x80000000 initramfs.itb; if test $? -eq 0; then echo "TFTP succeeded - booting downloaded initramfs image..."; bootm 0x80000000; else echo "TFTP failed - falling back to MMC boot."; run do_boot; fi; else echo "Ctrl+C detected - entering U-Boot shell."; run do_nothing; fi; echo "=== U-Boot Boot Sequence End ===";
EOF
scp -O "${SSH_OPTS[@]}" "$work_dir/mainline.env" "$SSH_TARGET:/tmp/mainline.env"

ssh "${SSH_OPTS[@]}" "$SSH_TARGET" 'sh -s' <<'REMOTE'
set -eu
stock_bootargs='console=ttyMSM0,115200n8'
stock_bootcmd='aq_load_fw 0x0 && bootipq'
main_bootargs='console=ttyMSM0,115200n8 rootwait root=/dev/mmcblk0p27'
main_do_boot='mmc read 0x44000000 0x00014022 0x3800; bootm 0x44000000'
main_do_nothing='echo "Boot aborted by user. You are now in the U-Boot shell."'
main_bootcmd='echo ""; echo "=== U-Boot Boot Sequence Start ==="; echo "Hit Ctrl+C within 3 seconds to enter shell."; echo ""; if sleep 3; then echo "No Ctrl+C detected - continuing automatic boot."; echo "Attempting TFTP boot (only available when RESET initialized Ethernet)..."; setenv ipaddr 192.168.1.1; setenv serverip 192.168.1.2; tftpboot 0x80000000 initramfs.itb; if test $? -eq 0; then echo "TFTP succeeded - booting downloaded initramfs image..."; bootm 0x80000000; else echo "TFTP failed - falling back to MMC boot."; run do_boot; fi; else echo "Ctrl+C detected - entering U-Boot shell."; run do_nothing; fi; echo "=== U-Boot Boot Sequence End ===";'
read_env() { fw_printenv -n "$1" 2>/dev/null || true; }
bootargs=$(read_env bootargs); bootcmd=$(read_env bootcmd)
do_boot=$(read_env do_boot); do_nothing=$(read_env do_nothing)
if [ "$bootargs" = "$main_bootargs" ] && [ "$bootcmd" = "$main_bootcmd" ] && \
   [ "$do_boot" = "$main_do_boot" ] && [ "$do_nothing" = "$main_do_nothing" ]; then
	echo 'U-Boot environment is already configured.'
elif [ "$bootargs" = "$stock_bootargs" ] && [ "$bootcmd" = "$stock_bootcmd" ]; then
	fw_setenv --script /tmp/mainline.env
else
	echo 'input check failed: U-Boot environment is neither stock nor the supported mainline state' >&2
	exit 1
fi
[ "$(read_env bootargs)" = "$main_bootargs" ]
[ "$(read_env do_boot)" = "$main_do_boot" ]
[ "$(read_env do_nothing)" = "$main_do_nothing" ]
[ "$(read_env bootcmd)" = "$main_bootcmd" ]
REMOTE

old_boot_id=$(ssh "${SSH_OPTS[@]}" "$SSH_TARGET" 'cat /proc/sys/kernel/random/boot_id')
printf 'Starting sysupgrade. Do not remove power.\n'
set +e
ssh "${SSH_OPTS[@]}" "$SSH_TARGET" 'exec sysupgrade -n -v /tmp/firmware.bin' \
	2>&1 | tee "$sysupgrade_log"
upgrade_status=${PIPESTATUS[0]}
set -e
grep -Fq 'upgrade: Commencing upgrade. Closing all shell sessions.' "$sysupgrade_log" || \
	die "sysupgrade did not reach the handoff point (status $upgrade_status)"
case "$upgrade_status" in 0|246|255) ;; *) die "unexpected sysupgrade status: $upgrade_status" ;; esac

printf 'Waiting for the installed firmware...\n'
new_ready=0
for _ in $(seq 1 120); do
	if state=$(ssh "${SSH_OPTS[@]}" "$SSH_TARGET" \
		'printf "boot="; cat /proc/sys/kernel/random/boot_id; printf "board="; cat /tmp/sysinfo/board_name 2>/dev/null; printf "cmdline="; cat /proc/cmdline; printf "overlay="; cat /tmp/sbe-overlay-mode 2>/dev/null' 2>/dev/null); then
		new_boot=$(printf '%s\n' "$state" | sed -n 's/^boot=//p')
		if [ -n "$new_boot" ] && [ "$new_boot" != "$old_boot_id" ] && \
		   printf '%s\n' "$state" | grep -qx 'board=qcom,ipq9574-ap-al02-c4' && \
		   printf '%s\n' "$state" | grep -q '^cmdline=.*root=/dev/mmcblk0p27' && \
		   printf '%s\n' "$state" | grep -qx 'overlay=persistent'; then
			printf '%s\n' "$state"
			new_ready=1
			break
		fi
	fi
	sleep 5
done
[ "$new_ready" -eq 1 ] || die 'installed firmware did not become ready within ten minutes'

finished=1
printf '\nSUCCESS: SBE1V1K is running the installed QSDK firmware at https://%s/\n' "$ROUTER_IP"
printf 'The default root password is empty; run passwd before connecting WAN.\n'
