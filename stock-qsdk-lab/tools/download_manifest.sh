#!/bin/sh
set -eu

manifest=${1:?usage: download_manifest.sh MANIFEST DESTINATION}
destination=${2:?usage: download_manifest.sh MANIFEST DESTINATION}

mkdir -p "$destination"
tail -n +2 "$manifest" | while IFS="$(printf '\t')" read -r package version feed filename sha256 url; do
	output="$destination/$filename"
	if [ ! -f "$output" ]; then
		printf 'Downloading %s %s\n' "$package" "$version"
		curl -fL --retry 3 --connect-timeout 20 -o "$output" "$url"
	fi
	actual=$(shasum -a 256 "$output" | awk '{print $1}')
	if [ "$actual" != "$sha256" ]; then
		printf 'checksum mismatch: %s\n' "$output" >&2
		exit 1
	fi
done

