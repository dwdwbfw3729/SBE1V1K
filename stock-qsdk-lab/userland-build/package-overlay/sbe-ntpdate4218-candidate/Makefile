include $(TOPDIR)/rules.mk

PKG_NAME:=sbe-ntpdate4218-candidate
PKG_VERSION:=4.2.8p18
PKG_RELEASE:=2

PKG_SOURCE:=ntp-$(PKG_VERSION).tar.gz
PKG_SOURCE_URL:=https://downloads.nwtime.org/ntp
PKG_HASH:=cf84c5f3fb1a295284942624d823fffa634144e096cfc4f9969ac98ef5f468e5
PKG_BUILD_DIR:=$(BUILD_DIR)/ntp-$(PKG_VERSION)

PKG_LICENSE:=NTP
PKG_LICENSE_FILES:=COPYRIGHT html/copyright.html
PKG_CPE_ID:=cpe:/a:ntp:ntp
# The signed release tarball already carries generated configure/Makefile.in
# files.  Re-running autoreconf makes the result depend on the host Automake
# minor version and can trigger an unwanted automake-1.16 rebuild during make.
PKG_LIBTOOL_PATHS:=. sntp
PKG_CHECK_FORMAT_SECURITY:=0
PKG_BUILD_PARALLEL:=1

include $(INCLUDE_DIR)/package.mk

define Package/sbe-ntpdate4218-candidate
  SUBMENU:=Time Synchronization
  SECTION:=net
  CATEGORY:=Network
  SOURCE:=$(PKG_SOURCE)
  TITLE:=SBE RAM-test candidate for ntpdate 4.2.8p18
  DEPENDS:=+libpthread +libcap
endef

define Package/sbe-ntpdate4218-candidate/description
 Isolated QSDK ABI candidate for the local SBE time policy.  It installs no
 init script and deliberately omits unused NTP authentication/OpenSSL support.
endef

CONFIGURE_VARS += \
	ac_cv_header_md5_h=no \
	ac_cv_lib_rt_sched_setscheduler=no \
	ac_cv_header_dns_sd_h=no \
	hw_cv_func_snprintf_c99=yes \
	hw_cv_func_vsnprintf_c99=yes

CONFIGURE_ARGS += \
	--disable-all-clocks \
	--disable-parse-clocks \
	--without-ntpsnmpd \
	--without-lineeditlibs \
	--disable-saveconfig \
	--enable-linuxcaps \
	--with-yielding-select=yes \
	--without-crypto

TARGET_CFLAGS += -fstack-protector-strong -D_FORTIFY_SOURCE=2
TARGET_LDFLAGS += -Wl,-z,now,-z,relro,-z,noexecstack

define Package/sbe-ntpdate4218-candidate/install
	$(INSTALL_DIR) $(1)/usr/libexec/sbe-qsdk-lab
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/ntpdate/ntpdate \
		$(1)/usr/libexec/sbe-qsdk-lab/ntpdate-4.2.8p18
endef

$(eval $(call BuildPackage,sbe-ntpdate4218-candidate))
