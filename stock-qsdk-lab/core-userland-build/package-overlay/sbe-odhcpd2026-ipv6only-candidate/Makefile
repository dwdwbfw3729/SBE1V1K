include $(TOPDIR)/rules.mk

PKG_NAME:=sbe-odhcpd2026-ipv6only-candidate
PKG_VERSION:=2026.06.28~68f38269
PKG_RELEASE:=1

PKG_SOURCE:=odhcpd-68f382690bfaec56d5b1f31c3c31c48bcb642e3a.tar
PKG_SOURCE_URL:=https://git.openwrt.org/project/odhcpd.git
PKG_HASH:=8556be09c596a0e73b414e94bdca453d45cdc1acd7359c21175ce16cdcc033c0
PKG_BUILD_DIR:=$(BUILD_DIR)/odhcpd-68f382690bfaec56d5b1f31c3c31c48bcb642e3a
PKG_BUILD_PARALLEL:=1
PKG_LICENSE:=GPL-2.0-only

include $(INCLUDE_DIR)/package.mk
include $(INCLUDE_DIR)/cmake.mk

define Package/sbe-odhcpd2026-ipv6only-candidate
  SECTION:=net
  CATEGORY:=Network
  SOURCE:=$(PKG_SOURCE)
  TITLE:=SBE isolated odhcpd IPv6-only 2026 candidate
  DEPENDS:=@IPV6 +libubox +libuci +libubus +libnl-tiny +libjson-c
endef

define Package/sbe-odhcpd2026-ipv6only-candidate/description
 IPv6 RA, DHCPv6-PD and NDP-only candidate.  DHCPv4 is compiled out and no
 init policy or configuration is installed.  PD/RA/NDP stays blocked on the
 RAM-only hardware gate even after host and chroot tests pass.
endef

CMAKE_OPTIONS += -DUBUS=1 -DDHCPV4_SUPPORT=0
TARGET_CFLAGS += -fstack-protector-strong -D_FORTIFY_SOURCE=2
TARGET_LDFLAGS += -Wl,--gc-sections,--as-needed,-z,now,-z,relro,-z,noexecstack

define Package/sbe-odhcpd2026-ipv6only-candidate/install
	$(INSTALL_DIR) $(1)/usr/sbin
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/odhcpd $(1)/usr/sbin/
endef

$(eval $(call BuildPackage,sbe-odhcpd2026-ipv6only-candidate))
