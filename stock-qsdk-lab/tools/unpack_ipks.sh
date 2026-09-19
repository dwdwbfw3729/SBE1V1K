#!/bin/sh
set -eu

manifest=${1:?usage: unpack_ipks.sh MANIFEST IPK_DIRECTORY DESTINATION}
source_dir=${2:?usage: unpack_ipks.sh MANIFEST IPK_DIRECTORY DESTINATION}
destination=${3:?usage: unpack_ipks.sh MANIFEST IPK_DIRECTORY DESTINATION}

mkdir -p "$destination"
tail -n +2 "$manifest" | while IFS="$(printf '\t')" read -r package version feed filename sha256 url; do
	ipk="$source_dir/$filename"
	[ -f "$ipk" ] || {
		printf 'missing package: %s\n' "$ipk" >&2
		exit 1
	}
	actual=$(shasum -a 256 "$ipk" | awk '{print $1}')
	[ "$actual" = "$sha256" ] || {
		printf 'checksum mismatch: %s\n' "$ipk" >&2
		exit 1
	}
	tar -xOzf "$ipk" ./data.tar.gz | tar -xzf - -C "$destination"
done
