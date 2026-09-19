include $(TOPDIR)/rules.mk

PKG_NAME:=sbe-uhttpd2026-candidate
PKG_VERSION:=2026.08.24~373145f7
PKG_RELEASE:=1

PKG_SOURCE:=uhttpd-373145f72c884c36a2b16f7f47e74ffae06bd754.tar
PKG_SOURCE_URL:=https://git.openwrt.org/project/uhttpd.git
PKG_HASH:=d8ceafa807d2ff4e8177bf5b850e415bff1ddfc9ea6f794c596b32fe6c4ecc59
PKG_BUILD_DIR:=$(BUILD_DIR)/uhttpd-373145f72c884c36a2b16f7f47e74ffae06bd754
PKG_BUILD_PARALLEL:=1
PKG_LICENSE:=ISC

include $(INCLUDE_DIR)/package.mk
include $(INCLUDE_DIR)/cmake.mk

define Package/sbe-uhttpd2026/default
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=Web Servers/Proxies
  SOURCE:=$(PKG_SOURCE)
  TITLE:=SBE isolated uhttpd 2026 candidate
endef

define Package/sbe-uhttpd2026-candidate
  $(Package/sbe-uhttpd2026/default)
  DEPENDS:=+libubox +libblobmsg-json +libjson-script +libjson-c +libustream-openssl
endef

define Package/sbe-uhttpd2026-mod-ubus-candidate
  $(Package/sbe-uhttpd2026/default)
  TITLE+= (ubus plugin)
  DEPENDS:=+sbe-uhttpd2026-candidate +libubus +libubox +libblobmsg-json +libjson-c
endef

define Package/sbe-uhttpd2026-candidate/description
 TLS- and CGI-capable uhttpd built from the locked OpenWrt commit.  Lua and
 ucode are deliberately absent.  This evaluation package installs no init
 policy, configuration, certificate, key or other credential.
endef

CMAKE_OPTIONS += \
	-DTLS_SUPPORT=ON \
	-DUBUS_SUPPORT=ON \
	-DLUA_SUPPORT=OFF \
	-DUCODE_SUPPORT=OFF

TARGET_CFLAGS += -fstack-protector-strong -D_FORTIFY_SOURCE=2 \
	-DSBE_USTREAM_SSL_ABI_20150806 \
	-I$(SBE_STOCK_ABI_SYSROOT)/usr/include
TARGET_LDFLAGS += -L$(SBE_STOCK_ABI_SYSROOT)/lib \
	-Wl,--gc-sections,--as-needed,-z,now,-z,relro,-z,noexecstack

define Package/sbe-uhttpd2026-candidate/install
	$(INSTALL_DIR) $(1)/usr/sbin
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/uhttpd $(1)/usr/sbin/uhttpd
endef

define Package/sbe-uhttpd2026-mod-ubus-candidate/install
	$(INSTALL_DIR) $(1)/usr/lib
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/uhttpd_ubus.so $(1)/usr/lib/
endef

$(eval $(call BuildPackage,sbe-uhttpd2026-candidate))
$(eval $(call BuildPackage,sbe-uhttpd2026-mod-ubus-candidate))
