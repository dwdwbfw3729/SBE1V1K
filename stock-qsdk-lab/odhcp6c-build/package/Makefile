include $(TOPDIR)/rules.mk

PKG_NAME:=odhcp6c
PKG_VERSION:=2024-09-25-b6ae9ffa
PKG_RELEASE:=1-sbe1
PKG_LICENSE:=GPL-2.0
PKG_BUILD_DIR:=$(BUILD_DIR)/odhcp6c-$(PKG_VERSION)-sbe
PKG_BUILD_PARALLEL:=1

include $(INCLUDE_DIR)/package.mk
include $(INCLUDE_DIR)/cmake.mk

define Package/odhcp6c
  SECTION:=net
  CATEGORY:=Network
  TITLE:=OpenWrt DHCPv6 client with QSDK netifd integration
  SOURCE:=https://github.com/openwrt/odhcp6c/tree/b6ae9ffaeb0e18e9fa3d5be62faa8d3c9f340a58
  DEPENDS:=@IPV6 +libubox
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
	$(TAR) -xf /candidate/work/source.tar -C $(PKG_BUILD_DIR)
endef

CMAKE_OPTIONS += -DUSE_LIBUBOX=on -DEXT_CER_ID=0
TARGET_CFLAGS += -fstack-protector-strong -D_FORTIFY_SOURCE=2
TARGET_LDFLAGS += -Wl,-z,now,-z,relro,-z,noexecstack

define Package/odhcp6c/install
	$(INSTALL_DIR) $(1)/usr/sbin $(1)/lib/netifd/proto
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/odhcp6c $(1)/usr/sbin/
	$(INSTALL_BIN) /candidate/work/hooks/dhcpv6.sh $(1)/lib/netifd/proto/
	$(INSTALL_BIN) /candidate/work/hooks/dhcpv6.script $(1)/lib/netifd/
endef

$(eval $(call BuildPackage,odhcp6c))
