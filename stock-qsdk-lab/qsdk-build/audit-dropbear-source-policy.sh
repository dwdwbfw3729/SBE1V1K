#!/bin/sh
set -eu

source_dir=${1:?usage: audit-dropbear-source-policy.sh DROPBEAR_SOURCE DROPBEAR_COMPILE_POLICY}
compiled_policy=${2:?usage: audit-dropbear-source-policy.sh DROPBEAR_SOURCE DROPBEAR_COMPILE_POLICY}

fail() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

[ -f "$source_dir/src/sysoptions.h" ] || fail 'Dropbear sysoptions.h is missing'
[ -f "$source_dir/src/default_options.h" ] || fail 'Dropbear default_options.h is missing'
[ -f "$compiled_policy" ] || fail 'compiled policy is missing'
grep -F '#define DROPBEAR_VERSION "2026.94"' "$source_dir/src/sysoptions.h" >/dev/null || \
	fail 'source is not Dropbear 2026.94'

check_policy() {
	macro=$1
	expected=$2
	grep -Eq "^[[:space:]]*#define[[:space:]]+$macro[[:space:]]" \
		"$source_dir/src/default_options.h" || \
		fail "$macro is not defined by upstream 2026.94"
	actual=$(sed -n "s/^$macro=//p" "$compiled_policy")
	[ "$actual" = "$expected" ] || \
		fail "$macro compiled as $actual instead of $expected"
	printf 'PASS: %s=%s is an upstream option and final preprocessed value\n' \
		"$macro" "$actual"
}

check_guard() {
	macro=$1
	file=$2
	grep -F "$macro" "$source_dir/$file" >/dev/null || \
		fail "$file does not use $macro"
	printf 'PASS: %s gates %s\n' "$macro" "$file"
}

check_policy DROPBEAR_SVR_PASSWORD_AUTH 1
check_policy DROPBEAR_SVR_PAM_AUTH 0
check_policy DROPBEAR_SVR_PUBKEY_AUTH 1
check_policy DROPBEAR_SVR_LOCALTCPFWD 1
check_policy DROPBEAR_SVR_REMOTETCPFWD 1
check_policy DROPBEAR_SVR_LOCALSTREAMFWD 1
check_policy DROPBEAR_SVR_REMOTESTREAMFWD 1
check_policy DROPBEAR_SVR_AGENTFWD 1
check_policy DROPBEAR_X11FWD 1
check_policy DROPBEAR_USE_PASSWORD_ENV 0
check_policy DROPBEAR_DSS 0
check_policy DROPBEAR_RSA_SHA1 0
check_policy DROPBEAR_ENABLE_CBC_MODE 0
check_policy DROPBEAR_SHA1_HMAC 0
check_policy DROPBEAR_SHA1_96_HMAC 0

# Verify that the real 2026.94 server dispatch/implementation files consume
# those exact names.  This prevents a plausible-looking but unused local macro
# from being accepted as a forwarding/authentication control.
check_guard DROPBEAR_SVR_PASSWORD_AUTH src/svr-authpasswd.c
check_guard DROPBEAR_SVR_PUBKEY_AUTH src/svr-authpubkey.c
check_guard DROPBEAR_SVR_LOCALTCPFWD src/svr-session.c
check_guard DROPBEAR_SVR_LOCALTCPFWD src/svr-tcpfwd.c
check_guard DROPBEAR_SVR_REMOTETCPFWD src/svr-forward.c
check_guard DROPBEAR_SVR_REMOTETCPFWD src/svr-tcpfwd.c
check_guard DROPBEAR_SVR_LOCALSTREAMFWD src/svr-session.c
check_guard DROPBEAR_SVR_LOCALSTREAMFWD src/svr-streamfwd.c
check_guard DROPBEAR_SVR_REMOTESTREAMFWD src/svr-forward.c
check_guard DROPBEAR_SVR_REMOTESTREAMFWD src/svr-streamfwd.c
check_guard DROPBEAR_SVR_AGENTFWD src/svr-chansession.c
check_guard DROPBEAR_SVR_AGENTFWD src/svr-agentfwd.c
check_guard DROPBEAR_X11FWD src/svr-chansession.c
check_guard DROPBEAR_X11FWD src/svr-x11fwd.c

for option in B a s g w; do
	grep -F "case '$option':" "$source_dir/src/svr-runopts.c" >/dev/null || \
		fail "server parser omits -$option"
done
grep -F 'svr_opts.allowblankpass = 0;' "$source_dir/src/svr-runopts.c" >/dev/null || \
	fail 'blank-password policy does not default off'
grep -F 'svr_opts.allowblankpass' "$source_dir/src/svr-auth.c" >/dev/null || \
	fail 'blank-password authentication does not consume allowblankpass'
printf 'PASS: -B/-a/-s/-g/-w parser cases exist and blank-password policy defaults off\n'
printf '\nPASS: Dropbear 2026.94 source/compiled-policy gate completed.\n'
