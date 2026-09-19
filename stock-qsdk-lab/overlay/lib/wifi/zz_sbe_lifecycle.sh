# SBE1V1K local radio lifecycle driver.
#
# /sbin/wifi sources every /lib/wifi/*.sh file and calls each registered
# driver's pre/post hooks around QSDK radio operations.  Registering a small
# hook driver avoids editing Qualcomm's qcawificfg80211.sh and keeps the
# original lock, module, NSS and SMP-affinity paths intact.

append DRIVERS "sbe_lifecycle"

normalize_mbssid_for_reload() {
	if ! /usr/sbin/sbe-mbssid-policy normalize >/dev/null 2>&1; then
		logger -t sbe-mbssid-policy \
			'reload normalization failed; continuing wireless lifecycle' \
			2>/dev/null || true
	fi
	return 0
}

apply_missing_wireless_defaults() {
	/etc/init.d/sbe-wireless-policy apply >/dev/null 2>&1 || {
		logger -t sbe-wireless-policy \
			'failed to apply missing defaults; continuing wireless lifecycle' \
			2>/dev/null || true
	}
	return 0
}

pre_sbe_lifecycle() {
	case "$1" in
		disable)
			# These argument positions come from the stock /sbin/wifi reload and
			# reload_legacy dispatchers.  Ordinary down/up never normalizes UCI.
			if [ "${3:-}" = wifi_reload ] || [ "${4:-}" = reload_legacy ]; then
				apply_missing_wireless_defaults
				normalize_mbssid_for_reload
			fi
			/usr/sbin/sbe-wifi-lifecycle save-nol >/dev/null 2>&1 || true
		;;
		disable_recover)
			/usr/sbin/sbe-wifi-lifecycle save-nol >/dev/null 2>&1 || true
		;;
		enable|enable_recover)
			# QSDK reads UCI after entering this hook.  Seed only missing values
			# here so a LuCI Enable action cannot race the factory detector.
			apply_missing_wireless_defaults
			/usr/sbin/sbe-wifi-lifecycle restore-nol >/dev/null 2>&1 || true
		;;
	esac
	return 0
}

post_sbe_lifecycle() {
	case "$1" in
		enable|enable_recover)
			/usr/sbin/sbe-wifi-lifecycle apply-radio-policy >/dev/null 2>&1 || true
		;;
	esac
	return 0
}

# /sbin/wifi iterates every registered driver for these operations.  The SBE
# hook owns no radio modules or configuration output, so its remaining entry
# points are deliberate no-ops rather than noisy "not supported" failures.
detect_sbe_lifecycle() { return 0; }
load_sbe_lifecycle() { return 0; }
unload_sbe_lifecycle() { return 0; }
trap_sbe_lifecycle() { return 0; }
