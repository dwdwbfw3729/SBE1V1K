include $(TOPDIR)/rules.mk

PKG_NAME:=sbe-rpcd-mod-rrdns20170710-modern-candidate
PKG_VERSION:=20170710~luci22e4e765
PKG_RELEASE:=1

PKG_SOURCE:=rpcd-mod-rrdns-22e4e76524046e21bb57b7595dda658bd41313a4.tar
PKG_SOURCE_URL:=https://git.openwrt.org/project/luci.git
PKG_HASH:=6695c7ce165437505900cd77bf837a0e951692571da1ab3bec7836c59b7b0f75
PKG_BUILD_DIR:=$(BUILD_DIR)/luci-22e4e76524046e21bb57b7595dda658bd41313a4
PKG_BUILD_PARALLEL:=1
CMAKE_SOURCE_SUBDIR:=libs/rpcd-mod-rrdns/src

PKG_LICENSE:=Apache-2.0
PKG_LICENSE_FILES:=

include $(INCLUDE_DIR)/package.mk
include $(INCLUDE_DIR)/cmake.mk

define Package/sbe-rpcd-mod-rrdns20170710-modern-candidate
  SECTION:=libs
  CATEGORY:=Libraries
  TITLE:=SBE current OpenWrt rapid reverse DNS rpcd module candidate
  SOURCE:=$(PKG_SOURCE)
  DEPENDS:=+rpcd +libubox +libubus
endef

define Package/sbe-rpcd-mod-rrdns20170710-modern-candidate/description
 Current official OpenWrt rpcd-mod-rrdns runtime source at the locked LuCI
 commit.  The 20170710 upstream package version remains current; this isolated
 candidate is evaluation-only and does not install or expand any rpcd ACL.
endef

TARGET_CFLAGS += -fstack-protector-strong -D_FORTIFY_SOURCE=2
TARGET_LDFLAGS += -Wl,--gc-sections,--as-needed,-z,now,-z,relro,-z,noexecstack

define Build/Prepare
	$(call Build/Prepare/Default)
	$(CP) ./files/rpcd-plugin-abi.h $(PKG_BUILD_DIR)/$(CMAKE_SOURCE_SUBDIR)/rpcd-plugin-abi.h
endef

define Package/sbe-rpcd-mod-rrdns20170710-modern-candidate/install
	$(INSTALL_DIR) $(1)/usr/lib/rpcd
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/rrdns.so $(1)/usr/lib/rpcd/rrdns.so
endef

define Package/sbe-rpcd-mod-rrdns20170710-modern-candidate/postinst
#!/bin/sh
[ -n "$$IPKG_INSTROOT" ] || /etc/init.d/rpcd reload
endef

$(eval $(call BuildPackage,sbe-rpcd-mod-rrdns20170710-modern-candidate))
