include $(TOPDIR)/rules.mk

PKG_NAME:=sbe-ubus2022-security-candidate
PKG_VERSION:=2022.02.21+sec2026.05.23
PKG_RELEASE:=1

PKG_SOURCE:=ubus-2022-02-21-b32a0e17.tar.xz
PKG_SOURCE_URL:=https://git.openwrt.org/project/ubus.git
PKG_HASH:=fddf17b1faeb2ab09a3bed2e301a9cc83cb6ceb69af57cd58dc2132b58276f8b
PKG_BUILD_DIR:=$(BUILD_DIR)/ubus-2022-02-21-b32a0e17
PKG_ABI_VERSION:=20210603
PKG_BUILD_PARALLEL:=1
PKG_INSTALL:=1

PKG_LICENSE:=LGPL-2.1
PKG_LICENSE_FILES:=

include $(INCLUDE_DIR)/package.mk
include $(INCLUDE_DIR)/cmake.mk

define Package/sbe-ubus2022-security/default
  SECTION:=base
  CATEGORY:=Base system
  SOURCE:=$(PKG_SOURCE)
  TITLE:=SBE ABI-preserving ubus security candidate
endef

define Package/sbe-ubus2022-security-candidate
  $(Package/sbe-ubus2022-security/default)
  DEPENDS:=+libubus +libubox +libblobmsg-json
  TITLE+= (client)
endef

define Package/sbe-ubusd2022-security-candidate
  $(Package/sbe-ubus2022-security/default)
  DEPENDS:=+libubox +libblobmsg-json +libjson-c
  TITLE+= (daemon)
endef

define Package/sbe-libubus20210603-security-candidate
  $(Package/sbe-ubus2022-security/default)
  DEPENDS:=+libubox
  TITLE+= (libubus.so.20210603)
endef

define Package/sbe-libubus-lua2022-comparison-only
  $(Package/sbe-ubus2022-security/default)
  DEPENDS:=+libubus +liblua
  TITLE+= (Lua 5.1 ABI comparison only)
endef

define Package/sbe-ubus2022-security-candidate/description
 The factory 2022 ubus ABI rebuilt with the reviewed daemon and client
 memory, file-descriptor and lifetime fixes through 2026-05-23. The package
 contains no configuration, credential, init policy or firmware-writing
 operation.
endef

CMAKE_OPTIONS += \
	-DABIVERSION="$(PKG_ABI_VERSION)" \
	-DBUILD_LUA=ON \
	-DBUILD_EXAMPLES=OFF \
	-DUNIT_TESTING=OFF \
	-DLUAPATH=/usr/lib/lua

TARGET_CFLAGS += -fstack-protector-strong -D_FORTIFY_SOURCE=2
TARGET_LDFLAGS += -Wl,--gc-sections,--as-needed,-z,now,-z,relro,-z,noexecstack

define Package/sbe-ubus2022-security-candidate/install
	$(INSTALL_DIR) $(1)/bin
	$(INSTALL_BIN) $(PKG_INSTALL_DIR)/usr/bin/ubus $(1)/bin/
endef

define Package/sbe-ubusd2022-security-candidate/install
	$(INSTALL_DIR) $(1)/sbin
	$(INSTALL_BIN) $(PKG_INSTALL_DIR)/usr/sbin/ubusd $(1)/sbin/
endef

define Package/sbe-libubus20210603-security-candidate/install
	$(INSTALL_DIR) $(1)/lib
	$(CP) $(PKG_INSTALL_DIR)/usr/lib/libubus.so.$(PKG_ABI_VERSION) $(1)/lib/
endef

define Package/sbe-libubus-lua2022-comparison-only/install
	$(INSTALL_DIR) $(1)/usr/lib/lua
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/lua/ubus.so $(1)/usr/lib/lua/
endef

$(eval $(call BuildPackage,sbe-ubus2022-security-candidate))
$(eval $(call BuildPackage,sbe-ubusd2022-security-candidate))
$(eval $(call BuildPackage,sbe-libubus20210603-security-candidate))
$(eval $(call BuildPackage,sbe-libubus-lua2022-comparison-only))
