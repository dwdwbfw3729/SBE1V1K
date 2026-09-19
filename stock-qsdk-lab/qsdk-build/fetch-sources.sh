#!/bin/sh
set -eu

lab_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$lab_dir/../.." && pwd)
workspace_root=$(CDPATH= cd -- "$repo_root/.." && pwd)
. "$lab_dir/sources.lock"

source_root=${QSDK_SOURCE_ROOT:-"$repo_root/stock-qsdk-lab/deps/qsdk-spf12.2-locked"}
qsdk_dir=$source_root/qsdk
metadata_only=${QSDK_METADATA_ONLY:-0}

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

# Rebuild a Git tree from every filesystem entry in an archive extraction.
# `git add -f` is deliberate: unlike a status-only check it includes files
# matched by an extracted .gitignore, so ignored transport residue cannot
# evade the locked tree comparison and later take part in a build.
verify_locked_archive_tree() (
	label=$1
	archive_path=$2
	expected_tree=$3

	verify_root=$(mktemp -d "$source_root/.sbe-archive-verify.XXXXXX") || exit 1
	trap 'rm -rf "$verify_root"' EXIT HUP INT TERM
	verify_worktree=$verify_root/worktree
	verify_git=$verify_root/git
	verify_index=$verify_root/index
	mkdir -p "$verify_worktree"
	GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
		git init -q --bare "$verify_git"

	tar -xzf "$archive_path" --strip-components=1 -C "$verify_worktree"
	if find "$verify_worktree" -name .git -print -quit | grep -q .; then
		fail "$label archive contains a forbidden nested .git entry"
	fi
	GIT_ATTR_NOSYSTEM=1 GIT_CONFIG_NOSYSTEM=1 \
		GIT_CONFIG_GLOBAL=/dev/null GIT_INDEX_FILE=$verify_index \
		git --git-dir="$verify_git" --work-tree="$verify_worktree" \
		-c core.bare=false -c core.autocrlf=false -c core.filemode=true \
		add -f -A -- .
	archive_tree=$(GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
		GIT_INDEX_FILE=$verify_index \
		git --git-dir="$verify_git" write-tree)
	[ "$archive_tree" = "$expected_tree" ] || \
		fail "$label archive contains missing, changed, untracked, or ignored files; tree is $archive_tree"
)

materialize_locked_archive() {
	label=$1
	url=$2
	mirror_url=$3
	proxy_url=$4
	cn_mirror_url=$5
	commit=$6
	expected_tree=$7
	destination=$8

	archive_dir=$source_root/source-archives
	archive_path=$archive_dir/$label-$commit.tar.gz
	mkdir -p "$archive_dir"
	if [ ! -f "$archive_path" ]; then
		archive_tmp=$archive_path.part.$$
		canonical_base=${url%.git}
		canonical_name=${canonical_base##*/}
		canonical_archive_url=$canonical_base/-/archive/$commit/$canonical_name-$commit.tar.gz
		proxy_archive_url=${proxy_url%.git}/archive/$commit.tar.gz
		mirror_archive_url=${mirror_url%.git}/archive/$commit.tar.gz
		cn_archive_url=
		[ -z "$cn_mirror_url" ] || \
			cn_archive_url=${cn_mirror_url%.git}/repository/archive/$commit.tar.gz
		downloaded=0
		for archive_url in "$cn_archive_url" "$proxy_archive_url" \
			"$mirror_archive_url" "$canonical_archive_url"
		do
			[ -n "$archive_url" ] || continue
			printf 'Downloading %-12s archive via %s\n' "$label" "$archive_url"
			: > "$archive_tmp"
			if curl --http1.1 -fL --retry 2 --retry-all-errors \
				--connect-timeout 20 --speed-limit 16384 --speed-time 20 \
				--max-time 600 "$archive_url" -o "$archive_tmp"
			then
				downloaded=1
				break
			fi
		done
		[ "$downloaded" -eq 1 ] || \
			fail "$label archive failed; partial file retained: $archive_tmp"
		mv "$archive_tmp" "$archive_path"
	fi
	tar -tzf "$archive_path" >/dev/null || \
		fail "$label cached archive is not a readable gzip tar: $archive_path"
	verify_locked_archive_tree "$label" "$archive_path" "$expected_tree"

	# Materialisation is only safe into the empty worktree created by clone_locked.
	# Refuse to overwrite an older checkout or preserve ignored build residue.
	[ -z "$(git -C "$destination" ls-files)" ] || \
		fail "$label destination already contains an indexed worktree: $destination"
	preexisting=$(git -C "$destination" status --porcelain \
		--untracked-files=all --ignored=matching)
	[ -z "$preexisting" ] || \
		fail "$label destination contains pre-existing untracked or ignored residue: $preexisting"
	tar -xzf "$archive_path" --strip-components=1 -C "$destination"

	# Populate the index from the locked tree, then hash the extracted tracked
	# files locally.  Comparing write-tree avoids trusting archive bytes or
	# filenames independently of the already-verified Git commit/tree.
	GIT_NO_LAZY_FETCH=1 git -C "$destination" read-tree --reset "$commit"
	GIT_NO_LAZY_FETCH=1 git -C "$destination" add -u -- .
	worktree_tree=$(GIT_NO_LAZY_FETCH=1 git -C "$destination" write-tree)
	[ "$worktree_tree" = "$expected_tree" ] || \
		fail "$label extracted worktree tree differs: $worktree_tree"
	git -C "$destination" update-ref --no-deref HEAD "$commit"
	unexpected=$(GIT_NO_LAZY_FETCH=1 git -C "$destination" status \
		--porcelain --untracked-files=all --ignored=matching)
	[ -z "$unexpected" ] || \
		fail "$label extracted worktree contains tracked, untracked, or ignored residue: $unexpected"
	git -C "$destination" config sbe.archiveSha256 "$(sha256_file "$archive_path")"
	git -C "$destination" config sbe.materializedTree "$expected_tree"
}

clone_locked() {
	label=$1
	url=$2
	mirror_url=$3
	proxy_url=$4
	cn_mirror_url=$5
	commit=$6
	expected_tree=$7
	destination=$8

	if [ -e "$destination" ] && [ ! -d "$destination/.git" ]; then
		fail "$label destination exists but is not a Git checkout: $destination"
	fi

	if [ ! -d "$destination/.git" ]; then
		mkdir -p "$(dirname -- "$destination")"
		printf 'Initialising %-14s %s\n' "$label" "$destination"
		git init -q "$destination"
		git -C "$destination" remote add origin "$url"
	fi

	actual_url=$(git -C "$destination" remote get-url origin)
	[ "$actual_url" = "$url" ] || fail "$label origin differs: $actual_url"
	# Source archives must hash to the upstream Git tree byte-for-byte even on
	# macOS hosts whose global Git config uses core.autocrlf=input.
	git -C "$destination" config core.autocrlf false
	if git -C "$destination" remote get-url mirror >/dev/null 2>&1; then
		git -C "$destination" remote set-url mirror "$mirror_url"
	else
		git -C "$destination" remote add mirror "$mirror_url"
	fi
	if git -C "$destination" remote get-url proxy >/dev/null 2>&1; then
		git -C "$destination" remote set-url proxy "$proxy_url"
	else
		git -C "$destination" remote add proxy "$proxy_url"
	fi
	if [ -n "$cn_mirror_url" ]; then
		if git -C "$destination" remote get-url cnmirror >/dev/null 2>&1; then
			git -C "$destination" remote set-url cnmirror "$cn_mirror_url"
		else
			git -C "$destination" remote add cnmirror "$cn_mirror_url"
		fi
	fi

	if ! git -C "$destination" cat-file -e "$commit^{commit}" 2>/dev/null; then
		fetched=0
		remote_order="proxy mirror origin"
		[ -z "$cn_mirror_url" ] || remote_order="cnmirror $remote_order"
		for remote in $remote_order; do
			attempt=1
			while [ "$attempt" -le 3 ]; do
				printf 'Fetching locked %-11s %s via %s (attempt %s/3)\n' \
					"$label" "$commit" "$remote" "$attempt"
				if git -c http.version=HTTP/1.1 -C "$destination" fetch \
					--no-tags --filter=blob:none --depth 1 "$remote" "$commit"
				then
					fetched=1
					git -C "$destination" config sbe.transportRemote "$remote"
					break
				fi
				attempt=$((attempt + 1))
			sleep 2
			done
			[ "$fetched" -eq 0 ] || break
		done
		[ "$fetched" -eq 1 ] || \
			fail "$label mirror and canonical origin did not provide locked commit $commit"
	fi
	actual_tree=$(git -C "$destination" rev-parse "$commit^{tree}")
	[ "$actual_tree" = "$expected_tree" ] || \
		fail "$label tree differs after transport fetch: $actual_tree"

	git -C "$destination" update-ref refs/sbe/locked "$commit"
	if [ "$metadata_only" = 1 ]; then
		git -C "$destination" config sbe.metadataOnly true
	else
		current_head=$(git -C "$destination" rev-parse HEAD 2>/dev/null || true)
		current_metadata=$(git -C "$destination" config --bool --get \
			sbe.metadataOnly 2>/dev/null || true)
		if [ "$current_head" != "$commit" ] || [ "$current_metadata" != false ]; then
			materialize_locked_archive "$label" "$url" "$mirror_url" "$proxy_url" \
				"$cn_mirror_url" "$commit" "$expected_tree" "$destination"
		fi
		git -C "$destination" config sbe.metadataOnly false
	fi
}

mkdir -p "$source_root"
case_probe=$source_root/.sbe-case-sensitive-probe.$$
mkdir "$case_probe"
mkdir "$case_probe/lower"
if ! mkdir "$case_probe/LOWER" 2>/dev/null; then
	rmdir "$case_probe/lower" "$case_probe"
	fail "$source_root is case-insensitive; QSDK Linux has 13 case-colliding tracked path pairs"
fi
rmdir "$case_probe/LOWER" "$case_probe/lower" "$case_probe"

clone_locked OpenWrt "$QSDK_OPENWRT_URL" "$QSDK_OPENWRT_MIRROR_URL" \
	"$QSDK_OPENWRT_PROXY_URL" "$QSDK_OPENWRT_CN_MIRROR_URL" \
	"$QSDK_OPENWRT_COMMIT" "$QSDK_OPENWRT_TREE" "$qsdk_dir"
clone_locked patches "$QSDK_PATCHES_URL" "$QSDK_PATCHES_MIRROR_URL" \
	"$QSDK_PATCHES_PROXY_URL" "$QSDK_PATCHES_CN_MIRROR_URL" \
	"$QSDK_PATCHES_COMMIT" "$QSDK_PATCHES_TREE" "$qsdk_dir/qsdk-package"
clone_locked kernel "$QSDK_KERNEL_URL" "$QSDK_KERNEL_MIRROR_URL" \
	"$QSDK_KERNEL_PROXY_URL" "$QSDK_KERNEL_CN_MIRROR_URL" \
	"$QSDK_KERNEL_COMMIT" "$QSDK_KERNEL_TREE" "$qsdk_dir/qca/src/linux-5.4"
clone_locked packages "$QSDK_PACKAGES_URL" "$QSDK_PACKAGES_MIRROR_URL" \
	"$QSDK_PACKAGES_PROXY_URL" "$QSDK_PACKAGES_CN_MIRROR_URL" \
	"$QSDK_PACKAGES_COMMIT" "$QSDK_PACKAGES_TREE" "$qsdk_dir/qca/feeds/packages"
clone_locked LuCI "$QSDK_LUCI_URL" "$QSDK_LUCI_MIRROR_URL" \
	"$QSDK_LUCI_PROXY_URL" "$QSDK_LUCI_CN_MIRROR_URL" \
	"$QSDK_LUCI_COMMIT" "$QSDK_LUCI_TREE" "$qsdk_dir/qca/feeds/luci"
clone_locked configs "$QSDK_CONFIGS_URL" "$QSDK_CONFIGS_MIRROR_URL" \
	"$QSDK_CONFIGS_PROXY_URL" "$QSDK_CONFIGS_CN_MIRROR_URL" \
	"$QSDK_CONFIGS_COMMIT" "$QSDK_CONFIGS_TREE" "$qsdk_dir/qca/configs/qsdk"

manifest_dir=$source_root/release-manifest
manifest_path=$manifest_dir/$QSDK_MANIFEST_XML
mkdir -p "$manifest_dir"
if [ ! -f "$manifest_path" ]; then
	command -v curl >/dev/null 2>&1 || fail 'curl is required to fetch the release manifest'
	manifest_tmp=$manifest_path.part.$$
	manifest_api="https://git.codelinaro.org/api/v4/projects/clo%2Fqsdk%2Freleases%2Fmanifest%2Fqstak/repository/files/$QSDK_MANIFEST_XML/raw?ref=$QSDK_MANIFEST_TAG"
	curl --http1.1 -fL --retry 3 --retry-all-errors --connect-timeout 20 \
		"$manifest_api" -o "$manifest_tmp" || \
		fail "manifest download failed; partial file retained: $manifest_tmp"
	actual=$(sha256_file "$manifest_tmp")
	[ "$actual" = "$QSDK_MANIFEST_XML_SHA256" ] || \
		fail "manifest SHA-256 differs: $actual"
	mv "$manifest_tmp" "$manifest_path"
fi

QSDK_SOURCE_ROOT=$source_root "$lab_dir/verify-sources.sh"

printf '\nLocked public QSDK subset is ready at %s\n' "$source_root"
if [ "$metadata_only" = 1 ]; then
	printf 'Metadata-only mode was requested; run again without QSDK_METADATA_ONLY before building.\n'
else
	printf 'Build root: %s\n' "$qsdk_dir"
fi
