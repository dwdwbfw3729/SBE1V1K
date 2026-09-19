include $(TOPDIR)/rules.mk

PKG_NAME:=sbe-ppp254-candidate
PKG_VERSION:=2.5.4~dev20260910
PKG_RELEASE:=1

PKG_SOURCE:=ppp-2587a678e61e94b6366f1a3be020644668a97000.tar
PKG_SOURCE_URL:=https://github.com/ppp-project/ppp.git
PKG_HASH:=48cf073e1635d59a99bfaf28b820da672b649cf8405def81133f6df16f16a843
PKG_BUILD_DIR:=$(BUILD_DIR)/ppp-2587a678e61e94b6366f1a3be020644668a97000
PKG_FIXUP:=autoreconf
PKG_INSTALL:=1
PKG_BUILD_PARALLEL:=1
PKG_LICENSE:=BSD-4-Clause
PKG_LICENSE_FILES:=LICENSE.BSD

include $(INCLUDE_DIR)/package.mk

define Package/sbe-ppp254-candidate
  SECTION:=net
  CATEGORY:=Network
  SOURCE:=$(PKG_SOURCE)
  TITLE:=SBE isolated pppd 2.5.4-dev candidate
  DEPENDS:=+kmod-ppp
endef

define Package/sbe-ppp254-mod-pppoe-candidate
  SECTION:=net
  CATEGORY:=Network
  SOURCE:=$(PKG_SOURCE)
  TITLE:=SBE matching rp-pppoe plugin candidate
  DEPENDS:=+sbe-ppp254-candidate +kmod-pppoe
endef

define Package/sbe-ppp254-candidate/description
 Locked post-v2.5.3 pppd.  The build contains core PAP/CHAP, IPv4/IPv6 and
 loadable-plugin support only; its sole built plugin is the matching upstream
 rp-pppoe module.  RADIUS, PPTP, L2TP, ATM, EAP-TLS, PEAP, Microsoft extensions,
 PAM, CBCP and multilink are absent.  No secrets or network policy are packaged.
endef

CONFIGURE_ARGS += \
	--disable-static \
	--disable-systemd \
	--disable-cbcp \
	--disable-microsoft-extensions \
	--enable-ipv6cp \
	--disable-multilink \
	--enable-plugins \
	--disable-eaptls \
	--disable-peap \
	--disable-openssl-engine \
	--without-openssl \
	--without-pam \
	--without-atm \
	--without-pcap \
	--with-plugin-dir=/usr/lib/pppd/2.5.4 \
	--with-runtime-dir=/var/run/pppd \
	--with-logfile-dir=/var/log/ppp \
	--without-system-ca-path

TARGET_CFLAGS += -ffunction-sections -fdata-sections -fstack-protector-strong -D_FORTIFY_SOURCE=2
TARGET_LDFLAGS += -Wl,--gc-sections,--as-needed,-z,now,-z,relro,-z,noexecstack

define Package/sbe-ppp254-candidate/install
	$(INSTALL_DIR) $(1)/usr/sbin
	$(INSTALL_BIN) $(PKG_INSTALL_DIR)/usr/sbin/pppd $(1)/usr/sbin/
endef

define Package/sbe-ppp254-mod-pppoe-candidate/install
	$(INSTALL_DIR) $(1)/usr/lib/pppd/2.5.4
	$(INSTALL_BIN) $(PKG_INSTALL_DIR)/usr/lib/pppd/2.5.4/pppoe.so \
		$(1)/usr/lib/pppd/2.5.4/rp-pppoe.so
endef

$(eval $(call BuildPackage,sbe-ppp254-candidate))
$(eval $(call BuildPackage,sbe-ppp254-mod-pppoe-candidate))
