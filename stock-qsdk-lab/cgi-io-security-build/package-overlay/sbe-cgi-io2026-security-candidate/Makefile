include $(TOPDIR)/rules.mk

PKG_NAME:=sbe-cgi-io2026-security-candidate
PKG_VERSION:=2026.07.21~31cb3c89
PKG_RELEASE:=1

PKG_SOURCE:=cgi-io-31cb3c89f02d918d7f17bf62a80c852fc38a1ca1.tar
PKG_SOURCE_URL:=https://git.openwrt.org/project/cgi-io.git
PKG_HASH:=d4a5fa9ef499a62714d718ad4efb374d8161016f833ea36d7555fc6e11b98da6
PKG_BUILD_DIR:=$(BUILD_DIR)/cgi-io-31cb3c89f02d918d7f17bf62a80c852fc38a1ca1
PKG_BUILD_PARALLEL:=1

PKG_LICENSE:=GPL-2.0-or-later
PKG_LICENSE_FILES:=

include $(INCLUDE_DIR)/package.mk
include $(INCLUDE_DIR)/cmake.mk

define Package/sbe-cgi-io2026-security-candidate
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=Web Servers/Proxies
  SOURCE:=$(PKG_SOURCE)
  TITLE:=SBE cgi-io 2026 security candidate
  DEPENDS:=+libubox +libubus
endef

define Package/sbe-cgi-io2026-security-candidate/description
 Current cgi-io with canonical-path ACL checks and fail-closed malformed POST
 decoding.  The candidate supplies only the executable; the reviewed LuCI CGI
 links and ACL policy remain owned by the base image until RAM validation.
endef

CMAKE_OPTIONS += -DUNIT_TESTING=OFF
TARGET_CFLAGS += -fstack-protector-strong -D_FORTIFY_SOURCE=2
TARGET_LDFLAGS += -Wl,--gc-sections,--as-needed,-z,now,-z,relro,-z,noexecstack

define Package/sbe-cgi-io2026-security-candidate/install
	$(INSTALL_DIR) $(1)/usr/libexec
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/cgi-io $(1)/usr/libexec/cgi-io
endef

$(eval $(call BuildPackage,sbe-cgi-io2026-security-candidate))
