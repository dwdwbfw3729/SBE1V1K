#!/bin/sh
# Public entry point.  Detailed component recipes stay private to the build tool.
set -eu
lab=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
builder="$lab/tools/build_release.py"

usage() {
	cat <<'EOF'
Usage:
  ./stock-qsdk-lab/build.sh                 Build the production image
  ./stock-qsdk-lab/build.sh release [opts]  Same as above
  ./stock-qsdk-lab/build.sh base [opts]     Build the minimal image
  ./stock-qsdk-lab/build.sh sources         Download/verify locked sources
  ./stock-qsdk-lab/build.sh check           Verify cached build inputs
  ./stock-qsdk-lab/build.sh plan            Show component status
  ./stock-qsdk-lab/build.sh component NAME  Rebuild one component

Common options: --output DIR, --jobs N, --vendor-simg FILE,
                --initramfs FILE --initramfs-sums FILE
EOF
}

command=${1:-release}
case "$command" in
	release)
		[ "$#" -eq 0 ] || shift
		exec python3 "$builder" --profile production "$@"
		;;
	base)
		shift
		exec python3 "$builder" --profile base "$@"
		;;
	sources)
		shift
		exec python3 "$lab/tools/init_dependencies.py" "$@"
		;;
	check)
		shift
		exec python3 "$builder" --check "$@"
		;;
	plan)
		shift
		exec python3 "$builder" --plan "$@"
		;;
	component)
		shift
		[ "$#" -ge 1 ] || { usage >&2; exit 2; }
		stage=$1
		shift
		exec python3 "$builder" --stage "$stage" --rebuild "$@"
		;;
	-h|--help|help)
		usage
		;;
	--*)
		# Backward-compatible access to the old low-level flags.
		exec python3 "$builder" "$@"
		;;
	*)
		printf 'Unknown build command: %s\n\n' "$command" >&2
		usage >&2
		exit 2
		;;
esac
