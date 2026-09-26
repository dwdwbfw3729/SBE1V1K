include $(TOPDIR)/rules.mk

PKG_NAME:=sbe-lucihttp2023-security-candidate
PKG_VERSION:=2023.03.15~9b5b683f
PKG_RELEASE:=1

PKG_SOURCE:=lucihttp-2023-03-15-9b5b683f.tar.xz
PKG_SOURCE_URL:=https://github.com/jow-/lucihttp.git
PKG_HASH:=82698fcf1ac47b14ea44b26eccfb11596b6eda4e9f68d016405ebd8a66dc816e
PKG_BUILD_DIR:=$(BUILD_DIR)/lucihttp-2023-03-15-9b5b683f
PKG_BUILD_PARALLEL:=1
PKG_INSTALL:=1
PKG_CONFIG_DEPENDS:=CONFIG_PACKAGE_sbe-liblucihttp-lua2023-abi0-candidate

PKG_LICENSE:=ISC
PKG_LICENSE_FILES:=LICENSE

include $(INCLUDE_DIR)/package.mk
include $(INCLUDE_DIR)/cmake.mk

define Package/sbe-liblucihttp2023-abi0-candidate
  SECTION:=libs
  CATEGORY:=Libraries
  SOURCE:=$(PKG_SOURCE)
  TITLE:=SBE LuCI HTTP ABI 0 security candidate
endef

define Package/sbe-liblucihttp2023-abi0-candidate/description
 Exact OpenWrt 2023 LuCI HTTP utility library rebuilt against the locked
 QSDK musl toolchain.  It retains SONAME liblucihttp.so.0 and is eligible
 only for an exact-path RAM replacement after ABI and parser tests pass.
endef

define Package/sbe-liblucihttp-lua2023-abi0-candidate
  SECTION:=libs
  CATEGORY:=Libraries
  SOURCE:=$(PKG_SOURCE)
  TITLE:=SBE LuCI HTTP Lua 5.1 binding candidate
  DEPENDS:=+sbe-liblucihttp2023-abi0-candidate +liblua
endef

define Package/sbe-liblucihttp-lua2023-abi0-candidate/description
 Lua 5.1 binding built from the same locked source as the ABI 0 core library.
 It must be promoted atomically with the core library in the RAM-only profile.
endef

TARGET_CFLAGS += -I$(STAGING_DIR)/usr/include -fstack-protector-strong -D_FORTIFY_SOURCE=2
TARGET_LDFLAGS += -Wl,--gc-sections,--as-needed,-z,now,-z,relro,-z,noexecstack

CMAKE_OPTIONS = \
	-DLUAPATH=/usr/lib/lua \
	-DBUILD_LUA=ON \
	-DBUILD_UCODE=OFF \
	-DBUILD_TESTS=OFF

define Build/InstallDev
	$(INSTALL_DIR) $(1)/usr/lib
	$(INSTALL_DIR) $(1)/usr/include
	$(CP) $(PKG_INSTALL_DIR)/usr/lib/liblucihttp.so* $(1)/usr/lib/
	$(CP) $(PKG_INSTALL_DIR)/usr/include/* $(1)/usr/include/
endef

define Package/sbe-liblucihttp2023-abi0-candidate/install
	$(INSTALL_DIR) $(1)/usr/lib
	$(CP) $(PKG_INSTALL_DIR)/usr/lib/liblucihttp.so.* $(1)/usr/lib/
endef

define Package/sbe-liblucihttp-lua2023-abi0-candidate/install
	$(INSTALL_DIR) $(1)/usr/lib/lua
	$(CP) $(PKG_INSTALL_DIR)/usr/lib/lua/lucihttp.so $(1)/usr/lib/lua/
endef

$(eval $(call BuildPackage,sbe-liblucihttp2023-abi0-candidate))
$(eval $(call BuildPackage,sbe-liblucihttp-lua2023-abi0-candidate))
