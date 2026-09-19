#!/bin/sh

set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$HERE/scripts/common.sh"

for var in PASSWALL_ARCHIVE XRAY_ARCHIVE GO_ARCHIVE; do
	eval "name=\${$var}"
	[ -f "$DIST_DIR/$name" ] || { echo "missing distfile: $name" >&2; exit 1; }
done

require_equal "PassWall archive sha256" "$(sha256_file "$DIST_DIR/$PASSWALL_ARCHIVE")" "$PASSWALL_ARCHIVE_SHA256"
require_equal "PassWall archive size" "$(file_size "$DIST_DIR/$PASSWALL_ARCHIVE")" "$PASSWALL_ARCHIVE_SIZE"
require_equal "Xray archive sha256" "$(sha256_file "$DIST_DIR/$XRAY_ARCHIVE")" "$XRAY_ARCHIVE_SHA256"
require_equal "Xray archive size" "$(file_size "$DIST_DIR/$XRAY_ARCHIVE")" "$XRAY_ARCHIVE_SIZE"
require_equal "Go archive sha256" "$(sha256_file "$DIST_DIR/$GO_ARCHIVE")" "$GO_ARCHIVE_SHA256"

verify_archive_names() {
	archive=$1 prefix=$2
	tar -tzf "$archive" | awk -v p="$prefix" '
		/^\// || /(^|\/)\.\.($|\/)/ { bad=1 }
		index($0,p) != 1 { bad=1 }
		END { exit bad ? 1 : 0 }
	' || { echo "unsafe or unexpected archive members: $archive" >&2; exit 1; }
}
verify_archive_names "$DIST_DIR/$PASSWALL_ARCHIVE" "openwrt-passwall-$PASSWALL_TAG/"
verify_archive_names "$DIST_DIR/$XRAY_ARCHIVE" "Xray-core-${XRAY_TAG#v}/"
verify_archive_names "$DIST_DIR/$GO_ARCHIVE" "go/"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/passwall-verify.XXXXXX")
trap 'rm -rf "$tmp"' EXIT INT TERM
tar -xzf "$DIST_DIR/$PASSWALL_ARCHIVE" -C "$tmp" "openwrt-passwall-$PASSWALL_TAG/luci-app-passwall/Makefile" "openwrt-passwall-$PASSWALL_TAG/luci-app-passwall/root/usr/share/passwall/0_default_config"
tar -xzf "$DIST_DIR/$XRAY_ARCHIVE" -C "$tmp" "Xray-core-${XRAY_TAG#v}/go.mod" "Xray-core-${XRAY_TAG#v}/go.sum"
require_equal "upstream PassWall Makefile sha256" "$(sha256_file "$tmp/openwrt-passwall-$PASSWALL_TAG/luci-app-passwall/Makefile")" "$PASSWALL_MAKEFILE_SHA256"
require_equal "upstream PassWall default sha256" "$(sha256_file "$tmp/openwrt-passwall-$PASSWALL_TAG/luci-app-passwall/root/usr/share/passwall/0_default_config")" "$PASSWALL_DEFAULT_SHA256"
require_equal "Xray go.mod sha256" "$(sha256_file "$tmp/Xray-core-${XRAY_TAG#v}/go.mod")" "$XRAY_GOMOD_SHA256"
require_equal "Xray go.sum sha256" "$(sha256_file "$tmp/Xray-core-${XRAY_TAG#v}/go.sum")" "$XRAY_GOSUM_SHA256"
grep -qx "go 1.26" "$tmp/Xray-core-${XRAY_TAG#v}/go.mod" || { echo "unexpected Xray Go language version" >&2; exit 1; }

# A codeload checksum by itself only pins opaque bytes.  Recreate Git's index
# from every archive member (including files matched by upstream .gitignore)
# and require its tree object to be the one recorded for the official tag.
verify_archive_tree() {
	archive=$1 prefix=$2 expected_tree=$3
	tree_root=$tmp/tree-$prefix
	git_dir=$tmp/git-$prefix
	index=$tmp/index-$prefix
	mkdir -p "$tree_root"
	tar -xzf "$archive" -C "$tree_root"
	root=$tree_root/$prefix
	git init -q --bare "$git_dir"
	GIT_ATTR_NOSYSTEM=1 GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
		GIT_INDEX_FILE="$index" git --git-dir="$git_dir" --work-tree="$root" \
		-c core.bare=false -c core.autocrlf=false -c core.filemode=true \
		add -f -A -- .
	actual_tree=$(GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
		GIT_INDEX_FILE="$index" git --git-dir="$git_dir" write-tree)
	require_equal "$prefix Git tree" "$actual_tree" "$expected_tree"
}
verify_archive_tree "$DIST_DIR/$PASSWALL_ARCHIVE" "openwrt-passwall-$PASSWALL_TAG" "$PASSWALL_TREE"
verify_archive_tree "$DIST_DIR/$XRAY_ARCHIVE" "Xray-core-${XRAY_TAG#v}" "$XRAY_TREE"

echo "PASS: official source archives and Git trees match locks"
