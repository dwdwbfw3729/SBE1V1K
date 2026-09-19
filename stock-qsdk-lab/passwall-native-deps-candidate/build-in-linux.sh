#!/bin/bash
set -euo pipefail
candidate=/candidate
toolchain=/qsdk/staging_dir/toolchain-aarch64_cortex-a73+neon-vfpv4_gcc-7.5.0_musl
target=/qsdk/staging_dir/target-aarch64_cortex-a73+neon-vfpv4_musl
run_name=${1:?pass a new output name}
case "$run_name" in ''|*[!a-z0-9-]*) exit 2 ;; esac
case "$run_name" in run-?*) ;; *) exit 2 ;; esac
out=$candidate/out/$run_name
test ! -e "$out"
test -x "$toolchain/bin/aarch64-openwrt-linux-musl-gcc"
export PATH="$toolchain/bin:$PATH"
export STAGING_DIR="$target"
export SOURCE_DATE_EPOCH=1789420800 TZ=UTC LC_ALL=C
cross=aarch64-openwrt-linux-musl-
export CC=${cross}gcc AR=${cross}ar RANLIB=${cross}ranlib
test "$("$CC" -dumpmachine)" = aarch64-openwrt-linux-musl
test "$("$CC" -dumpversion)" = 7.5.0
grep -Eq '^#define[[:space:]]+LUA_VERSION_NUM[[:space:]]+501' "$target/usr/include/lua.h"
work=$(mktemp -d /tmp/sbe-native-deps.XXXXXX)
mkdir -p "$work/src" "$out/payload"
printf '%s\n' "$work" > "$out/build-work-path.txt"
common='-Os -pipe -mcpu=cortex-a73 -fstack-protector-strong -D_FORTIFY_SOURCE=2'
link='-Wl,-z,relro -Wl,-z,now -Wl,-z,noexecstack'
dist=$candidate/distfiles
(cd "$dist" && sha256sum -c "$candidate/sources.sha256")
for archive in microsocks-1.0.5.tar.gz tcping-db910183.tar.gz ipt2socks-1.1.4.tar.gz yaml-0.2.5.tar.gz lyaml-6.2.8.tar.gz; do
 tar -xzf "$dist/$archive" -C "$work/src"
done
unzip -q "$dist/dns2socks-2.1.zip" -d "$work/src/dns2socks"
patch_file=$candidate/upstream-packages/microsocks/patches/100-Add-SOCKS5-forwarding-rules-support.patch
test "$(sha256sum "$patch_file" | awk '{print $1}')" = 5f9bcfa4ea50c21c43863312a094b7939276c4f4cfddf353c82f441fa4fe5d88
(cd "$work/src/microsocks-1.0.5" && patch --batch --fuzz=0 -p1 < "$patch_file")
make -C "$work/src/microsocks-1.0.5" -j2 CC="$CC" CFLAGS="$common -fPIE -std=c99" LDFLAGS="$link -pie"
make -C "$work/src/tcping-db9101834732dac9aaa59dbb7fb9c74612dbf723" -j2 CC="$CC" CFLAGS="$common -fPIE" LDFLAGS="$link -pie"
make -C "$work/src/ipt2socks-1.1.4" -j2 CC="$CC" \
 CFLAGS="$common -fPIE -std=c99 -pthread -fno-strict-aliasing" LDFLAGS="$link -pie -pthread"
(cd "$work/src/dns2socks/DNS2SOCKS" && "$CC" $common -fPIE DNS2SOCKS.c $link -pie -pthread -o dns2socks)
for spec in \
 microsocks:microsocks-1.0.5/microsocks \
 tcping:tcping-db9101834732dac9aaa59dbb7fb9c74612dbf723/tcping \
 ipt2socks:ipt2socks-1.1.4/ipt2socks \
 dns2socks:dns2socks/DNS2SOCKS/dns2socks; do
 package=${spec%%:*}
 source=${spec#*:}
 mkdir -p "$out/payload/$package/usr/bin"
 cp "$work/src/$source" "$out/payload/$package/usr/bin/$package"
 "${cross}strip" --strip-unneeded "$out/payload/$package/usr/bin/$package"
done
# ChinaDNS-NG is the project's official fully static ARM64 release, not a
# binary claimed to have been rebuilt by this script.
mkdir -p "$out/payload/chinadns-ng/usr/bin"
install -m 755 "$dist/chinadns-ng-2025.08.09-aarch64" "$out/payload/chinadns-ng/usr/bin/chinadns-ng"
test "$(sha256sum "$out/payload/chinadns-ng/usr/bin/chinadns-ng" | awk '{print $1}')" = 42ddd494200ec6d88b35902927688d316bc23e06e6c08d9e01eb2412196ab845
(cd "$work/src/yaml-0.2.5" && \
 CFLAGS="$common -fPIC" LDFLAGS="$link" ./configure --host=aarch64-openwrt-linux-musl --prefix=/usr --enable-shared --disable-static && \
 make -j2 && make DESTDIR="$work/yaml-stage" install)
mkdir -p "$out/payload/libyaml/usr/lib"
cp -a "$work/yaml-stage/usr/lib/libyaml-0.so.2" "$work/yaml-stage/usr/lib/libyaml-0.so.2.0.9" "$out/payload/libyaml/usr/lib/"
"${cross}strip" --strip-unneeded "$out/payload/libyaml/usr/lib/libyaml-0.so.2.0.9"
mkdir -p "$out/payload/lyaml/usr/lib/lua/lyaml"
(cd "$work/src/lyaml-1afb1f870ae486097f79586502f4254d6074afcb" && \
 "$CC" $common -fPIC -shared '-DPACKAGE="lyaml"' '-DVERSION="6.2.8"' -DNDEBUG \
 -I"$target/usr/include" -I"$work/yaml-stage/usr/include" \
 ext/yaml/yaml.c ext/yaml/emitter.c ext/yaml/parser.c ext/yaml/scanner.c \
 -L"$work/yaml-stage/usr/lib" -lyaml $link -o "$out/payload/lyaml/usr/lib/lua/yaml.so" && \
 cp lib/lyaml/*.lua "$out/payload/lyaml/usr/lib/lua/lyaml/")
"${cross}strip" --strip-unneeded "$out/payload/lyaml/usr/lib/lua/yaml.so"
python3 "$candidate/package-ipks.py" "$out"
python3 "$candidate/audit-elf.py" "$out/payload" "$toolchain/bin/${cross}readelf"
printf '%s\n' 'Built seven userland dependency packages. No router or shared QSDK make was used.'
