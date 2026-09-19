#!/bin/sh
set -eu

stock_image=${1:?usage: assemble-rootfs STOCK_IMAGE OUTPUT_IMAGE ROOTFS_DATA_LABEL MOUNT_POLICY COMPONENT_PROFILE}
output_image=${2:?usage: assemble-rootfs STOCK_IMAGE OUTPUT_IMAGE ROOTFS_DATA_LABEL MOUNT_POLICY COMPONENT_PROFILE}
rootfs_data_label=${3:-rootfs_data_1}
mount_policy=${4:-normal}
component_profile=${5:-production}
feed_policy=${SBE_FEED_POLICY:-embedded}
case "$feed_policy" in
	embedded|external) ;;
	*) printf 'invalid feed policy: %s\n' "$feed_policy" >&2; exit 1 ;;
esac
# Package selection and archive caching are independent. Preserve the legacy
# low-level defaults; the release entrypoint selects both values explicitly.
package_profile=${SBE_PACKAGE_PROFILE:-}
if [ -z "$package_profile" ]; then
	case "$feed_policy" in embedded) package_profile=passwall ;; external) package_profile=base ;; esac
fi
case "$package_profile" in
	base|passwall) ;;
	*) printf 'invalid package profile: %s\n' "$package_profile" >&2; exit 1 ;;
esac
source_commit=${SBE_SOURCE_COMMIT:?SBE_SOURCE_COMMIT is required for release provenance}
case "$source_commit" in
	''|*[!0-9a-f]*) printf 'invalid source commit: %s\n' "$source_commit" >&2; exit 1 ;;
esac
[ "${#source_commit}" -eq 40 ] || {
	printf 'source commit is not a full object ID: %s\n' "$source_commit" >&2
	exit 1
}
source_dirty=${SBE_SOURCE_DIRTY:-false}
case "$source_dirty" in true|false) ;; *) printf 'invalid source dirty state\n' >&2; exit 1 ;; esac
source_diff_sha256=${SBE_SOURCE_DIFF_SHA256:-clean}
case "$source_diff_sha256" in
	clean) [ "$source_dirty" = false ] || { printf 'dirty source needs a diff digest\n' >&2; exit 1; } ;;
	*[!0-9a-f]*|'') printf 'invalid source diff digest\n' >&2; exit 1 ;;
	*) [ "${#source_diff_sha256}" -eq 64 ] || { printf 'invalid source diff digest length\n' >&2; exit 1; } ;;
esac
case "$rootfs_data_label" in
	rootfs_data_1) ;;
	*)
		printf 'invalid rootfs data label: %s\n' "$rootfs_data_label" >&2
		exit 1
		;;
esac
case "$mount_policy" in
	normal|trial-safe) ;;
	*)
		printf 'invalid mount policy: %s\n' "$mount_policy" >&2
		exit 1
		;;
esac
case "$component_profile" in
	''|*[!a-z0-9-]*|-*|*-)
		printf 'invalid component profile name: %s\n' "$component_profile" >&2
		exit 1
		;;
esac
component_profile_path=/lab/component-profiles/$component_profile.json
[ -f "$component_profile_path" ] || {
	printf 'component profile does not exist: %s\n' "$component_profile" >&2
	exit 1
}

root=/work/rootfs
luci_overlay=/work/luci-overlay
control_root=/work/ipk-control
component_overlay=/work/component-overlay
local_feed=/work/sbe-local-feed
component_report=/work/component-profile-report.json
luci_finalization_report=/work/luci-finalization-report.json
stock_usb_baseline=/work/stock-usb-baseline
manifest=/lab/work/luci-package-manifest.tsv
baseline_path=${SBE_BASELINE_PATH:-/lab/stock-baseline.env}
[ -f "$baseline_path" ] || {
	printf 'source baseline is missing: %s\n' "$baseline_path" >&2
	exit 1
}
. "$baseline_path"

stock_sha256=$(sha256sum "$stock_image" | awk '{print $1}')
[ "$stock_sha256" = "$STOCK_P27_SHA256" ] || {
	printf 'unexpected stock p27 SHA-256: %s\n' "$stock_sha256" >&2
	exit 1
}
[ "$(stat -c %s "$stock_image")" = "$STOCK_P27_PARTITION_SIZE" ] || {
	printf 'unexpected stock p27 partition size\n' >&2
	exit 1
}

rm -rf "$root" "$luci_overlay" "$control_root" "$component_overlay" "$local_feed" "$stock_usb_baseline"
rm -f "$component_report" "$luci_finalization_report"
mkdir -p "$root" "$luci_overlay" "$control_root" "$(dirname "$output_image")"

unsquashfs -d "$root" "$stock_image" >/dev/null
# Preserve only the native userland package inputs before overlay/promotion.
# Resolve absolute symlinks within the vendor tree, never against the host.
vendor_userland=$(mktemp -d /work/vendor-userland.XXXXXX)
python3 /lab/feed/build_base_userland.py --capture "$root" --output "$vendor_userland"
python3 /lab/tools/patch_stock_rootfs.py \
	--capture-stock-usb-baseline "$stock_usb_baseline" "$root"
install -m 0755 "$root/usr/sbin/dnsmasq" /work/stock-dnsmasq
install -m 0755 "$root/sbin/led_ctl" /work/stock-led-ctl
[ -f "$root/lib/libustream-ssl.so" ] && \
	[ ! -L "$root/lib/libustream-ssl.so" ] || {
	printf 'factory libustream-ssl ABI is missing or not a regular file\n' >&2
	exit 1
}
stock_ustream_sha256=$(sha256sum "$root/lib/libustream-ssl.so" | awk '{print $1}')
[ -z "${STOCK_USTREAM_SSL_SHA256:-}" ] || [ "$stock_ustream_sha256" = "$STOCK_USTREAM_SSL_SHA256" ] || {
	printf 'factory libustream-ssl ABI hash mismatch: %s\n' \
		"$stock_ustream_sha256" >&2
	exit 1
}

tail -n +2 "$manifest" | while IFS="$(printf '\t')" read -r package version feed filename sha256 url; do
	ipk="/lab/cache/ipk/$filename"
	[ -f "$ipk" ] || {
		printf 'missing package: %s\n' "$ipk" >&2
		exit 1
	}
	actual=$(sha256sum "$ipk" | awk '{print $1}')
	[ "$actual" = "$sha256" ] || {
		printf 'checksum mismatch: %s\n' "$ipk" >&2
		exit 1
	}
	tar -xOzf "$ipk" ./data.tar.gz | tar -xzf - -C "$luci_overlay"
done

rsync -a "$luci_overlay/" "$root/"
rsync -a /lab/overlay/ "$root/"
if [ -n "${SBE_DERIVED_SOURCE_PATH:-}" ]; then
	vendor_wifi_source=$(dirname "$stock_image")/stock-wifi.squashfs
	python3 /lab/tools/write_upgrade_source.py \
		--derived "$SBE_DERIVED_SOURCE_PATH" \
		--fit "$(dirname "$stock_image")/stock-p25.fit" \
		--wifi "$vendor_wifi_source" \
		--root "$root"
	unsquashfs -d "$root/usr/share/sbe-wififw" "$vendor_wifi_source" >/dev/null
	[ -f "$root/usr/share/sbe-wififw/qcn9224/amss.bin" ] || {
		printf '1.5.3 vendor QCN9224 firmware is missing\n' >&2
		exit 1
	}
	printf 'qcn9224_amss_sha256=%s\n' \
		"$(sha256sum "$root/usr/share/sbe-wififw/qcn9224/amss.bin" | awk '{print $1}')" \
		>> "$root/usr/share/sbe-build/vendor-wifi-source"
	install -d -m 0755 "$root/lib/firmware/IPQ9574"
	[ ! -e "$root/lib/firmware/IPQ9574/WIFI_FW" ] || {
		printf 'stock root unexpectedly contains an embedded Wi-Fi mount path\n' >&2
		exit 1
	}
	ln -s /usr/share/sbe-wififw "$root/lib/firmware/IPQ9574/WIFI_FW"
fi
if [ "$component_profile" = production ]; then
	# Native QSDK NTP service paired with the BusyBox ntpd component.
	rsync -a /lab/busybox-candidate/rootfs-payload/ "$root/"
	rsync -a /lab/logd-candidate/rootfs-payload/ "$root/"
	ln -sf ../../bin/busybox "$root/usr/sbin/ntpd"
fi

# Stage the byte-preserved native PassWall packages and their user-space
# dependencies into a normal offline opkg feed. Qualified additive kernel
# support is packaged after component finalization below.
mkdir -p "$local_feed"
python3 /lab/feed/stage_native_feed.py \
	--lab /lab --output "$local_feed" >/dev/null
python3 /lab/feed/make_packages_index.py \
	--input "$local_feed" --output "$local_feed/Packages" >/dev/null
gzip -n -9 -c "$local_feed/Packages" > "$local_feed/Packages.gz"
if [ "$feed_policy" = embedded ]; then
	# Derived releases finalize their LuCI packages below. Do not leave raw,
	# superseded IPKs alongside those finalized packages in the built-in source.
	if [ -z "${SBE_DERIVED_SOURCE_PATH:-}" ]; then
		install -d -m 0755 "$root/usr/share/sbe-feed"
		cp -p "$local_feed"/*.ipk "$local_feed/Packages" "$local_feed/Packages.gz" \
			"$local_feed/Native-Packages.tsv" \
			"$root/usr/share/sbe-feed/"
	fi
else
	# A feed is a release artifact, not a copy of every optional IPK in flash.
	sed -i '/^src\/gz sbe_local file:\/\/\/usr\/share\/sbe-feed$/d' "$root/etc/opkg.conf"
	install -d -m 0755 "$root/usr/share/sbe-build"
	printf 'external\n' > "$root/usr/share/sbe-build/feed-policy"
fi
install -d -m 0755 "$root/usr/libexec"
install -d -m 0755 "$root/usr/libexec/sbe-optional"
install -m 0700 /work/stock-led-ctl "$root/usr/libexec/sbe-led-ctl-real"
install -d -m 0755 "$root/usr/share/sbe-opkg"
install -m 0755 /lab/device/sbe-p30-audit.sh "$root/usr/sbin/sbe-p30-audit"
# Keep the QSDK dnsmasq binary while taking the standard OpenWrt init script
# and configuration from the ABI-compatible package.
install -m 0755 /work/stock-dnsmasq "$root/usr/sbin/dnsmasq"
install -d -m 0700 "$root/etc/dropbear"
# Ship no user-specific key.  The first boot follows OpenWrt convention:
# root has an empty password and Dropbear accepts it only on the LAN listener.
rm -f "$root/etc/dropbear/authorized_keys"

# The factory database has no valid Package/Version/Status records.  Rebuild a
# truthful database for baked packages. Exact factory versions are unavailable,
# so the neutral 0-factory version lets configured feeds offer replacements;
# opkg and the administrator retain the final compatibility decision.
opkg_info="$root/usr/lib/opkg/info"
opkg_status="$root/usr/lib/opkg/status"
install -d -m 0755 "$opkg_info"
: > "$opkg_status"
while IFS= read -r package; do
	case "$package" in ''|\#*) continue ;; esac
	cat >> "$opkg_status" <<EOF
Package: $package
Version: 0-factory
Architecture: aarch64_cortex-a73_neon-vfpv4
Status: install ok installed
Auto-Installed: yes

EOF
done < /lab/stock-provided-packages.txt

tail -n +2 "$manifest" | while IFS="$(printf '\t')" read -r package version feed filename sha256 url; do
	ipk="/lab/cache/ipk/$filename"
	package_control="$control_root/$package"
	installed_package=$package
	mkdir -p "$package_control"
	tar -xOzf "$ipk" ./control.tar.gz | tar -xzf - -C "$package_control"
	if [ "$package" = dnsmasq-dhcpv6 ]; then
		# Only the generic 19.07 init/config payload is used.  The executable
		# was replaced above with the byte-preserved factory QSDK 2.89 build,
		# so never publish the downloaded 2.80 package as installed.
		installed_package=dnsmasq
		cat > "$opkg_info/$installed_package.control" <<'EOF'
Package: dnsmasq
Version: 2.89-sbe1
Architecture: aarch64_cortex-a73_neon-vfpv4
Provides: dnsmasq-dhcpv6
Description: Factory Qualcomm QSDK dnsmasq 2.89 with local OpenWrt control files
EOF
	else
		install -m 0644 "$package_control/control" \
			"$opkg_info/$installed_package.control"
	fi
	for metadata in conffiles preinst postinst prerm postrm; do
		[ -f "$package_control/$metadata" ] || continue
		# Do not attach removal/install scripts from the discarded 2.80
		# executable to the factory-owned 2.89 service.
		if [ "$package" = dnsmasq-dhcpv6 ] && [ "$metadata" != conffiles ]; then
			continue
		fi
		mode=0644
		[ "$metadata" = conffiles ] || mode=0755
		install -m "$mode" "$package_control/$metadata" \
			"$opkg_info/$installed_package.$metadata"
	done
	tar -xOzf "$ipk" ./data.tar.gz | tar -tzf - | \
		sed -e 's#^\./#/#' -e '/\/$/d' > "$opkg_info/$installed_package.list"
	cat "$opkg_info/$installed_package.control" >> "$opkg_status"
	printf 'Status: install ok installed\nAuto-Installed: yes\n\n' >> "$opkg_status"
done

record_local_ipk() {
	ipk=$1
	install_reason=$2
	extract_payload=$3
	replace_record=$4
	package_control=$(mktemp -d "$control_root/local.XXXXXX")
	tar -xOzf "$ipk" ./control.tar.gz | tar -xzf - -C "$package_control"
	package=$(sed -n 's/^Package:[[:space:]]*//p' "$package_control/control" | sed -n '1p')
	case "$package" in ''|*[!A-Za-z0-9+._-]*) echo "invalid local package name: $package" >&2; exit 1 ;; esac
	if awk -v wanted="$package" '$1 == "Package:" && $2 == wanted { found=1 } END { exit !found }' "$opkg_status"; then
		if [ "$replace_record" != yes ]; then
			printf 'local package already exists in status: %s\n' "$package" >&2
			exit 1
		fi
		status_without_package=$(mktemp "$control_root/status.XXXXXX")
		awk -v wanted="$package" '
			BEGIN { RS=""; ORS="" }
			{
				installed=""
				line_count=split($0, lines, "\n")
				for (line=1; line<=line_count; line++)
					if (lines[line] ~ /^Package:[[:space:]]*/ ) {
						installed=lines[line]
						sub(/^Package:[[:space:]]*/, "", installed)
						break
					}
				if (installed != wanted) print $0 "\n\n"
			}' "$opkg_status" > "$status_without_package"
		mv "$status_without_package" "$opkg_status"
		for old_metadata in "$opkg_info/$package".*; do
			[ -f "$old_metadata" ] || [ -L "$old_metadata" ] || continue
			rm -f "$old_metadata"
		done
	fi
	if [ "$extract_payload" = yes ]; then
		tar -xOzf "$ipk" ./data.tar.gz | tar -xzf - -C "$root"
	fi
	install -m 0644 "$package_control/control" "$opkg_info/$package.control"
	for metadata in conffiles preinst postinst postinst-pkg prerm postrm; do
		[ -f "$package_control/$metadata" ] || continue
		mode=0644
		[ "$metadata" = conffiles ] || mode=0755
		install -m "$mode" "$package_control/$metadata" "$opkg_info/$package.$metadata"
	done
	tar -xOzf "$ipk" ./data.tar.gz | tar -tzf - | \
		sed -e 's#^\./#/#' -e '/\/$/d' > "$opkg_info/$package.list"
	cat "$opkg_info/$package.control" >> "$opkg_status"
	printf 'Status: install ok installed\n' >> "$opkg_status"
	[ "$install_reason" = manual ] || printf 'Auto-Installed: yes\n' >> "$opkg_status"
	if [ -s "$package_control/conffiles" ]; then
		printf 'Conffiles:\n' >> "$opkg_status"
		while IFS= read -r config_path; do
			[ -n "$config_path" ] || continue
			case "$config_path" in
				/*) ;;
				*) printf 'invalid conffile path for %s: %s\n' "$package" "$config_path" >&2; exit 1 ;;
			esac
			[ -f "$root$config_path" ] || {
				printf 'missing conffile for %s: %s\n' "$package" "$config_path" >&2
				exit 1
			}
			config_md5=$(md5sum "$root$config_path" | awk '{print $1}')
			printf ' %s %s\n' "$config_path" "$config_md5" >> "$opkg_status"
		done < "$package_control/conffiles"
	fi
	printf '\n' >> "$opkg_status"

	# OpenWrt's coreutils subpackages carry their standard command links in the
	# native Alternatives field. Because image assembly extracts these packages
	# offline, materialize the same links now; opkg retains the original field
	# and will manage them normally on a later upgrade or removal.
	alternatives=$(sed -n 's/^Alternatives:[[:space:]]*//p' "$package_control/control")
	if [ -n "$alternatives" ]; then
		printf '%s\n' "$alternatives" | tr ',' '\n' | while IFS= read -r alternative; do
			alternative=$(printf '%s' "$alternative" | sed 's/^[[:space:]]*//')
			alternative_path=$(printf '%s' "$alternative" | cut -d: -f2)
			alternative_target=$(printf '%s' "$alternative" | cut -d: -f3-)
			case "$alternative_path:$alternative_target" in
				/*:/*) ;;
				*) printf 'invalid alternative for %s: %s\n' "$package" "$alternative" >&2; exit 1 ;;
			esac
			[ -e "$root$alternative_target" ] || {
				printf 'missing alternative target for %s: %s\n' "$package" "$alternative_target" >&2
				exit 1
			}
			install -d -m 0755 "$(dirname "$root$alternative_path")"
			ln -sf "$alternative_target" "$root$alternative_path"
		done
	fi
}

install_local_ipk() {
	record_local_ipk "$1" "$2" yes no
}

if [ "$component_profile" = production ]; then
	# The stock SquashFS only carries /dev/console; early boot populates /dev.
	# Give the offline chroot a real temporary null device so redirections do
	# not accidentally bake a regular /dev/null file into the image.
	created_null=no
	if [ ! -e "$root/dev/null" ] && [ ! -L "$root/dev/null" ]; then
		mknod -m 0666 "$root/dev/null" c 1 3
		created_null=yes
	fi
	[ -c "$root/dev/null" ] || {
		printf 'offline target /dev/null is not a character device\n' >&2
		exit 1
	}
	tail -n +2 "$local_feed/Native-Packages.tsv" | \
		while IFS="$(printf '\t')" read -r package install_reason package_file \
			package_sha256 package_version package_architecture package_source package_depends; do
			[ "$install_reason" != no ] || continue
			if [ "$package_profile" = base ]; then
				case "$package" in
					odhcp6c) install_reason=auto ;;
					*) continue ;;
				esac
			fi
			[ "$(sha256sum "$local_feed/$package_file" | awk '{print $1}')" = \
				"$package_sha256" ] || {
				printf 'native feed package changed after staging: %s\n' "$package" >&2
				exit 1
			}
			install_local_ipk "$local_feed/$package_file" "$install_reason"
		done
fi

patch_args=""
[ "$mount_policy" = trial-safe ] && patch_args=--trial-safe
python3 /lab/tools/patch_stock_rootfs.py \
	--rootfs-data-label "$rootfs_data_label" \
	--stock-usb-baseline "$stock_usb_baseline" \
	--component-profile "$component_profile_path" \
	$patch_args "$root"
python3 /lab/tools/apply_component_profile.py \
	--root "$root" \
	--lab /lab \
	--profile "$component_profile_path" \
	--name "$component_profile" \
	--report "$component_report" \
	--overlay-output "$component_overlay"
if [ "$component_profile" = production ]; then
	python3 /lab/tools/finalize_component_luci.py \
		--root "$root" \
		--profile "$component_profile_path" \
		--local-overlay /lab/overlay \
		--component-overlay "$component_overlay" \
		--lock /lab/security/luci-finalization.lock.tsv \
		--report "$luci_finalization_report"
	# The component profile promotes dnsmasq-full's exact payload, then records
	# canonical source provenance. Restore the native IPK's complete package
	# metadata so future opkg upgrades retain its configuration and scripts.
	dnsmasq_full_ipk=$(awk -F "$(printf '\t')" '$1 == "dnsmasq-full" { print $3 }' \
		"$local_feed/Native-Packages.tsv")
	[ -n "$dnsmasq_full_ipk" ] || {
		printf 'dnsmasq-full is missing from the native feed record\n' >&2
		exit 1
	}
	record_local_ipk "$local_feed/$dnsmasq_full_ipk" auto no yes
	python3 /lab/feed/check_native_payloads.py --lab /lab --root "$root"
	# apply_component_profile installs the package's generic conffile so the
	# canonical opkg record keeps its original baseline checksum.  Restore the
	# selected SBE1V1K board default afterwards, exactly as an ordinary opkg
	# install preserves an administrator-modified conffile.
	install -m 0644 /lab/overlay/etc/config/dhcp "$root/etc/config/dhcp"
fi
python3 /lab/tools/populate_stock_package_files.py "$root"
if [ -n "${SBE_DERIVED_SOURCE_PATH:-}" ]; then
	python3 /lab/feed/build_base_userland.py \
		--root "$root" --vendor-root "$vendor_userland" \
		--derived "$SBE_DERIVED_SOURCE_PATH" --output "$local_feed"
	python3 /lab/feed/build_board_packages.py \
		--root "$root" --derived "$SBE_DERIVED_SOURCE_PATH" \
		--output "$local_feed"
	python3 /lab/feed/build_platform_packages.py \
		--root "$root" --output "$local_feed" --source-commit "$source_commit"
	python3 /lab/feed/package_finalized_luci.py \
		--root "$root" --lab /lab --profile "$component_profile_path" \
		--lock /lab/security/luci-finalization.lock.tsv --output "$local_feed"
	python3 /lab/feed/build_kernel_packages.py \
		--root "$root" --output "$local_feed" --factory "$stock_image" \
		--derived "$SBE_DERIVED_SOURCE_PATH" \
		--lock /lab/sources/kernel-support-1.5.3.json \
		--modules /lab/qsdk-build/out/kernel-support-1.5.3
	python3 /lab/feed/make_packages_index.py \
		--input "$local_feed" --output "$local_feed/Packages" >/dev/null
	gzip -n -9 -c "$local_feed/Packages" > "$local_feed/Packages.gz"
	if [ "$feed_policy" = embedded ]; then
		# Keep the running WLAN firmware in the image, but ship its duplicate
		# reinstall archive only in the complete external release repository.
		# The full preinstalled proxy suite and its local reinstall source then
		# fit the unchanged partition. Index only the IPKs actually embedded.
		embedded_inputs=$(mktemp -d /work/embedded-feed.XXXXXX)
		for ipk in "$local_feed"/*.ipk; do
			case "${ipk##*/}" in sbe-wififw_*.ipk) continue ;; esac
			cp -p "$ipk" "$embedded_inputs/"
		done
		sh /lab/feed/build-feed.sh --input "$embedded_inputs" \
			--output "$root/usr/share/sbe-feed"
		sh /lab/feed/verify-feed.sh --feed "$root/usr/share/sbe-feed"
	fi
fi
# Run native offline maintainer hooks only after all target dependencies are
# present, inside the target filesystem. IPKG_INSTROOT remains nonempty so
# OpenWrt enables rc links but does not start services or run first-boot UCI
# defaults. This also lets unmodified upstream scripts source /lib correctly
# instead of accidentally looking for target helpers on the build host.
if [ "$component_profile" = production ]; then
	tail -n +2 "$local_feed/Native-Packages.tsv" | \
		while IFS="$(printf '\t')" read -r package rest; do
			postinst=/usr/lib/opkg/info/$package.postinst
			[ -x "$root$postinst" ] || continue
			chroot "$root" /usr/bin/env IPKG_INSTROOT=/ IPKG_NO_SCRIPT=0 \
				/bin/sh "$postinst"
		done
	[ "$created_null" != yes ] || rm -f "$root/dev/null"
fi
# The factory opkg scans every installed package's ownership file before a
# local install.  Some immutable QSDK packages have no recoverable package
# manifest; give those records an explicit empty list so normal opkg operations
# do not emit one warning for every factory package.
awk '$1 == "Package:" { print $2 }' "$opkg_status" | LC_ALL=C sort -u | \
	while IFS= read -r installed_package; do
		[ -n "$installed_package" ] || continue
		[ -e "$opkg_info/$installed_package.list" ] || : > "$opkg_info/$installed_package.list"
	done
if [ "$component_profile" = production ]; then
	/lab/tests/test_userland_services_rootfs.sh "$root" /lab
fi
python3 /lab/tools/audit_elf_abi.py \
	--stock-root /work/rootfs \
	--overlay-root "$luci_overlay"
python3 /lab/tools/audit_elf_abi.py \
	--stock-root /work/rootfs \
	--overlay-root "$component_overlay"
python3 /lab/tools/audit_image_hygiene.py "$root"

final_overlay_elfs=/work/final-overlay-elfs.list
find "$luci_overlay" "$component_overlay" -type f > "$final_overlay_elfs"
pppd_254_plugin_tested=false
while IFS= read -r file; do
	file "$file" | grep -q 'ELF 64-bit.*ARM aarch64' || continue
	case "$file" in
		"$luci_overlay"/*) relative=${file#"$luci_overlay"} ;;
		"$component_overlay"/*) relative=${file#"$component_overlay"} ;;
		*) printf 'unexpected ELF audit path: %s\n' "$file" >&2; exit 1 ;;
	esac
	# The package overlay is an assembly input, not the final filesystem.
	# A component profile may delete or replace one of its ELF files (notably
	# the legacy pppd 2.4.7 plugin).  Runtime-test only the exact bytes that are
	# still selected in the final rootfs; the component overlay separately
	# supplies and tests every promoted replacement.
	final_file=$root$relative
	[ -f "$final_file" ] && [ ! -L "$final_file" ] || continue
	cmp -s "$file" "$final_file" || continue
	case "$relative" in
		/usr/lib/pppd/*/*.so)
			# pppd plugins deliberately import symbols from the pppd executable.
			# Preload the exact plugin while musl relocates pppd as the main
			# program.  This supplies and resolves the real exported host-symbol
			# ABI without running pppd, touching /dev/ppp, or depending on the
			# build container's kernel modules.  A missing dependency or strong
			# host symbol makes the loader fail before it can print the listing.
			chroot "$root" /usr/bin/env LD_PRELOAD="$relative" \
				/lib/ld-musl-aarch64.so.1 --list /usr/sbin/pppd >/dev/null
			[ "$relative" != /usr/lib/pppd/2.5.4/rp-pppoe.so ] || \
				pppd_254_plugin_tested=true
			continue
			;;
	esac
	# rpcd and Lua modules resolve part of their ABI from their host process.
	# Preload the same stock libraries those hosts load before checking modules.
	chroot "$root" /usr/bin/env \
		LD_PRELOAD=/lib/libblobmsg_json.so:/usr/lib/liblua.so.5.1.5 \
		/lib/ld-musl-aarch64.so.1 --list "$relative" >/dev/null
done < "$final_overlay_elfs"
if [ "$component_profile" = production ] && \
	[ "$pppd_254_plugin_tested" != true ]; then
	printf 'canonical pppd 2.5.4 rp-pppoe plugin was not runtime-tested\n' >&2
	exit 1
fi

# Generate this only after the component profile and every package status/list
# mutation is complete. This is build provenance for later diagnostics; normal
# opkg and the LuCI package page never consult it when deciding an operation.
base_attestation="$root/usr/share/sbe-opkg/base-attestation"
python3 /lab/feed/base_attestation.py create \
	--root "$root" \
	--profile "$component_profile" \
	--profile-file "$component_profile_path" \
	--output "$base_attestation"
python3 /lab/feed/base_attestation.py verify \
	--root "$root" \
	--attestation "$base_attestation"

# Bind the immutable runtime to the exact repository revision that assembled
# it.  Artifact hashes stay in the external manifest to avoid a hash cycle.
install -d -m 0755 "$root/usr/share/sbe-build"
luci_patchset_revision=$(sed -n 's/^PATCHSET_REVISION=//p' /lab/luci-maintenance/sources.lock)
{
	printf 'format=sbe1v1k-source-identity-v1\n'
	printf 'source_git_commit=%s\n' "$source_commit"
	printf 'source_tree_dirty=%s\n' "$source_dirty"
	printf 'source_diff_sha256=%s\n' "$source_diff_sha256"
	printf 'component_profile=%s\n' "$component_profile"
	printf 'luci_patchset_revision=%s\n' "$luci_patchset_revision"
} > "$root/usr/share/sbe-build/source-identity"
chmod 0644 "$root/usr/share/sbe-build/source-identity"

filesystem_image=/work/rootfs.squashfs
rm -f "$filesystem_image" "$output_image"
mksquashfs "$root" "$filesystem_image" \
	-comp xz \
	-b 262144 \
	-mkfs-time "$ROOTFS_SOURCE_DATE_EPOCH" \
	-all-time "$ROOTFS_SOURCE_DATE_EPOCH" \
	-no-xattrs \
	-no-tailends \
	-all-root \
	-noappend >/dev/null

partition_size=$(stat -c %s "$stock_image")
filesystem_size=$(stat -c %s "$filesystem_image")
[ "$filesystem_size" -le "$partition_size" ] || {
	printf 'new SquashFS (%s bytes) exceeds partition (%s bytes)\n' \
		"$filesystem_size" "$partition_size" >&2
	exit 1
}

case "$output_image" in
	*.img) squashfs_output=${output_image%.img}.root.squashfs ;;
	*) squashfs_output=$output_image.root.squashfs ;;
esac

cp "$filesystem_image" "$squashfs_output"
cp "$filesystem_image" "$output_image"
truncate -s "$partition_size" "$output_image"

unsquashfs -s "$output_image" >/dev/null
legacy_seed_package_count=$(($(wc -l < "$manifest") - 1))
profile_counts=$(python3 -c \
	'import json, sys; report = json.load(open(sys.argv[1], encoding="utf-8")); print(len(report["packages"]), len(report["artifacts"]))' \
	"$component_report")
canonical_package_count=${profile_counts%% *}
canonical_artifact_count=${profile_counts#* }
{
	printf 'stock_image_sha256=%s\n' "$stock_sha256"
	printf 'source_baseline_sha256=%s\n' "$(sha256sum "$baseline_path" | awk '{print $1}')"
	printf 'stock_ustream_ssl_sha256=%s\n' "$stock_ustream_sha256"
	printf 'output_image_sha256=%s\n' "$(sha256sum "$output_image" | awk '{print $1}')"
	# Keep the attestation independent of the caller-selected output filename so
	# two byte-identical builds also produce byte-identical manifests.
	printf 'squashfs_artifact_role=%s\n' 'unpadded-rootfs'
	printf 'squashfs_sha256=%s\n' "$(sha256sum "$squashfs_output" | awk '{print $1}')"
	printf 'partition_size=%s\n' "$partition_size"
	printf 'squashfs_size=%s\n' "$filesystem_size"
	printf 'rootfs_data_label=%s\n' "$rootfs_data_label"
	printf 'feed_policy=%s\n' "$feed_policy"
	printf 'package_profile=%s\n' "$package_profile"
	printf 'mount_policy=%s\n' "$mount_policy"
	printf 'component_profile=%s\n' "$component_profile"
	printf 'source_git_commit=%s\n' "$source_commit"
	printf 'source_tree_dirty=%s\n' "$source_dirty"
	printf 'source_diff_sha256=%s\n' "$source_diff_sha256"
	printf 'source_identity_sha256=%s\n' \
		"$(sha256sum "$root/usr/share/sbe-build/source-identity" | awk '{print $1}')"
	printf 'component_profile_sha256=%s\n' \
		"$(sha256sum "$component_profile_path" | awk '{print $1}')"
	printf 'component_profile_report_sha256=%s\n' \
		"$(sha256sum "$component_report" | awk '{print $1}')"
	printf 'board_dhcp_config_sha256=%s\n' \
		"$(sha256sum "$root/etc/config/dhcp" | awk '{print $1}')"
	printf 'component_profile_applicator_sha256=%s\n' \
		"$(sha256sum /lab/tools/apply_component_profile.py | awk '{print $1}')"
	printf 'luci_component_finalizer_sha256=%s\n' \
		"$(sha256sum /lab/tools/finalize_component_luci.py | awk '{print $1}')"
	printf 'luci_finalization_lock_sha256=%s\n' \
		"$(sha256sum /lab/security/luci-finalization.lock.tsv | awk '{print $1}')"
	printf 'ubus_atomic_promotion_lock_sha256=%s\n' \
		"$(sha256sum /lab/ubus-security-build/atomic-promotion.lock.tsv | awk '{print $1}')"
	printf 'ubus_patch_provenance_lock_sha256=%s\n' \
		"$(sha256sum /lab/ubus-security-build/patch-provenance.lock.tsv | awk '{print $1}')"
	if [ -f "$luci_finalization_report" ]; then
		printf 'luci_finalization_report_sha256=%s\n' \
			"$(sha256sum "$luci_finalization_report" | awk '{print $1}')"
	else
		printf 'luci_finalization_report_sha256=%s\n' 'not-applicable'
	fi
	printf 'root_login=%s\n' 'blank-password-lan-only'
	printf 'embedded_authorized_keys=%s\n' 'none'
	# Backward-compatible alias: this counts only the legacy OpenWrt seed
	# manifest, not the profile's final canonical package namespace.
	printf 'openwrt_package_count=%s\n' "$legacy_seed_package_count"
	printf 'legacy_seed_package_count=%s\n' "$legacy_seed_package_count"
	printf 'canonical_package_count=%s\n' "$canonical_package_count"
	printf 'canonical_artifact_count=%s\n' "$canonical_artifact_count"
	printf 'package_manifest_sha256=%s\n' \
		"$(sha256sum "$manifest" | awk '{print $1}')"
	printf 'rootfs_patcher_sha256=%s\n' \
		"$(sha256sum /lab/tools/patch_stock_rootfs.py | awk '{print $1}')"
	printf 'rootfs_assembler_sha256=%s\n' \
		"$(sha256sum /lab/docker/assemble-rootfs.sh | awk '{print $1}')"
	printf 'native_feed_inputs_sha256=%s\n' \
		"$(sha256sum /lab/feed/native-feed-inputs.tsv | awk '{print $1}')"
	printf 'stock_package_files_sha256=%s\n' \
		"$(sha256sum /lab/stock-package-files.json | awk '{print $1}')"
	printf 'stock_package_populator_sha256=%s\n' \
		"$(sha256sum /lab/tools/populate_stock_package_files.py | awk '{print $1}')"
	printf 'native_feed_packages_sha256=%s\n' \
		"$(sha256sum "$local_feed/Native-Packages.tsv" | awk '{print $1}')"
	printf 'hygiene_policy_sha256=%s\n' \
		"$(sha256sum /lab/tools/audit_image_hygiene.py | awk '{print $1}')"
	printf 'feed_base_attestation_sha256=%s\n' \
		"$(sha256sum "$base_attestation" | awk '{print $1}')"
	printf 'feed_base_attestation_generator_sha256=%s\n' \
		"$(sha256sum /lab/feed/base_attestation.py | awk '{print $1}')"
} > "$output_image.manifest"

if [ "$feed_policy" = external ] || [ -n "${SBE_DERIVED_SOURCE_PATH:-}" ]; then
	feed_output=$(dirname "$output_image")/compatible-feed-inputs
	install -d -m 0755 "$feed_output"
	cp -p "$local_feed"/*.ipk "$local_feed/Packages" "$local_feed/Packages.gz" \
		"$local_feed/Native-Packages.tsv" "$feed_output/"
fi

printf 'built %s (%s-byte SquashFS in %s-byte partition image)\n' \
	"$output_image" "$filesystem_size" "$partition_size"
printf 'built unpadded SquashFS %s\n' "$squashfs_output"
