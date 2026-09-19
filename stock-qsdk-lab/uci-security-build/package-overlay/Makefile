# Locked replacement for QSDK package/system/uci.  Only the libuci package is
# selected by the build gate; uci and libuci-lua remain unselected test/build
# by-products and are not release artifacts from this directory.

include $(TOPDIR)/rules.mk

PKG_NAME:=uci
PKG_RELEASE:=5

PKG_SOURCE_URL=$(PROJECT_GIT)/project/uci.git
PKG_SOURCE_PROTO:=git
PKG_SOURCE_DATE=2019-09-01
PKG_SOURCE_VERSION:=415f9e48436d29f612348f58f546b3ad8d74ac38
PKG_MIRROR_HASH:=06f2801b103c359129c1675cbe5045c2cd04d756c2ab1efd2160608f34a27a8f

PKG_LICENSE:=LGPL-2.1
PKG_LICENSE_FILES:=
PKG_MAINTAINER:=Felix Fietkau <nbd@nbd.name>
PKG_BUILD_PARALLEL:=0

include $(INCLUDE_DIR)/package.mk
include $(INCLUDE_DIR)/cmake.mk

DEBUG=

define Package/libuci
  SECTION:=libs
  CATEGORY:=Libraries
  TITLE:=C library for the Unified Configuration Interface (UCI)
  DEPENDS:=+libubox
  ABI_VERSION:=20130104
endef

define Package/uci
  SECTION:=base
  CATEGORY:=Base system
  DEPENDS:=+libuci
  TITLE:=Utility for the Unified Configuration Interface (UCI)
endef

define Package/libuci-lua
  SECTION=libs
  CATEGORY=Libraries
  DEPENDS:=+libuci +liblua
  TITLE:=Lua plugin for UCI
endef

TARGET_CFLAGS += -I$(STAGING_DIR)/usr/include
TARGET_LDFLAGS += -L$(STAGING_DIR)/usr/lib

CMAKE_OPTIONS = \
	-DLUAPATH=/usr/lib/lua \
	$(if $(DEBUG),-DUCI_DEBUG=ON)

define Package/libuci/install
	$(INSTALL_DIR) $(1)/lib
	$(CP) $(PKG_BUILD_DIR)/libuci.so* $(1)/lib/
endef

define Package/libuci-lua/install
	$(INSTALL_DIR) $(1)/usr/lib/lua
	$(CP) $(PKG_BUILD_DIR)/lua/uci.so $(1)/usr/lib/lua/
endef

# This definition is retained so the compile target still builds the exact
# upstream CLI used by the loader smoke test.  CONFIG_PACKAGE_uci is unset, so
# this install stanza is never packaged by the candidate gate.
define Package/uci/install
	$(INSTALL_DIR) $(1)/sbin
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/uci $(1)/sbin/
endef

define Build/InstallDev
	$(INSTALL_DIR) $(1)/usr/include
	$(CP) $(PKG_BUILD_DIR)/uci{,_config,_blob,map}.h $(1)/usr/include
	$(INSTALL_DIR) $(1)/usr/lib
	$(CP) $(PKG_BUILD_DIR)/libuci.so* $(1)/usr/lib
	$(CP) $(PKG_BUILD_DIR)/libucimap.a $(1)/usr/lib
endef

$(eval $(call BuildPackage,uci))
$(eval $(call BuildPackage,libuci))
$(eval $(call BuildPackage,libuci-lua))
