include $(TOPDIR)/rules.mk

PKG_NAME:=sbe-dnsmasq293-candidate
PKG_UPSTREAM_VERSION:=2.93
PKG_VERSION:=$(PKG_UPSTREAM_VERSION)
PKG_RELEASE:=1

PKG_SOURCE:=dnsmasq-$(PKG_UPSTREAM_VERSION).tar.xz
PKG_SOURCE_URL:=https://thekelleys.org.uk/dnsmasq
PKG_HASH:=0c00d4e5c97c8306e5fb932b348b34269c9c29a0e7df0e8e82958b407092bc19
PKG_BUILD_DIR:=$(BUILD_DIR)/dnsmasq-$(PKG_UPSTREAM_VERSION)

PKG_LICENSE:=GPL-2.0-or-later
PKG_LICENSE_FILES:=COPYING COPYING-v3
PKG_BUILD_PARALLEL:=1
PKG_INSTALL:=1

include $(INCLUDE_DIR)/package.mk

define Package/sbe-dnsmasq293-candidate
  SECTION:=utils
  CATEGORY:=Utilities
  SOURCE:=$(PKG_SOURCE)
  TITLE:=SBE1V1K isolated dnsmasq 2.93 ABI candidate
  URL:=https://thekelleys.org.uk/dnsmasq/doc.html
  DEPENDS:=@IPV6 +libubox +libubus +libnetfilter-conntrack +kmod-ipt-ipset
endef

define Package/sbe-dnsmasq293-candidate/description
 Isolated QSDK-toolchain build for RAM/chroot validation.  It does not provide
 dnsmasq, install an init script, or replace the factory service.
endef

TARGET_CFLAGS += -ffunction-sections -fdata-sections
TARGET_LDFLAGS += -Wl,--gc-sections

# DHCPv4, DHCPv6, RA, TFTP, auth and ipset are upstream defaults in 2.93.
# Keep DNSSEC out of the first candidate because the stock image has no nettle.
COPTS := -DHAVE_UBUS -DHAVE_CONNTRACK -DNO_ID -DNO_DNSSEC -DNO_NFTSET

MAKE_FLAGS := \
	$(TARGET_CONFIGURE_OPTS) \
	CFLAGS="$(TARGET_CFLAGS) $(TARGET_CPPFLAGS)" \
	LDFLAGS="$(TARGET_LDFLAGS)" \
	COPTS="$(COPTS)" \
	PREFIX="/usr"

define Package/sbe-dnsmasq293-candidate/install
	$(INSTALL_DIR) $(1)/usr/libexec/sbe-qsdk-lab
	$(INSTALL_BIN) $(PKG_INSTALL_DIR)/usr/sbin/dnsmasq \
		$(1)/usr/libexec/sbe-qsdk-lab/dnsmasq-2.93
endef

$(eval $(call BuildPackage,sbe-dnsmasq293-candidate))
