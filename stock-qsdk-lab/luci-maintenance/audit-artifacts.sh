#!/bin/bash

set -euo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$HERE/common.sh"
. "$HERE/sources.lock"

ARTIFACT_DIR=${1:-$HERE/candidate-out/release}
AUDIT_DIR=${2:-$HERE/candidate-out/audit}
QSDK=${QSDK_DIR:-/qsdk}
READELF=$QSDK/staging_dir/toolchain-aarch64_cortex-a73+neon-vfpv4_gcc-7.5.0_musl/bin/aarch64-openwrt-linux-musl-readelf

[ -d "$ARTIFACT_DIR" ] || fail "artifact directory is missing: $ARTIFACT_DIR"
[ -x "$READELF" ] || fail "locked cross readelf is missing: $READELF"
rm -rf "$AUDIT_DIR"
mkdir -p "$AUDIT_DIR/controls"

tmp=$(mktemp -d /tmp/sbe-luci-audit.XXXXXX)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

actual_count=$(find "$ARTIFACT_DIR" -maxdepth 1 -type f -name '*.ipk' | wc -l | tr -d ' ')
[ "$actual_count" = 20 ] || fail "expected exactly 20 release IPKs, got $actual_count"

printf 'package\tversion\tarchitecture\tsource\tdepends\tfilename\tsha256\n' > "$AUDIT_DIR/packages.tsv"
printf 'package\ttype\tmode\tpath\tsha256_or_target\n' > "$AUDIT_DIR/payload-files.tsv"
printf 'package\tpath\telf_class\tmachine\ttype\tneeded\n' > "$AUDIT_DIR/elf-needed.tsv"
printf 'package\tcontrol_member\tmode\tsha256\n' > "$AUDIT_DIR/control-scripts.tsv"

declare -A seen_files
elf_count=0
while IFS=$'\t' read -r _target package expected_version expected_arch expected_source; do
	case "${_target:-}" in ''|'#'*) continue ;; esac
	mapfile -t matches < <(find "$ARTIFACT_DIR" -maxdepth 1 -type f \
		-name "${package}_*.ipk" -print | LC_ALL=C sort)
	[ "${#matches[@]}" = 1 ] ||
		fail "expected one release IPK for $package, got ${#matches[@]}"
	ipk=${matches[0]}
	filename=$(basename "$ipk")
	[ -z "${seen_files[$filename]:-}" ] || fail "duplicate artifact filename: $filename"
	seen_files[$filename]=1

	control_tar=$tmp/$package.control.tar.gz
	data_tar=$tmp/$package.data.tar.gz
	payload=$tmp/$package.payload
	control_dir=$tmp/$package.control
	mkdir -p "$payload" "$control_dir"
	tar -xOzf "$ipk" ./control.tar.gz > "$control_tar" ||
		fail "cannot read control archive from $filename"
	tar -xOzf "$ipk" ./data.tar.gz > "$data_tar" ||
		fail "cannot read data archive from $filename"
	tar -xzf "$control_tar" -C "$control_dir"
	tar -xzf "$data_tar" -C "$payload"
	if [ "$package" = luci-base ]; then
		luci_js=$payload/www/luci-static/resources/luci.js
		[ -f "$luci_js" ] || fail 'luci-base runtime is missing'
		grep -F -q 'rpcBaseURL=env.ubuspath' "$luci_js" ||
			fail 'luci-base does not select the configured ubus POST endpoint directly'
		if grep -F -q 'Request.get(env.ubuspath)' "$luci_js"; then
			fail 'luci-base still probes the POST-only ubus endpoint with GET'
		fi
	fi
	if [ "$package" = luci-mod-system ]; then
		sshkeys=$payload/www/luci-static/resources/view/system/sshkeys.js
		[ -f "$sshkeys" ] || fail 'luci-mod-system SSH-key view is missing'
		grep -F -q "E('pre',[delkey])" "$sshkeys" ||
			fail 'luci-mod-system lacks the SSH-key stored-XSS backport'
		if grep -F -q "E('pre',delkey)" "$sshkeys"; then
			fail 'luci-mod-system retains the raw-HTML SSH-key delete sink'
		fi
	fi
	if [ "$package" = luci-mod-network ]; then
		diagnostics=$payload/www/luci-static/resources/view/network/diagnostics.js
		grep -F -q "['-4','-c','5','-W','1',addr]:['-6','-c','5',addr]" "$diagnostics" ||
			fail 'diagnostic Ping actions do not select IPv4/IPv6 explicitly'
		grep -F -q "['-4','-q','1','-w','1','-n',addr]" "$diagnostics" ||
			fail 'diagnostic Traceroute action does not select IPv4 explicitly'
		wireless=$payload/www/luci-static/resources/view/network/wireless.js
		[ -f "$wireless" ] || fail 'luci-mod-network wireless view is missing'
		grep -F -q "qca_max_widths" "$wireless" ||
			fail 'luci-mod-network lacks the QCA per-band width contract'
		grep -F -q "band.parentNode.style.display=''" "$wireless" ||
			fail 'luci-mod-network does not keep the detected QCA band visible'
	fi
	if [ "$package" = luci-mod-status ]; then
		for view in bandwidth connections load wireless; do
			graph=$payload/www/luci-static/resources/view/status/$view.js
			[ -f "$graph" ] || fail "luci-mod-status $view view is missing"
			[ "$(grep -F -o 'y=isNaN(y)?ctx.height:y' "$graph" | wc -l | tr -d ' ')" = 1 ] ||
				fail "luci-mod-status $view view lacks the official NaN coordinate guard"
		done
	fi
	if [ "$package" = rpcd-mod-luci ]; then
		rpc_module=$payload/usr/lib/rpcd/luci.so
		[ -f "$rpc_module" ] || fail 'rpcd-mod-luci provider is missing'
		grep -a -F -q 'qca_max_widths' "$rpc_module" ||
			fail 'rpcd-mod-luci lacks the QCA width response field'
		grep -a -F -q '/sys/class/net/%s/%s_maxchwidth' "$rpc_module" ||
			fail 'rpcd-mod-luci lacks the validated QCA sysfs width source'
	fi
	control=$control_dir/control
	[ -f "$control" ] || fail "control metadata is missing in $filename"
	cp "$control" "$AUDIT_DIR/controls/$package.control"

	field() {
		sed -n "s/^$1: //p" "$control"
	}
	actual_package=$(field Package)
	actual_version=$(field Version)
	actual_arch=$(field Architecture)
	actual_source=$(field Source)
	actual_source_name=$(field SourceName)
	depends=$(field Depends)
	[ "$actual_package" = "$package" ] || fail "$filename has package identity $actual_package"
	[ "$actual_version" = "$expected_version" ] || fail "$package version is $actual_version"
	[ "$actual_arch" = "$expected_arch" ] || fail "$package architecture is $actual_arch"
	[ "$actual_source" = "$expected_source" ] || fail "$package source is $actual_source"
	[ "$actual_source_name" = "$package" ] ||
		fail "$package has unexpected SourceName $actual_source_name"
	case ",$depends," in
		*,kmod-*|*,\ kmod-*|*kernel*) fail "$package gained a kernel dependency: $depends" ;;
	esac
	printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
		"$package" "$actual_version" "$actual_arch" "$actual_source" "$depends" \
		"$filename" "$(sha256_file "$ipk")" >> "$AUDIT_DIR/packages.tsv"

	while IFS= read -r member; do
		case "$member" in
			/*|../*|*/../*|*/..) fail "$package has unsafe archive member: $member" ;;
		esac
	done < <(tar -tzf "$data_tar")
	if find "$payload" -mindepth 1 ! -type d ! -type f ! -type l -print -quit | grep -q .; then
		fail "$package contains a device, FIFO, or socket"
	fi
	while IFS= read -r link; do
		target=$(readlink "$link")
		case "$target" in /*|../*|*/../*|*/..) fail "$package has unsafe symlink: $target" ;; esac
	done < <(find "$payload" -type l | LC_ALL=C sort)

	if grep -R -a -E -q \
		'/Users/yangzhg|/private/(tmp|var)/|BEGIN [A-Z ]*PRIVATE KEY|OpenSync|opensync|OVSDB|ovsdb|CUJO|cujo|SSHM|sshm' \
		"$payload" "$control_dir"; then
		fail "$package leaks a host path, key, or operator-control marker"
	fi

	while IFS= read -r path; do
		rel=/${path#"$payload/"}
		mode=$(stat -c '%a' "$path")
		if (( (8#$mode & 06000) != 0 )); then
			fail "$package $rel has a setuid/setgid mode: $mode"
		fi
		if [ -L "$path" ]; then
			printf '%s\tsymlink\t%s\t%s\t%s\n' \
				"$package" "$mode" "$rel" "$(readlink "$path")" >> "$AUDIT_DIR/payload-files.tsv"
			continue
		fi
		printf '%s\tfile\t%s\t%s\t%s\n' \
			"$package" "$mode" "$rel" "$(sha256_file "$path")" >> "$AUDIT_DIR/payload-files.tsv"
		if file "$path" | grep -q 'ELF '; then
			elf_count=$((elf_count + 1))
			header=$($READELF -h "$path")
			elf_class=$(printf '%s\n' "$header" | sed -n 's/^ *Class: *//p')
			machine=$(printf '%s\n' "$header" | sed -n 's/^ *Machine: *//p')
			elf_type=$(printf '%s\n' "$header" | sed -n 's/^ *Type: *\([^ ]*\).*/\1/p')
			[ "$elf_class" = ELF64 ] || fail "$package $rel is not ELF64"
			[ "$machine" = AArch64 ] || fail "$package $rel is not AArch64"
			dynamic=$($READELF -d "$path" 2>/dev/null || true)
			program=$($READELF -W -l "$path")
			if printf '%s\n' "$dynamic" | grep -Eq '\((RPATH|RUNPATH)\)'; then
				fail "$package $rel contains RPATH/RUNPATH"
			fi
			printf '%s\n' "$program" | grep -q 'GNU_RELRO' ||
				fail "$package $rel lacks GNU_RELRO"
			stack_line=$(printf '%s\n' "$program" | grep 'GNU_STACK')
			[ -n "$stack_line" ] || fail "$package $rel lacks GNU_STACK metadata"
			printf '%s\n' "$stack_line" | grep -q 'RWE' &&
				fail "$package $rel requests an executable stack"
			printf '%s\n' "$dynamic" | grep -Eq '\(BIND_NOW\)|FLAGS.*NOW' ||
				fail "$package $rel lacks immediate binding"
			needed=$(printf '%s\n' "$dynamic" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p' |
				LC_ALL=C sort | paste -sd, -)
			printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
				"$package" "$rel" "$elf_class" "$machine" "$elf_type" "$needed" >> "$AUDIT_DIR/elf-needed.tsv"
		fi
	done < <(find "$payload" \( -type f -o -type l \) | LC_ALL=C sort)

	while IFS= read -r script; do
		[ -f "$script" ] || continue
		printf '%s\t%s\t%s\t%s\n' "$package" "$(basename "$script")" \
			"$(stat -c '%a' "$script")" "$(sha256_file "$script")" >> "$AUDIT_DIR/control-scripts.tsv"
	done < <(find "$control_dir" -maxdepth 1 -type f ! -name control | LC_ALL=C sort)
done < "$HERE/packages.lock.tsv"

[ "${#seen_files[@]}" = 20 ] || fail 'release artifact set contains an unlisted IPK'
[ "$elf_count" -ge 6 ] || fail "expected at least six target ELF objects, got $elf_count"

for required in \
	'luci-base:/usr/lib/lua/luci/template/parser.so' \
	'luci-lib-ip:/usr/lib/lua/luci/ip.so' \
	'luci-lib-jsonc:/usr/lib/lua/luci/jsonc.so' \
	'luci-lib-nixio:/usr/lib/lua/nixio.so' \
	'luci-mod-status:/usr/bin/luci-bwc' \
	'rpcd-mod-luci:/usr/lib/rpcd/luci.so'; do
	package=${required%%:*}
	path=${required#*:}
	grep -F -q "$package"$'\t'"$path"$'\t' "$AUDIT_DIR/elf-needed.tsv" ||
		fail "required ELF is missing from the audit: $required"
done

sort_tsv_body() {
	local input=$1 sorted=$tmp/sorted.tsv
	sed -n '1p' "$input" > "$sorted"
	sed '1d' "$input" | LC_ALL=C sort >> "$sorted"
	mv "$sorted" "$input"
}
sort_tsv_body "$AUDIT_DIR/packages.tsv"
sort_tsv_body "$AUDIT_DIR/payload-files.tsv"
sort_tsv_body "$AUDIT_DIR/elf-needed.tsv"
sort_tsv_body "$AUDIT_DIR/control-scripts.tsv"
printf 'PASS: 20 LuCI IPKs match source, version, architecture and payload policy\n' > "$AUDIT_DIR/RESULT.txt"
printf 'PASS: audited 20 LuCI IPKs and %s target ELF objects\n' "$elf_count"
