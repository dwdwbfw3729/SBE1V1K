#!/bin/bash
set -euo pipefail

candidate_dir=$(cd -- "$(dirname -- "$0")" && pwd)
dist_dir=${1:?usage: build-in-linux.sh DIST_DIR TOOLCHAIN_DIR TARGET_STAGING OUTPUT_DIR}
toolchain_dir=${2:?usage: build-in-linux.sh DIST_DIR TOOLCHAIN_DIR TARGET_STAGING OUTPUT_DIR}
target_staging=${3:?usage: build-in-linux.sh DIST_DIR TOOLCHAIN_DIR TARGET_STAGING OUTPUT_DIR}
output_dir=${4:?usage: build-in-linux.sh DIST_DIR TOOLCHAIN_DIR TARGET_STAGING OUTPUT_DIR}
. "$candidate_dir/sources.lock"

[ "$(uname -s)" = Linux ] || {
	printf 'ERROR: this script must run in Linux\n' >&2
	exit 1
}
[ -x "$toolchain_dir/bin/aarch64-openwrt-linux-musl-gcc" ] || {
	printf 'ERROR: QSDK GCC 7.5/musl toolchain is missing\n' >&2
	exit 1
}
[ -f "$target_staging/usr/include/zlib.h" ] || {
	printf 'ERROR: QSDK target zlib headers are missing\n' >&2
	exit 1
}
[ -f "$target_staging/usr/lib/libz.so.1" ] || {
	printf 'ERROR: QSDK target zlib runtime is missing\n' >&2
	exit 1
}

work_root=/tmp/sbe-tls-curl-build
rm -rf "$work_root"
mkdir -p "$work_root/src" "$work_root/openssl-stage" "$work_root/curl-stage" "$work_root/runtime-openssl" "$work_root/runtime-curl"
rm -rf "$output_dir"
mkdir -p "$output_dir"

"$candidate_dir/verify-sources.sh" "$dist_dir"
tar -xzf "$dist_dir/$OPENSSL_ARCHIVE" -C "$work_root/src"
tar -xJf "$dist_dir/$CURL_ARCHIVE" -C "$work_root/src"

cross=aarch64-openwrt-linux-musl-
export PATH="$toolchain_dir/bin:$PATH"
export AR=${cross}ar
export AS=${cross}as
export CC=${cross}gcc
export CXX=${cross}g++
export LD=${cross}ld
export NM=${cross}nm
export OBJCOPY=${cross}objcopy
export OBJDUMP=${cross}objdump
export RANLIB=${cross}ranlib
export READELF=${cross}readelf
export STRIP=${cross}strip
export STAGING_DIR="$target_staging"
export SOURCE_DATE_EPOCH
export TZ=UTC
export LC_ALL=C

common_cppflags='-D_FORTIFY_SOURCE=2'
common_cflags='-Os -pipe -mcpu=cortex-a73 -fstack-protector-strong -Wformat -Werror=format-security'
common_ldflags='-Wl,-z,relro -Wl,-z,now -Wl,-z,noexecstack'

openssl_src="$work_root/src/openssl-$OPENSSL_VERSION"
(
	cd "$openssl_src"
	# Configure prepends --cross-compile-prefix to tool names, so pass the
	# unprefixed names here rather than the fully qualified global variables.
	CC=gcc CXX=g++ AR=ar AS=as LD=ld NM=nm RANLIB=ranlib \
	CPPFLAGS="$common_cppflags" CFLAGS="$common_cflags -fPIC" \
	LDFLAGS="$common_ldflags" perl Configure linux-aarch64 \
		--cross-compile-prefix="$cross" \
		--prefix=/usr --openssldir=/etc/ssl3 --libdir=lib \
		shared enable-pie no-tests no-afalgeng no-capieng no-dgram no-fips no-legacy \
		no-md2 no-md4 no-rc2 no-rc4 no-rc5 no-sctp no-srp no-weak-ssl-ciphers \
		no-zlib no-quic
	make -s -j"${JOBS:-4}"
	make -s DESTDIR="$work_root/openssl-stage" install_sw
)

curl_src="$work_root/src/curl-$CURL_VERSION"
(
	cd "$curl_src"
	CPPFLAGS="$common_cppflags -I$work_root/openssl-stage/usr/include -I$target_staging/usr/include" \
	CFLAGS="$common_cflags -fPIE -pthread" \
	LDFLAGS="$common_ldflags -pie -pthread -L$work_root/openssl-stage/usr/lib -L$target_staging/usr/lib" \
	LIBS='-ldl' \
	PKG_CONFIG=false \
	./configure \
		--build=aarch64-linux-gnu --host=aarch64-openwrt-linux-musl \
		--prefix=/usr \
		--disable-shared --enable-static --enable-symbol-hiding \
		--enable-http --enable-ipv6 --enable-threaded-resolver \
		--enable-proxy --enable-basic-auth --enable-bearer-auth --enable-hsts \
		--disable-alt-svc --disable-httpsrr --disable-ech --disable-ssls-export \
		--disable-proxy-http3 --disable-openssl-auto-load-config \
		--disable-debug --disable-docs --disable-manual \
		--disable-libcurl-option --disable-ldap --disable-ldaps \
		--disable-aws --disable-httpsig \
		--disable-digest-auth --disable-kerberos-auth --disable-negotiate-auth \
		--disable-unix-sockets --disable-dnsshuffle --disable-get-easy-options \
		--disable-cookies --disable-doh --disable-mime --disable-form-api \
		--disable-dateparse --disable-netrc --disable-headers-api \
		--disable-dict --disable-file --disable-ftp --disable-gopher \
		--disable-imap --disable-mqtt --disable-pop3 --disable-rtsp \
		--disable-smb --disable-smtp --disable-telnet --disable-tftp \
		--disable-ipfs --disable-websockets --disable-ntlm \
		--with-openssl="$work_root/openssl-stage/usr" \
		--with-zlib="$target_staging/usr" \
		--with-ca-bundle=/etc/ssl/cert.pem --with-ca-path=/etc/ssl/certs \
		--without-brotli --without-zstd --without-libidn2 --without-libpsl \
		--without-nghttp2 --without-ngtcp2 --without-nghttp3 \
		--without-libssh2 --without-gssapi
	make -s -j"${JOBS:-4}"
	make -s DESTDIR="$work_root/curl-stage" install
)

protocols=$("$work_root/curl-stage/usr/bin/curl-config" --protocols | tr '\n' ' ' | sed 's/[[:space:]]*$//')
[ "$protocols" = 'HTTP HTTPS' ] || {
	printf 'ERROR: unexpected curl protocol set: %s\n' "$protocols" >&2
	exit 1
}

# Runtime payload deliberately omits development symlinks libssl.so,
# libcrypto.so and libcurl.so.4.  Existing factory ABI consumers remain on
# libssl.so.1.1/libcrypto.so.1.1/libcurl.so.4, while new scripts can opt into
# /usr/bin/curl-sbe and the .so.3 OpenSSL ABI.
install -Dm755 "$work_root/openssl-stage/usr/bin/openssl" "$work_root/runtime-openssl/usr/bin/openssl3"
install -Dm644 "$work_root/openssl-stage/usr/lib/libcrypto.so.3" "$work_root/runtime-openssl/usr/lib/libcrypto.so.3"
install -Dm644 "$work_root/openssl-stage/usr/lib/libssl.so.3" "$work_root/runtime-openssl/usr/lib/libssl.so.3"
install -Dm644 "$openssl_src/apps/openssl.cnf" "$work_root/runtime-openssl/etc/ssl3/openssl.cnf"
install -Dm755 "$work_root/curl-stage/usr/bin/curl" "$work_root/runtime-curl/usr/bin/curl-sbe"

"$STRIP" --strip-unneeded \
	"$work_root/runtime-openssl/usr/bin/openssl3" \
	"$work_root/runtime-openssl/usr/lib/libcrypto.so.3" \
	"$work_root/runtime-openssl/usr/lib/libssl.so.3" \
	"$work_root/runtime-curl/usr/bin/curl-sbe"

create_ipk() {
	package=$1
	version=$2
	depends=$3
	source=$4
	license=$5
	description=$6
	data_root=$7
	ipk_root="$work_root/ipk-$package"
	rm -rf "$ipk_root"
	mkdir -p "$ipk_root/control" "$ipk_root/outer"
	installed_size=$(find "$data_root" -type f -printf '%s\n' | awk '{s += $1} END {print s + 0}')
	{
		printf 'Package: %s\n' "$package"
		printf 'Version: %s-1\n' "$version"
		printf 'Depends: %s\n' "$depends"
		printf 'Source: %s\n' "$source"
		printf 'SourceName: %s\n' "$package"
		printf 'License: %s\n' "$license"
		printf 'Section: libs\n'
		printf 'Architecture: aarch64_cortex-a73_neon-vfpv4\n'
		printf 'Installed-Size: %s\n' "$installed_size"
		printf 'Description: %s\n' "$description"
	} >"$ipk_root/control/control"
	printf '2.0\n' >"$ipk_root/outer/debian-binary"
	tar --sort=name --mtime="@$SOURCE_DATE_EPOCH" --owner=0 --group=0 --numeric-owner \
		-C "$data_root" -cf - . | gzip -n -9 >"$ipk_root/outer/data.tar.gz"
	tar --sort=name --mtime="@$SOURCE_DATE_EPOCH" --owner=0 --group=0 --numeric-owner \
		-C "$ipk_root/control" -cf - ./control | gzip -n -9 >"$ipk_root/outer/control.tar.gz"
	tar --sort=name --mtime="@$SOURCE_DATE_EPOCH" --owner=0 --group=0 --numeric-owner \
		-C "$ipk_root/outer" -cf - ./debian-binary ./data.tar.gz ./control.tar.gz | gzip -n -9 \
		>"$output_dir/${package}_${version}-1_aarch64_cortex-a73_neon-vfpv4.ipk"
}

create_ipk sbe-openssl35-candidate "$OPENSSL_VERSION" 'libc, libgcc1' "$OPENSSL_ARCHIVE" Apache-2.0 \
	'Isolated OpenSSL 3.5 LTS runtime with .so.3 ABI; no service or private key.' \
	"$work_root/runtime-openssl"
create_ipk sbe-curl822-candidate "$CURL_VERSION" 'libc, libgcc1, zlib, sbe-openssl35-candidate' "$CURL_ARCHIVE" curl \
	'HTTP/HTTPS-only curl CLI using the isolated OpenSSL 3.5 ABI; no listener or init script.' \
	"$work_root/runtime-curl"

cp -a "$work_root/runtime-openssl" "$output_dir/runtime-openssl"
cp -a "$work_root/runtime-curl" "$output_dir/runtime-curl"
{
	printf 'OPENSSL_VERSION=%s\n' "$OPENSSL_VERSION"
	printf 'OPENSSL_COMMIT=%s\n' "$OPENSSL_COMMIT"
	printf 'CURL_VERSION=%s\n' "$CURL_VERSION"
	printf 'CURL_COMMIT=%s\n' "$CURL_COMMIT"
	printf 'TOOLCHAIN=%s\n' "$($CC --version | sed -n '1p')"
	printf 'CPPFLAGS=%s\n' "$common_cppflags"
	printf 'CFLAGS=%s\n' "$common_cflags"
	printf 'LDFLAGS=%s\n' "$common_ldflags"
	printf 'CURL_PROTOCOLS=http,https\n'
	printf 'CURL_AUTH=basic,bearer\n'
	printf 'CURL_DISABLED_EXPERIMENTS=alt-svc,httpsrr,ech,ssls-export,httpsig,http3\n'
	printf 'OPENSSL_SONAMES=libssl.so.3,libcrypto.so.3\n'
	printf 'SOURCE_DATE_EPOCH=%s\n' "$SOURCE_DATE_EPOCH"
	printf 'FACTORY_ABI_REPLACED=no\n'
} >"$output_dir/CANDIDATE_BUILD_CONFIG"

(
	cd "$output_dir"
	find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum >SHA256SUMS
)
printf 'Candidate output written to %s (not integrated)\n' "$output_dir"
