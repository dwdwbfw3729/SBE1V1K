#!/bin/sh
set -eu

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$HERE/sources.lock"
QSDK_TOP=${1:-/qsdk}
DEST=${2:-"$HERE/out"}
SOURCE_DATE_EPOCH=1591022183
PKG_VERSION=git-20.153.52583-6dd22ec-1
PKG_NAME=luci-proto-vxlan
PKG_ARCH=all
JSMIN=$QSDK_TOP/staging_dir/hostpkg/bin/jsmin
UPSTREAM_PACKAGE=$HERE/upstream/protocols/luci-proto-vxlan

fail() {
	echo "ERROR: $*" >&2
	exit 1
}

[ -x "$JSMIN" ] || fail "locked QSDK host jsmin is unavailable: $JSMIN"
command -v sha256sum >/dev/null 2>&1 || fail 'sha256sum is required'
command -v tar >/dev/null 2>&1 || fail 'GNU tar is required'
command -v gzip >/dev/null 2>&1 || fail 'gzip is required'

check_source() {
	expected=$1
	path=$2
	actual=$(sha256sum "$path" | awk '{ print $1 }')
	[ "$actual" = "$expected" ] || fail "source hash mismatch: $path"
}

check_source 9fedd06d102ff8c43833168a90b991959322dc1971063d1b7b6cf713a8807257 \
	"$UPSTREAM_PACKAGE/Makefile"
check_source 619072b9dd5f8aa43779c2105b082f045d5e43d11a939473f764c1a89a812aac \
	"$UPSTREAM_PACKAGE/htdocs/luci-static/resources/protocol/vxlan.js"
check_source bf310f1ed4fda25732c0e4af39f452121ab0a00990cb92b5a92cedf2c0a130b5 \
	"$UPSTREAM_PACKAGE/htdocs/luci-static/resources/protocol/vxlan6.js"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT HUP INT TERM
pkg=$work/pkg
control=$pkg/CONTROL
data_dir=$pkg/www/luci-static/resources/protocol
archive=$DEST/${PKG_NAME}_${PKG_VERSION}_${PKG_ARCH}.ipk

mkdir -p "$control" "$data_dir" "$DEST" "$work/archive"

# Match CONFIG_LUCI_JSMIN=y in the locked QSDK build without invoking make.
"$JSMIN" < "$UPSTREAM_PACKAGE/htdocs/luci-static/resources/protocol/vxlan.js" \
	> "$data_dir/vxlan.js"
"$JSMIN" < "$UPSTREAM_PACKAGE/htdocs/luci-static/resources/protocol/vxlan6.js" \
	> "$data_dir/vxlan6.js"
chmod 0644 "$data_dir/vxlan.js" "$data_dir/vxlan6.js"

cat > "$control/control" <<EOF
Package: $PKG_NAME
Version: $PKG_VERSION
Depends: libc, vxlan
Source: protocols/luci-proto-vxlan
SourceName: $PKG_NAME
License: Apache-2.0
Section: luci
Architecture: $PKG_ARCH
Installed-Size: 0
Description:  Support for Virtual eXtensible Local Area Network (VXLAN, RFC7348)
EOF

cat > "$control/postinst" <<'EOF'
#!/bin/sh
[ "${IPKG_NO_SCRIPT}" = "1" ] && exit 0
[ -x ${IPKG_INSTROOT}/lib/functions.sh ] || exit 0
. ${IPKG_INSTROOT}/lib/functions.sh
default_postinst $0 $@
EOF

cat > "$control/prerm" <<'EOF'
#!/bin/sh
[ -x ${IPKG_INSTROOT}/lib/functions.sh ] || exit 0
. ${IPKG_INSTROOT}/lib/functions.sh
default_prerm $0 $@
EOF

chmod 0644 "$control/control"
chmod 0755 "$control/postinst" "$control/prerm"

tar --format=gnu --sort=name --owner=0 --group=0 --numeric-owner \
	--mtime="@$SOURCE_DATE_EPOCH" --exclude=./CONTROL -C "$pkg" -cf - . \
	| gzip -n -9 > "$work/archive/data.tar.gz"

installed_size=$(stat -c '%s' "$work/archive/data.tar.gz")
sed -i "s/^Installed-Size: .*/Installed-Size: $installed_size/" "$control/control"

tar --format=gnu --sort=name --owner=0 --group=0 --numeric-owner \
	--mtime="@$SOURCE_DATE_EPOCH" -C "$control" -cf - . \
	| gzip -n -9 > "$work/archive/control.tar.gz"
printf '2.0\n' > "$work/archive/debian-binary"
touch -d "@$SOURCE_DATE_EPOCH" "$work/archive/debian-binary"

tar --format=gnu --sort=name --owner=0 --group=0 --numeric-owner \
	--mtime="@$SOURCE_DATE_EPOCH" -C "$work/archive" -cf - \
	./debian-binary ./data.tar.gz ./control.tar.gz \
	| gzip -n -9 > "$work/$PKG_NAME.ipk"

mv "$work/$PKG_NAME.ipk" "$archive"
(cd "$DEST" && sha256sum "$(basename "$archive")") > "$archive.sha256"
echo "$archive"
