#!/bin/sh
set -eu

build_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$build_dir/../.." && pwd)
workspace_parent=$(CDPATH= cd -- "$repo_root/.." && pwd)
. "$build_dir/sources.lock"

source_root=${1:-${QSDK_SOURCE_ROOT:-"$repo_root/stock-qsdk-lab/deps/qsdk-spf12.2-locked"}}
qsdk_dir=$source_root/qsdk
jobs=${QSDK_JOBS:-4}
output=${DIAGNOSTICS_MODERN_OUTPUT:-"$build_dir/candidate-out/diagnostics-modern"}

export LC_ALL=C
export TZ=UTC
export SOURCE_DATE_EPOCH

fail() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

sha256_file() {
	sha256sum "$1" | awk '{print $1}'
}

[ "$(uname -s)" = Linux ] || fail 'diagnostics candidates must build inside Linux'
[ -f "$qsdk_dir/Makefile" ] || fail "complete QSDK tree is missing: $qsdk_dir"
[ -f "$qsdk_dir/.config" ] || fail 'released shared QSDK .config is missing'
[ "$(sha256_file "$qsdk_dir/.config")" = "$QSDK_BASE_CONFIG_SHA256" ] ||
	fail 'shared QSDK .config differs from the released lock before build'

"$build_dir/verify-sources.sh"
"$build_dir/verify-stock-abi.sh" "$source_root"
"$build_dir/security-source-gate.py"

mkdir -p "$qsdk_dir/dl" "$output"
copy_distfile() {
	filename=$1
	expected=$2
	source=$build_dir/distfiles/$filename
	target=$qsdk_dir/dl/$filename
	[ -f "$source" ] || fail "locked source archive is missing: $source"
	[ "$(sha256_file "$source")" = "$expected" ] ||
		fail "locked source archive changed: $source"
	if [ -f "$target" ]; then
		[ "$(sha256_file "$target")" = "$expected" ] ||
			fail "QSDK dl contains mismatched $filename"
	else
		cp "$source" "$target"
	fi
}

copy_distfile "$MTR_RELEASE_ARCHIVE" "$MTR_RELEASE_SHA256"
copy_distfile "$HTOP_RELEASE_ARCHIVE" "$HTOP_RELEASE_SHA256"
copy_distfile "$NANO_RELEASE_ARCHIVE" "$NANO_RELEASE_SHA256"

packages='sbe-mtr096-root-cli-candidate
sbe-htop353-candidate
sbe-nano92-daily-candidate'
package_parent=$qsdk_dir/package/sbe-qsdk-lab
mkdir -p "$package_parent"
config_backup=$(mktemp "${TMPDIR:-/tmp}/sbe-diagnostics-config.XXXXXX")
cp "$qsdk_dir/.config" "$config_backup"

cleanup() {
	printf '%s\n' "$packages" | while IFS= read -r package; do
		[ -n "$package" ] || continue
		target=$package_parent/$package
		source=$build_dir/package-overlay/$package
		if [ -L "$target" ] && [ "$(readlink "$target")" = "$source" ]; then
			rm -f "$target"
		fi
	done
	if [ -f "$config_backup" ]; then
		cp "$config_backup" "$qsdk_dir/.config"
		rm -f "$config_backup"
	fi
}
trap cleanup EXIT HUP INT TERM

printf '%s\n' "$packages" | while IFS= read -r package; do
	[ -n "$package" ] || continue
	target=$package_parent/$package
	source=$build_dir/package-overlay/$package
	[ -f "$source/Makefile" ] || fail "candidate overlay is missing: $source"
	if [ -L "$target" ]; then
		[ "$(readlink "$target")" = "$source" ] ||
			fail "$target points somewhere unexpected"
	elif [ -e "$target" ]; then
		fail "refusing to replace existing QSDK package path: $target"
	else
		ln -s "$source" "$target"
	fi
done

# Package-only target profile.  No world, rootfs, image, kernel or device
# target is selected by this workflow.
cat > "$qsdk_dir/.config" <<'EOF'
CONFIG_TARGET_ipq95xx=y
CONFIG_TARGET_ipq95xx_generic=y
CONFIG_TARGET_ipq95xx_generic_Default=y
CONFIG_DEVEL=y
CONFIG_TOOLCHAINOPTS=y
CONFIG_BINUTILS_USE_VERSION_2_31_1=y
CONFIG_GCC_USE_VERSION_7=y
CONFIG_LIBC_USE_MUSL=y
CONFIG_IPV6=y
CONFIG_PKG_CHECK_FORMAT_SECURITY=y
CONFIG_PKG_ASLR_PIE=y
CONFIG_PKG_CC_STACKPROTECTOR_STRONG=y
CONFIG_PKG_FORTIFY_SOURCE_2=y
CONFIG_PKG_RELRO_FULL=y
CONFIG_PACKAGE_sbe-mtr096-root-cli-candidate=m
CONFIG_PACKAGE_sbe-htop353-candidate=m
CONFIG_PACKAGE_sbe-nano92-daily-candidate=m
EOF
make -C "$qsdk_dir" defconfig

minimal_config=$(mktemp "${TMPDIR:-/tmp}/sbe-diagnostics-minimal.XXXXXX")
awk '!/^CONFIG_PACKAGE_kmod-[^=]*=[ym]$/' "$qsdk_dir/.config" > "$minimal_config"
cp "$minimal_config" "$qsdk_dir/.config"
rm -f "$minimal_config"
cp "$qsdk_dir/.config" "$output/CANDIDATE_BUILD_CONFIG"

grep -q '^CONFIG_PACKAGE_libncurses=m$' "$qsdk_dir/.config" ||
	fail 'diagnostics candidates did not select stock libncurses'
for package in sbe-mtr096-root-cli-candidate sbe-htop353-candidate sbe-nano92-daily-candidate
do
	grep -q "^CONFIG_PACKAGE_$package=m$" "$qsdk_dir/.config" ||
		fail "$package is not selected as a module"
	find "$qsdk_dir/bin" -type f -name "${package}_*.ipk" -delete
	find "$output" -maxdepth 1 -type f -name "${package}_*.ipk" -delete
	make -C "$qsdk_dir" "package/$package/clean"
	make -C "$qsdk_dir" -j"$jobs" "package/$package/compile" V=s
done

copy_candidate() {
	package=$1
	expected_source=$2
	artifact=$(find "$qsdk_dir/bin" -type f -name "${package}_*.ipk" -print |
		LC_ALL=C sort | tail -n 1)
	[ -n "$artifact" ] || fail "build completed without $package IPK"
	cp "$artifact" "$output/"
	artifact=$output/$(basename "$artifact")
	control=$(tar -xOzf "$artifact" ./control.tar.gz | tar -xOzf - ./control) ||
		fail "cannot read control metadata from $artifact"
	[ "$(printf '%s\n' "$control" | sed -n 's/^Package: //p')" = "$package" ] ||
		fail "$artifact has an unexpected package identity"
	[ "$(printf '%s\n' "$control" | sed -n 's/^Source: //p')" = "$expected_source" ] ||
		fail "$artifact has an unexpected source identity"
	case "$control" in
		*'/workspace/'*|*'/Users/'*|*'/home/'*|*'/private/tmp/'*|*'BEGIN '*'PRIVATE KEY'*)
			fail "$artifact control metadata leaks a host path or private key"
			;;
	esac
}

copy_candidate sbe-mtr096-root-cli-candidate "$MTR_RELEASE_ARCHIVE"
copy_candidate sbe-htop353-candidate "$HTOP_RELEASE_ARCHIVE"
copy_candidate sbe-nano92-daily-candidate "$NANO_RELEASE_ARCHIVE"

(cd "$output" && sha256sum ./*.ipk | LC_ALL=C sort -k2) \
	> "$output/PACKAGE_SHA256SUMS"

printf 'BUILT, NOT APPROVED: three isolated diagnostics IPKs are in %s\n' "$output"
printf 'No rootfs, image, kernel, firmware or device target was invoked.\n'
