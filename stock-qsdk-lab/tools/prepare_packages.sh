#!/bin/sh
set -eu

lab_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
index_dir="$lab_dir/cache/index"
ipk_dir="$lab_dir/cache/ipk"
manifest="$lab_dir/work/luci-package-manifest.tsv"
release=https://downloads.openwrt.org/releases/19.07.10

mkdir -p "$index_dir" "$ipk_dir" "$(dirname "$manifest")"

for feed in base luci packages routing; do
	curl -fL --retry 3 --connect-timeout 20 \
		-o "$index_dir/$feed.Packages.gz" \
		"$release/packages/aarch64_generic/$feed/Packages.gz"
	gzip -t "$index_dir/$feed.Packages.gz"
done

curl -fL --retry 3 --connect-timeout 20 \
	-o "$index_dir/armvirt64.Packages.gz" \
	"$release/targets/armvirt/64/packages/Packages.gz"
gzip -t "$index_dir/armvirt64.Packages.gz"

set --
while IFS= read -r package; do
	case "$package" in
	'' | \#*) continue ;;
	esac
	set -- "$@" "$package"
done < "$lab_dir/package-roots.txt"

python3 "$lab_dir/tools/resolve_packages.py" \
	--index-dir "$index_dir" \
	--provided "$lab_dir/stock-provided-packages.txt" \
	--output "$manifest" \
	"$@"

sh "$lab_dir/tools/download_manifest.sh" "$manifest" "$ipk_dir"
printf 'package set is ready: %s\n' "$manifest"

