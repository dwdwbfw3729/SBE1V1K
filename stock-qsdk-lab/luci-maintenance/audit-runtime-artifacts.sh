#!/bin/bash

set -euo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$HERE/common.sh"
. "$HERE/sources.lock"

ARTIFACT_DIR=${1:-$HERE/runtime-candidate-out/release}
AUDIT_DIR=${2:-$HERE/runtime-candidate-out/audit}
BASELINE_DIR=${3:-/baseline-ipk}
QSDK=${QSDK_DIR:-/qsdk}
PACKAGES_LOCK=$HERE/runtime-packages.lock.tsv
ELF_PATHS_LOCK=$HERE/runtime-elf-paths.lock.tsv
BASELINE_LOCK=$HERE/runtime-baseline-ipks.lock
WEAK_ALLOWLIST=$HERE/runtime-weak-symbol-allowlist.tsv
REQUIRED_ALLOWLIST=$HERE/runtime-required-symbol-allowlist.tsv
PROVIDER_ABI_LOCK=$HERE/runtime-provider-abi.lock.tsv
PROMOTION_LOCK=$HERE/runtime-promotion.lock.tsv
TOOLCHAIN_BIN=$QSDK/staging_dir/toolchain-aarch64_cortex-a73+neon-vfpv4_gcc-7.5.0_musl/bin
READELF=$TOOLCHAIN_BIN/aarch64-openwrt-linux-musl-readelf

[ -d "$ARTIFACT_DIR" ] || fail "runtime artifact directory is missing: $ARTIFACT_DIR"
[ -d "$BASELINE_DIR" ] || fail "runtime baseline directory is missing: $BASELINE_DIR"
[ -x "$READELF" ] || fail "locked cross readelf is missing: $READELF"
[ -x "$HERE/elf-dynsym.py" ] || fail 'sectionless ELF symbol parser is not executable'
rm -rf "$AUDIT_DIR/controls" "$AUDIT_DIR/dynsym"
mkdir -p "$AUDIT_DIR/controls" "$AUDIT_DIR/dynsym"

tmp=$(mktemp -d /tmp/sbe-luci-runtime-audit.XXXXXX)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

actual_count=$(find "$ARTIFACT_DIR" -maxdepth 1 -type f -name '*.ipk' | wc -l | tr -d ' ')
[ "$actual_count" = 6 ] || fail "expected exactly 6 runtime release IPKs, got $actual_count"

printf 'package\tversion\tarchitecture\tsource\tsource_name\tdepends\tprovides\tfilename\tsha256\n' > "$AUDIT_DIR/packages.tsv"
printf 'package\tbaseline_filename\tbaseline_sha256\tidentity_dependencies\tversion_transition\n' > "$AUDIT_DIR/baseline-packages.tsv"
printf 'package\ttype\tmode\tpath\tsha256_or_target\n' > "$AUDIT_DIR/payload-files.tsv"
printf 'package\tpath\trole\tsoname\tneeded\tdefined_symbols_sha256\tundefined_symbols_sha256\tbaseline_abi\thardening\n' > "$AUDIT_DIR/elf-abi.tsv"
printf 'package\tpath\tdirection\tsymbol\treason\tresult\n' > "$AUDIT_DIR/weak-symbol-delta.tsv"
printf 'package\tpath\tdirection\tsymbol\tprovider_path\treason\tresult\n' > "$AUDIT_DIR/required-symbol-delta.tsv"
printf 'provider_path\tsoname\tmachine\tdefined_symbols_sha256\tresult\n' > "$AUDIT_DIR/provider-abi.tsv"
printf 'package\tbackend\tnew\tbaseline\tresult\n' > "$AUDIT_DIR/iwinfo-backends.tsv"

while IFS=$'\t' read -r expected filename; do
	case "${expected:-}" in ''|'#'*) continue ;; esac
	[ -f "$BASELINE_DIR/$filename" ] || fail "baseline IPK is missing: $filename"
	[ "$(sha256_file "$BASELINE_DIR/$filename")" = "$expected" ] ||
		fail "baseline IPK hash changed: $filename"
done < "$BASELINE_LOCK"

while IFS=$'\t' read -r provider_path expected_soname expected_machine expected_symbols; do
	case "${provider_path:-}" in ''|'#'*) continue ;; esac
	provider=$QSDK/$provider_path
	[ -f "$provider" ] || fail "locked runtime ABI provider is missing: $provider_path"
	provider_soname=$($READELF -d "$provider" | sed -n 's/.*(SONAME).*\[\(.*\)\]/\1/p')
	provider_soname=${provider_soname:--}
	provider_machine=$($READELF -h "$provider" | sed -n 's/^ *Machine: *//p')
	python3 "$HERE/elf-dynsym.py" --kind defined "$provider" > "$tmp/provider-defined.tsv"
	provider_symbols=$(sha256_file "$tmp/provider-defined.tsv")
	[ "$provider_soname" = "$expected_soname" ] || fail "provider SONAME changed: $provider_path"
	[ "$provider_machine" = "$expected_machine" ] || fail "provider machine changed: $provider_path"
	[ "$provider_symbols" = "$expected_symbols" ] || fail "provider symbol ABI changed: $provider_path"
	printf '%s\t%s\t%s\t%s\tmatch\n' "$provider_path" "$provider_soname" \
		"$provider_machine" "$provider_symbols" >> "$AUDIT_DIR/provider-abi.tsv"
done < "$PROVIDER_ABI_LOCK"

safe_member_list() {
	local archive=$1 member
	while IFS= read -r member; do
		case "$member" in
			/*|../*|*/../*|*/..) fail "unsafe archive member in $archive: $member" ;;
		esac
	done < <(tar -tzf "$archive")
}

extract_ipk() {
	local ipk=$1 destination=$2 label=$3
	local control_tar=$tmp/$label.control.tar.gz
	local data_tar=$tmp/$label.data.tar.gz
	mkdir -p "$destination/control" "$destination/payload"
	total_control=$(tar -tzf "$ipk" | awk '$0 == "./control.tar.gz" || $0 == "control.tar.gz" { count++ } END { print count+0 }')
	total_data=$(tar -tzf "$ipk" | awk '$0 == "./data.tar.gz" || $0 == "data.tar.gz" { count++ } END { print count+0 }')
	[ "$total_control" = 1 ] && [ "$total_data" = 1 ] ||
		fail "$label does not contain exactly one control.tar.gz and data.tar.gz"
	tar -xOzf "$ipk" ./control.tar.gz > "$control_tar" 2>/dev/null ||
		tar -xOzf "$ipk" control.tar.gz > "$control_tar"
	tar -xOzf "$ipk" ./data.tar.gz > "$data_tar" 2>/dev/null ||
		tar -xOzf "$ipk" data.tar.gz > "$data_tar"
	safe_member_list "$control_tar"
	safe_member_list "$data_tar"
	tar -xzf "$control_tar" -C "$destination/control"
	tar -xzf "$data_tar" -C "$destination/payload"
}

control_field() {
	local control=$1 name=$2
	sed -n "s/^$name: //p" "$control"
}

payload_shape() {
	local root=$1 path mode kind
	while IFS= read -r path; do
		mode=$(stat -c '%a' "$path")
		if [ -L "$path" ]; then kind=symlink; else kind=file; fi
		printf '%s\t%s\t%s\n' "$kind" "$mode" "/${path#"$root/"}"
	done < <(find "$root" \( -type f -o -type l \) | LC_ALL=C sort)
}

declare -A seen_files seen_elf_paths seen_weak_allowlist seen_required_allowlist seen_promotion
elf_count=0
while IFS=$'\t' read -r _target _config package expected_version expected_arch expected_source expected_source_name baseline_filename expected_baseline_version; do
	case "${_target:-}" in ''|'#'*) continue ;; esac
	mapfile -t matches < <(find "$ARTIFACT_DIR" -maxdepth 1 -type f \
		-name "${package}_*.ipk" -print | LC_ALL=C sort)
	[ "${#matches[@]}" = 1 ] ||
		fail "expected one runtime release IPK for $package, got ${#matches[@]}"
	ipk=${matches[0]}
	filename=$(basename "$ipk")
	[ -z "${seen_files[$filename]:-}" ] || fail "duplicate runtime artifact filename: $filename"
	seen_files[$filename]=1
	baseline=$BASELINE_DIR/$baseline_filename
	[ -f "$baseline" ] || fail "$package baseline reference is missing: $baseline_filename"

	new_dir=$tmp/$package.new
	old_dir=$tmp/$package.old
	extract_ipk "$ipk" "$new_dir" "$package.new"
	extract_ipk "$baseline" "$old_dir" "$package.old"
	control=$new_dir/control/control
	old_control=$old_dir/control/control
	[ -f "$control" ] && [ -f "$old_control" ] || fail "$package control metadata is missing"
	cp "$control" "$AUDIT_DIR/controls/$package.control"

	actual_package=$(control_field "$control" Package)
	actual_version=$(control_field "$control" Version)
	actual_arch=$(control_field "$control" Architecture)
	actual_source=$(control_field "$control" Source)
	actual_source_name=$(control_field "$control" SourceName)
	depends=$(control_field "$control" Depends)
	provides=$(control_field "$control" Provides)
	old_package=$(control_field "$old_control" Package)
	old_version=$(control_field "$old_control" Version)
	old_arch=$(control_field "$old_control" Architecture)
	old_depends=$(control_field "$old_control" Depends)
	old_provides=$(control_field "$old_control" Provides)

	[ "$actual_package" = "$package" ] || fail "$filename has package identity $actual_package"
	[ "$actual_version" = "$expected_version" ] || fail "$package version is $actual_version"
	[ "$actual_arch" = "$expected_arch" ] || fail "$package architecture is $actual_arch"
	[ "$actual_source" = "$expected_source" ] || fail "$package source is $actual_source"
	[ "$actual_source_name" = "$expected_source_name" ] ||
		fail "$package has unexpected SourceName $actual_source_name"
	[ "$old_package" = "$package" ] || fail "$baseline_filename has package identity $old_package"
	[ "$old_version" = "$expected_baseline_version" ] ||
		fail "$package baseline version is $old_version, expected $expected_baseline_version"
	[ "$old_arch" = aarch64_generic ] || fail "$package baseline architecture is $old_arch"
	[ "$old_depends" = "$depends" ] ||
		fail "$package dependencies differ from final-rootfs baseline: $depends"
	[ "$old_provides" = "$provides" ] ||
		fail "$package Provides differs from final-rootfs baseline: $provides"
	promotion=$(awk -F '\t' -v package="$package" \
		'$1 !~ /^#/ && $1 == package { print $2 "\t" $3 "\t" $4 "\t" $5 }' \
		"$PROMOTION_LOCK")
	[ -n "$promotion" ] || fail "$package has no promotion lock"
	[ "$(printf '%s\n' "$promotion" | wc -l | tr -d ' ')" = 1 ] ||
		fail "$package has duplicate promotion locks"
	IFS=$'\t' read -r promotion_version promotion_arch promotion_filename promotion_sha <<< "$promotion"
	[ "$promotion_version" = "$actual_version" ] || fail "$package promotion version differs"
	[ "$promotion_arch" = "$actual_arch" ] || fail "$package promotion architecture differs"
	[ "$promotion_filename" = "$filename" ] || fail "$package promotion filename differs"
	artifact_sha=$(sha256_file "$ipk")
	[ "$promotion_sha" = "$artifact_sha" ] || fail "$package promotion SHA-256 differs"
	seen_promotion[$package]=1
	case ",$depends," in
		*,kmod-*|*,\ kmod-*|*kernel*) fail "$package gained a kernel dependency: $depends" ;;
	esac
	printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
		"$package" "$actual_version" "$actual_arch" "$actual_source" "$actual_source_name" \
		"$depends" "$provides" "$filename" "$artifact_sha" >> "$AUDIT_DIR/packages.tsv"
	printf '%s\t%s\t%s\tmatch\t%s-to-%s-locked\n' "$package" "$baseline_filename" \
		"$(sha256_file "$baseline")" "$old_version" "$actual_version" >> "$AUDIT_DIR/baseline-packages.tsv"

	new_payload=$new_dir/payload
	old_payload=$old_dir/payload
	if find "$new_payload" -mindepth 1 ! -type d ! -type f ! -type l -print -quit | grep -q .; then
		fail "$package contains a device, FIFO, or socket"
	fi
	payload_shape "$new_payload" > "$tmp/$package.new-shape"
	payload_shape "$old_payload" > "$tmp/$package.old-shape"
	cmp "$tmp/$package.new-shape" "$tmp/$package.old-shape" ||
		fail "$package payload paths, types, or modes differ from final-rootfs baseline"

	if grep -R -a -E -q \
		'/Users/yangzhg|/private/(tmp|var)/|BEGIN [A-Z ]*PRIVATE KEY|OpenSync|opensync|OVSDB|ovsdb|CUJO|cujo|SSHM|sshm' \
		"$new_payload" "$new_dir/control"; then
		fail "$package leaks a host path, key, or operator-control marker"
	fi

	while IFS= read -r path; do
		rel=/${path#"$new_payload/"}
		old_path=$old_payload/${path#"$new_payload/"}
		mode=$(stat -c '%a' "$path")
		if (( (8#$mode & 06000) != 0 )); then
			fail "$package $rel has a setuid/setgid mode: $mode"
		fi
		if [ -L "$path" ]; then
			target=$(readlink "$path")
			case "$target" in /*|../*|*/../*|*/..) fail "$package has unsafe symlink: $target" ;; esac
			[ "$(readlink "$old_path")" = "$target" ] || fail "$package $rel symlink target changed"
			printf '%s\tsymlink\t%s\t%s\t%s\n' \
				"$package" "$mode" "$rel" "$target" >> "$AUDIT_DIR/payload-files.tsv"
			continue
		fi
		printf '%s\tfile\t%s\t%s\t%s\n' \
			"$package" "$mode" "$rel" "$(sha256_file "$path")" >> "$AUDIT_DIR/payload-files.tsv"
		if file "$path" | grep -q 'ELF '; then
			elf_count=$((elf_count + 1))
			role=$(awk -F '\t' -v package="$package" -v path="$rel" \
				'$1 !~ /^#/ && $1 == package && $2 == path { print $3 }' "$ELF_PATHS_LOCK")
			[ -n "$role" ] || fail "$package has an unlisted ELF payload: $rel"
			[ "$(printf '%s\n' "$role" | wc -l | tr -d ' ')" = 1 ] ||
				fail "$package $rel has duplicate ELF path locks"
			seen_elf_paths[$package:$rel]=1

			header=$($READELF -h "$path")
			elf_class=$(printf '%s\n' "$header" | sed -n 's/^ *Class: *//p')
			machine=$(printf '%s\n' "$header" | sed -n 's/^ *Machine: *//p')
			[ "$elf_class" = ELF64 ] || fail "$package $rel is not ELF64"
			[ "$machine" = AArch64 ] || fail "$package $rel is not AArch64"
			dynamic=$($READELF -d "$path")
			old_dynamic=$($READELF -d "$old_path")
			program=$($READELF -W -l "$path")
			old_program=$($READELF -W -l "$old_path")
			soname=$(printf '%s\n' "$dynamic" | sed -n 's/.*(SONAME).*\[\(.*\)\]/\1/p')
			old_soname=$(printf '%s\n' "$old_dynamic" | sed -n 's/.*(SONAME).*\[\(.*\)\]/\1/p')
			soname=${soname:--}
			old_soname=${old_soname:--}
			[ "$soname" = "$old_soname" ] || fail "$package $rel SONAME changed"
			needed=$(printf '%s\n' "$dynamic" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p' |
				LC_ALL=C sort | paste -sd, -)
			old_needed=$(printf '%s\n' "$old_dynamic" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p' |
				LC_ALL=C sort | paste -sd, -)
			needed=${needed:--}
			old_needed=${old_needed:--}
			[ "$needed" = "$old_needed" ] ||
				fail "$package $rel dynamic dependencies changed: $needed"

			new_defined=$AUDIT_DIR/dynsym/$package.defined.tsv
			new_undefined=$AUDIT_DIR/dynsym/$package.undefined.tsv
			old_defined=$tmp/$package.old-defined.tsv
			old_undefined=$tmp/$package.old-undefined.tsv
			python3 "$HERE/elf-dynsym.py" --kind defined "$path" > "$new_defined"
			python3 "$HERE/elf-dynsym.py" --kind undefined "$path" > "$new_undefined"
			python3 "$HERE/elf-dynsym.py" --kind defined "$old_path" > "$old_defined"
			python3 "$HERE/elf-dynsym.py" --kind undefined "$old_path" > "$old_undefined"
			cmp "$new_defined" "$old_defined" ||
				fail "$package $rel exported dynamic symbol ABI differs from baseline"
			awk -F '\t' '$2 != "WEAK"' "$new_undefined" > "$tmp/$package.new-required.tsv"
			awk -F '\t' '$2 != "WEAK"' "$old_undefined" > "$tmp/$package.old-required.tsv"
			for direction in added removed; do
				if [ "$direction" = added ]; then
					comm -13 "$tmp/$package.old-required.tsv" "$tmp/$package.new-required.tsv" > "$tmp/$package.required-delta.tsv"
				else
					comm -23 "$tmp/$package.old-required.tsv" "$tmp/$package.new-required.tsv" > "$tmp/$package.required-delta.tsv"
				fi
				while IFS=$'\t' read -r _kind _binding _type _visibility symbol; do
					[ -n "${symbol:-}" ] || continue
					allow=$(awk -F '\t' -v package="$package" -v path="$rel" \
						-v direction="$direction" -v symbol="$symbol" \
						'$1 !~ /^#/ && $1 == package && $2 == path && $3 == direction && $4 == symbol { print $5 "\t" $6 }' \
						"$REQUIRED_ALLOWLIST")
					[ -n "$allow" ] ||
						fail "$package $rel has an unreviewed $direction required import: $symbol"
					provider_path=${allow%%$'\t'*}
					reason=${allow#*$'\t'}
					if [ "$direction" = added ]; then
						[ -f "$QSDK/$provider_path" ] || fail "allowlisted provider is missing: $provider_path"
						python3 "$HERE/elf-dynsym.py" --kind defined "$QSDK/$provider_path" |
							awk -F '\t' -v symbol="$symbol" '$5 == symbol { found=1 } END { exit !found }' ||
							fail "$provider_path does not export required symbol $symbol"
					fi
					key=$package:$rel:$direction:$symbol
					seen_required_allowlist[$key]=1
					printf '%s\t%s\t%s\t%s\t%s\t%s\tallowlisted-provider-verified\n' \
						"$package" "$rel" "$direction" "$symbol" "$provider_path" "$reason" >> "$AUDIT_DIR/required-symbol-delta.tsv"
				done < "$tmp/$package.required-delta.tsv"
			done
			awk -F '\t' '$2 == "WEAK"' "$new_undefined" > "$tmp/$package.new-weak.tsv"
			awk -F '\t' '$2 == "WEAK"' "$old_undefined" > "$tmp/$package.old-weak.tsv"
			for direction in added removed; do
				if [ "$direction" = added ]; then
					comm -13 "$tmp/$package.old-weak.tsv" "$tmp/$package.new-weak.tsv" > "$tmp/$package.weak-delta.tsv"
				else
					comm -23 "$tmp/$package.old-weak.tsv" "$tmp/$package.new-weak.tsv" > "$tmp/$package.weak-delta.tsv"
				fi
				while IFS=$'\t' read -r _kind _binding _type _visibility symbol; do
					[ -n "${symbol:-}" ] || continue
					reason=$(awk -F '\t' -v package="$package" -v path="$rel" \
						-v direction="$direction" -v symbol="$symbol" \
						'$1 !~ /^#/ && $1 == package && $2 == path && $3 == direction && $4 == symbol { print $5 }' \
						"$WEAK_ALLOWLIST")
					[ -n "$reason" ] ||
						fail "$package $rel has an unreviewed $direction weak import: $symbol"
					key=$package:$rel:$direction:$symbol
					seen_weak_allowlist[$key]=1
					printf '%s\t%s\t%s\t%s\t%s\tallowlisted\n' \
						"$package" "$rel" "$direction" "$symbol" "$reason" >> "$AUDIT_DIR/weak-symbol-delta.tsv"
				done < "$tmp/$package.weak-delta.tsv"
			done

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
			new_interp=$(printf '%s\n' "$program" | sed -n 's/.*Requesting program interpreter: \([^]]*\).*/\1/p')
			old_interp=$(printf '%s\n' "$old_program" | sed -n 's/.*Requesting program interpreter: \([^]]*\).*/\1/p')
			[ "$new_interp" = "$old_interp" ] || fail "$package $rel program interpreter changed"
			printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\tcompatible-reviewed-deltas\tRELRO+NOW+NX\n' \
				"$package" "$rel" "$role" "$soname" "$needed" \
				"$(sha256_file "$new_defined")" "$(sha256_file "$new_undefined")" >> "$AUDIT_DIR/elf-abi.tsv"
		else
			cmp "$path" "$old_path" || fail "$package non-ELF payload changed: $rel"
		fi
	done < <(find "$new_payload" \( -type f -o -type l \) | LC_ALL=C sort)
done < "$PACKAGES_LOCK"

while IFS=$'\t' read -r package _version _arch _filename _sha; do
	case "${package:-}" in ''|'#'*) continue ;; esac
	[ "${seen_promotion[$package]:-}" = 1 ] ||
		fail "promotion lock names an unaudited package: $package"
done < "$PROMOTION_LOCK"

[ "$elf_count" = 6 ] || fail "expected exactly 6 runtime ELF payloads, got $elf_count"
while IFS=$'\t' read -r package path _role; do
	case "${package:-}" in ''|'#'*) continue ;; esac
	[ "${seen_elf_paths[$package:$path]:-}" = 1 ] || fail "locked ELF path was not audited: $package $path"
done < "$ELF_PATHS_LOCK"

while IFS=$'\t' read -r package path direction symbol _reason; do
	case "${package:-}" in ''|'#'*) continue ;; esac
	key=$package:$path:$direction:$symbol
	[ "${seen_weak_allowlist[$key]:-}" = 1 ] ||
		fail "weak-symbol allowlist entry was not exercised: $key"
done < "$WEAK_ALLOWLIST"

while IFS=$'\t' read -r package path direction symbol _provider _reason; do
	case "${package:-}" in ''|'#'*) continue ;; esac
	key=$package:$path:$direction:$symbol
	[ "${seen_required_allowlist[$key]:-}" = 1 ] ||
		fail "required-symbol allowlist entry was not exercised: $key"
done < "$REQUIRED_ALLOWLIST"

iwinfo_new=$tmp/libiwinfo20181126.new/payload/usr/lib/libiwinfo.so
iwinfo_old=$tmp/libiwinfo20181126.old/payload/usr/lib/libiwinfo.so
iwinfo_new_strings=$tmp/libiwinfo20181126.new.strings
iwinfo_old_strings=$tmp/libiwinfo20181126.old.strings
strings "$iwinfo_new" > "$iwinfo_new_strings"
strings "$iwinfo_old" > "$iwinfo_old_strings"
for backend in wext nl80211; do
	new_present=no
	old_present=no
	grep -Fx -q "${backend}_ops" "$iwinfo_new_strings" && new_present=yes
	grep -Fx -q "${backend}_ops" "$iwinfo_old_strings" && old_present=yes
	[ "$new_present" = yes ] && [ "$old_present" = yes ] ||
		fail "required iwinfo backend is missing: $backend"
	printf 'libiwinfo20181126\t%s\t%s\t%s\tmatch\n' \
		"$backend" "$new_present" "$old_present" >> "$AUDIT_DIR/iwinfo-backends.tsv"
done
for backend in wl madwifi; do
	new_present=no
	old_present=no
	grep -Fx -q "${backend}_ops" "$iwinfo_new_strings" && new_present=yes
	grep -Fx -q "${backend}_ops" "$iwinfo_old_strings" && old_present=yes
	[ "$new_present" = "$old_present" ] || fail "iwinfo backend set changed: $backend"
	printf 'libiwinfo20181126\t%s\t%s\t%s\tmatch\n' \
		"$backend" "$new_present" "$old_present" >> "$AUDIT_DIR/iwinfo-backends.tsv"
done

printf 'PASS: audited 6 runtime IPKs; package identity/payload match and reviewed ELF ABI plus iwinfo backends are final-rootfs compatible\n' |
	tee "$AUDIT_DIR/RESULT.txt"
