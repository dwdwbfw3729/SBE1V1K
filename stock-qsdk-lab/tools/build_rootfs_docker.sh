#!/usr/bin/env bash
set -Eeuo pipefail

lab_dir="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
repo_dir="$(CDPATH= cd -- "$lab_dir/.." && pwd)"

die() {
	printf 'error: %s\n' "$*" >&2
	exit 1
}

[ "$#" -ge 2 ] && [ "$#" -le 6 ] || \
	die "usage: build_rootfs_docker.sh STOCK_IMAGE OUTPUT_IMAGE [ROOTFS_DATA_LABEL] [MOUNT_POLICY] [COMPONENT_PROFILE] [SOURCE_BASELINE]"
stock_image="$1"
output_image="$2"
rootfs_data_label="${3:-rootfs_data_1}"
mount_policy="${4:-normal}"
component_profile="${5:-production}"
source_baseline="${6:-$lab_dir/stock-baseline.env}"

case "$rootfs_data_label" in
	rootfs_data_1) ;;
	*) die "ROOTFS_DATA_LABEL must be rootfs_data_1" ;;
esac
case "$mount_policy" in
	normal|trial-safe) ;;
	*) die "MOUNT_POLICY must be normal or trial-safe" ;;
esac
case "$component_profile" in
	''|*[!a-z0-9-]*|-*|*-) die "COMPONENT_PROFILE contains invalid characters" ;;
esac
[ -f "$lab_dir/component-profiles/$component_profile.json" ] || \
	die "component profile does not exist: $component_profile"

[ -f "$stock_image" ] || die "stock image not found: $stock_image"
[ -f "$source_baseline" ] || die "source baseline not found: $source_baseline"
source_commit=$(git -C "$lab_dir" rev-parse --verify HEAD)
case "$source_commit" in ''|*[!0-9a-f]*) die "source Git commit is not hexadecimal" ;; esac
[ "${#source_commit}" -eq 40 ] || die "source Git commit is not a full 40-character object ID"
source_dirty=false
source_diff_sha256=clean
if [ -n "$(git -C "$lab_dir" status --porcelain -- .)" ]; then
	[ "${SBE_ALLOW_DIRTY_SOURCE:-0}" = 1 ] || \
		die "source tree has uncommitted changes; commit them or set SBE_ALLOW_DIRTY_SOURCE=1 for a marked local validation build"
	source_dirty=true
	source_state=$(mktemp /tmp/sbe-source-state.XXXXXX)
	trap 'rm -f "$source_state"' EXIT
	git -C "$lab_dir" diff --binary HEAD -- . > "$source_state"
	git -C "$lab_dir" ls-files --others --exclude-standard -- . | LC_ALL=C sort | while IFS= read -r relative; do
		printf 'untracked %s\n' "$relative"
		[ -f "$lab_dir/$relative" ] && shasum -a 256 "$lab_dir/$relative"
	done >> "$source_state"
	source_diff_sha256=$(shasum -a 256 "$source_state" | awk '{print $1}')
fi

docker_bin=${DOCKER_BIN:-}
if [ -z "$docker_bin" ]; then
	docker_bin=$(command -v docker || true)
fi
if [ -z "$docker_bin" ] && [ -x /Applications/Docker.app/Contents/Resources/bin/docker ]; then
	docker_bin=/Applications/Docker.app/Contents/Resources/bin/docker
fi
[ -n "$docker_bin" ] || die "Docker Desktop or another Linux Docker engine is required"
"$docker_bin" info >/dev/null 2>&1 || die "Docker engine is not running"

stock_dir="$(CDPATH= cd -- "$(dirname -- "$stock_image")" && pwd)"
stock_name="$(basename -- "$stock_image")"
baseline_dir="$(CDPATH= cd -- "$(dirname -- "$source_baseline")" && pwd)"
baseline_name="$(basename -- "$source_baseline")"
derived_source_name=derived-source.json
if [ -f "$baseline_dir/$derived_source_name" ]; then
	derived_source_in_container="/baseline/$derived_source_name"
else
	derived_source_in_container=""
fi
mkdir -p "$(dirname -- "$output_image")"
output_dir="$(CDPATH= cd -- "$(dirname -- "$output_image")" && pwd)"
output_name="$(basename -- "$output_image")"

image_name=sbe1v1k-stock-rootfs-builder:ubuntu-24.04
volume_name=sbe1v1k-stock-rootfs-work

if [ -n "${UBUNTU_PORTS_MIRROR:-}" ]; then
	"$docker_bin" build --build-arg "UBUNTU_PORTS_MIRROR=$UBUNTU_PORTS_MIRROR" \
		--platform linux/arm64 -f "$lab_dir/docker/Dockerfile" \
		-t "$image_name" "$lab_dir"
else
	"$docker_bin" build --platform linux/arm64 \
		-f "$lab_dir/docker/Dockerfile" -t "$image_name" "$lab_dir"
fi
"$docker_bin" volume create "$volume_name" >/dev/null
"$docker_bin" run --rm --platform linux/arm64 \
	-e SBE_SOURCE_COMMIT="$source_commit" \
	-e SBE_SOURCE_DIRTY="$source_dirty" \
	-e SBE_SOURCE_DIFF_SHA256="$source_diff_sha256" \
	-e SBE_BASELINE_PATH="/baseline/$baseline_name" \
	-e SBE_DERIVED_SOURCE_PATH="$derived_source_in_container" \
	-e SBE_FEED_POLICY="${SBE_FEED_POLICY:-embedded}" \
	-e SBE_PACKAGE_PROFILE="${SBE_PACKAGE_PROFILE:-}" \
	-v "$stock_dir:/input:ro" \
	-v "$baseline_dir:/baseline:ro" \
	-v "$lab_dir:/lab:ro" \
	-v "$output_dir:/out" \
	-v "$volume_name:/work" \
	"$image_name" \
	"/input/$stock_name" "/out/$output_name" \
	"$rootfs_data_label" "$mount_policy" "$component_profile"

case "$output_name" in
	*.img) squashfs_name=${output_name%.img}.root.squashfs ;;
	*) squashfs_name=$output_name.root.squashfs ;;
esac
shasum -a 256 \
	"$output_dir/$output_name" \
	"$output_dir/$squashfs_name" \
	"$output_dir/$output_name.manifest"
