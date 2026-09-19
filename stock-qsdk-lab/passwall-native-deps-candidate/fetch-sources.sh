#!/bin/sh
set -eu
candidate_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
dist=$candidate_dir/distfiles
mkdir -p "$dist"
fetch() {
 name=$1
 digest=$2
 url=$3
 if [ ! -f "$dist/$name" ]; then
  curl -fL --retry 2 --connect-timeout 15 --max-time 120 \
   --proto '=https' --proto-redir '=https' "$url" -o "$dist/$name.part"
  mv "$dist/$name.part" "$dist/$name"
 fi
 actual=$(shasum -a 256 "$dist/$name" | awk '{print $1}')
 if [ "$digest" != - ] && [ "$actual" != "$digest" ]; then
  echo "source checksum mismatch: $name" >&2
  exit 1
 fi
 printf '%s  %s\n' "$actual" "$name"
}
# Recipes from Openwrt-Passwall/openwrt-passwall-packages commit
# b08887dfbd0db1710e54203ca700a697653f5b8d. These are build inputs,
# not runtime restrictions on users installing or updating software.
fetch microsocks-1.0.5.tar.gz \
 939d1851a18a4c03f3cc5c92ff7a50eaf045da7814764b4cb9e26921db15abc8 \
 https://codeload.github.com/rofl0r/microsocks/tar.gz/v1.0.5
fetch dns2socks-2.1.zip \
 406b5003523577d39da66767adfe54f7af9b701374363729386f32f6a3a995f4 \
 https://github.com/Openwrt-Passwall/openwrt-passwall-packages/releases/download/dns2socks/SourceCode.zip
fetch tcping-db910183.tar.gz \
 7f7307fb8aba6d7b9811f6cc48fec878a077d777d4e4fcb2e72bdc8d3c1ffb6e \
 https://codeload.github.com/Lienol/tcping/tar.gz/db9101834732dac9aaa59dbb7fb9c74612dbf723
fetch ipt2socks-1.1.4.tar.gz \
 68dc76e63951d655c2fd9b420e175b5a75a50014d6db6e729398b41f2c988356 \
 https://codeload.github.com/zfl9/ipt2socks/tar.gz/v1.1.4
fetch chinadns-ng-2025.08.09-aarch64 \
 42ddd494200ec6d88b35902927688d316bc23e06e6c08d9e01eb2412196ab845 \
 'https://github.com/zfl9/chinadns-ng/releases/download/2025.08.09/chinadns-ng+wolfssl_noasm@aarch64-linux-musl@generic+v8a@fast+lto'
# Separate upstream YAML inputs: libyaml 0.2.5 release archive (also used by
# OpenWrt packages/libs/yaml), and lyaml 6.2.8 at the exact commit below.
fetch yaml-0.2.5.tar.gz \
 c642ae9b75fee120b2d96c712538bd2cf283228d2337df2cf2988e3c02678ef4 \
 https://pyyaml.org/download/libyaml/yaml-0.2.5.tar.gz
fetch lyaml-6.2.8.tar.gz \
 74f347f16514a6c70ec22bfaf0e4e0de87a0d434191111642560de93ab312efc \
 https://codeload.github.com/gvvaughan/lyaml/tar.gz/1afb1f870ae486097f79586502f4254d6074afcb
