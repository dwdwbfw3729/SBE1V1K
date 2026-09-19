include $(TOPDIR)/rules.mk

PKG_NAME:=sbe-miniupnpd2311-candidate
PKG_VERSION:=2.3.11
PKG_RELEASE:=1

PKG_SOURCE:=miniupnpd-$(PKG_VERSION).tar.gz
PKG_SOURCE_URL:=https://github.com/miniupnp/miniupnp/releases/download/miniupnpd_$(subst .,_,$(PKG_VERSION))
PKG_HASH:=91994b127da735b2c97f19992e34420648c0e8c4ace8a4bcb0596e7685c48678
PKG_BUILD_DIR:=$(BUILD_DIR)/miniupnpd-$(PKG_VERSION)

PKG_LICENSE:=BSD-3-Clause
PKG_LICENSE_FILES:=LICENSE
PKG_CPE_ID:=cpe:/a:miniupnp_project:miniupnpd
PKG_INSTALL:=1
PKG_BUILD_PARALLEL:=1

include $(INCLUDE_DIR)/package.mk
include $(INCLUDE_DIR)/version.mk

define Package/sbe-miniupnpd2311-candidate
  SECTION:=net
  CATEGORY:=Network
  SOURCE:=$(PKG_SOURCE)
  TITLE:=SBE RAM-test candidate for MiniUPnPd 2.3.11
  DEPENDS:=+iptables +libip4tc +IPV6:libip6tc +IPV6:ip6tables +libuuid +libcap \
	+libmnl +libnfnetlink +libnetfilter-conntrack
endef

define Package/sbe-miniupnpd2311-candidate/description
 This package is a non-release replacement-binary candidate for the factory
 iptables ABI.  It must not enter an image until the SBE target gates pass.
endef

define Build/Prepare
	$(call Build/Prepare/Default)
	echo "$(VERSION_NUMBER)" | tr '() ' '_' >$(PKG_BUILD_DIR)/os.openwrt
endef

CONFIGURE_ARGS = \
	$(if $(CONFIG_IPV6),--ipv6) \
	--igd2 \
	--leasefile \
	--portinuse \
	--regex \
	--vendorcfg \
	--disable-pppconn \
	--disable-fork \
	--disable-tests \
	--firewall=iptables

TARGET_CFLAGS += $(FPIC) -fstack-protector-strong -D_FORTIFY_SOURCE=2
TARGET_LDFLAGS += -Wl,--gc-sections,--as-needed,-z,now,-z,relro,-z,noexecstack

define Package/sbe-miniupnpd2311-candidate/install
	$(INSTALL_DIR) $(1)/usr/sbin
	$(INSTALL_BIN) $(PKG_INSTALL_DIR)/usr/sbin/miniupnpd $(1)/usr/sbin/miniupnpd
endef

$(eval $(call BuildPackage,sbe-miniupnpd2311-candidate))
