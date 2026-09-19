#!/bin/bash

set -euo pipefail

fail() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

sha256_file() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | awk '{print $1}'
	else
		shasum -a 256 "$1" | awk '{print $1}'
	fi
}

sha256_stream() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum | awk '{print $1}'
	else
		shasum -a 256 | awk '{print $1}'
	fi
}

# Hash regular-file contents, paths and symlink targets in a prepared LuCI
# tree. Git-controlled LuCI paths contain no newlines; reject such a path if a
# future source snapshot ever introduces one instead of producing ambiguity.
source_tree_sha256() {
	local tree=$1 entry
	[ -d "$tree" ] || fail "source tree is missing: $tree"
	(
		cd "$tree"
		find . \( -type f -o -type l \) -print | LC_ALL=C sort |
		while IFS= read -r entry; do
			case "$entry" in *$'\n'*) fail "newline in source path: $entry" ;; esac
			if [ -L "$entry" ]; then
				printf 'L\t%s\t%s\n' "$entry" "$(readlink "$entry")"
			else
				printf 'F\t%s\t%s\n' "$(sha256_file "$entry")" "$entry"
			fi
		done
	) | sha256_stream
}
