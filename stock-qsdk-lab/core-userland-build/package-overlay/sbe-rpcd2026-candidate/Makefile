include $(TOPDIR)/rules.mk

PKG_NAME:=sbe-rpcd2026-candidate
PKG_VERSION:=2026.07.19~e37ed9d8
PKG_RELEASE:=1

PKG_SOURCE:=rpcd-e37ed9d814699098eb7e26c8b33c054840782dfb.tar
PKG_SOURCE_URL:=https://git.openwrt.org/project/rpcd.git
PKG_HASH:=062cb796890f6d92627038c2eb973c4082276da08356d85e754e590531174e40
PKG_BUILD_DIR:=$(BUILD_DIR)/rpcd-e37ed9d814699098eb7e26c8b33c054840782dfb
PKG_BUILD_PARALLEL:=1
PKG_LICENSE:=ISC

include $(INCLUDE_DIR)/package.mk
include $(INCLUDE_DIR)/cmake.mk

define Package/sbe-rpcd2026/default
  SECTION:=utils
  CATEGORY:=Base system
  SOURCE:=$(PKG_SOURCE)
  TITLE:=SBE isolated rpcd 2026 candidate
  DEPENDS:=+sbe-rpcd2026-candidate +libubus +libubox
endef

define Package/sbe-rpcd2026-candidate
  SECTION:=utils
  CATEGORY:=Base system
  SOURCE:=$(PKG_SOURCE)
  TITLE:=SBE isolated rpcd 2026 candidate
  DEPENDS:=+libubus +libubox +libuci +libblobmsg-json +libjson-c
endef

define Package/sbe-rpcd2026-mod-file-candidate
  $(Package/sbe-rpcd2026/default)
  TITLE+= (file plugin)
endef

define Package/sbe-rpcd2026-mod-rpcsys-candidate
  $(Package/sbe-rpcd2026/default)
  TITLE+= (rpc-sys plugin without firmware-write methods)
endef

define Package/sbe-rpcd2026-mod-iwinfo-candidate
  $(Package/sbe-rpcd2026/default)
  TITLE+= (factory libiwinfo ABI plugin)
  DEPENDS+=+libiwinfo
endef

define Package/sbe-rpcd2026-candidate/description
 The daemon and file, rpc-sys and iwinfo modules are one locked rpcd commit.
 Compatibility patches retain the factory 19.07 ABIs, while rpc-sys firmware
 upgrade and factory-reset entry points remain compiled out.  No init policy
 or configuration is installed by this evaluation package.
endef

CMAKE_OPTIONS += \
	-DFILE_SUPPORT=ON \
	-DRPCSYS_SUPPORT=ON \
	-DIWINFO_SUPPORT=ON \
	-DUCODE_SUPPORT=OFF \
	-DSBE_FACTORY_IWINFO_ABI=ON \
	-DCMAKE_INSTALL_PREFIX=/usr

TARGET_CFLAGS += -fstack-protector-strong -D_FORTIFY_SOURCE=2 \
	-I$(SBE_STOCK_ABI_SYSROOT)/usr/include
TARGET_LDFLAGS += -L$(SBE_STOCK_ABI_SYSROOT)/usr/lib \
	-Wl,--gc-sections,--as-needed,-z,now,-z,relro,-z,noexecstack

define Package/sbe-rpcd2026-candidate/install
	$(INSTALL_DIR) $(1)/sbin $(1)/usr/share/rpcd/acl.d
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/rpcd $(1)/sbin/rpcd
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/unauthenticated.json \
		$(1)/usr/share/rpcd/acl.d/unauthenticated.json
endef

define Package/sbe-rpcd2026-mod-file-candidate/install
	$(INSTALL_DIR) $(1)/usr/lib/rpcd
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/file.so $(1)/usr/lib/rpcd/
endef

define Package/sbe-rpcd2026-mod-rpcsys-candidate/install
	$(INSTALL_DIR) $(1)/usr/lib/rpcd
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/rpcsys.so $(1)/usr/lib/rpcd/
endef

define Package/sbe-rpcd2026-mod-iwinfo-candidate/install
	$(INSTALL_DIR) $(1)/usr/lib/rpcd
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/iwinfo.so $(1)/usr/lib/rpcd/
endef

# The factory libiwinfo payload is hash-locked and supplied only through the
# link-only ABI sysroot.  Tell the legacy dependency scanner about that exact
# external runtime ABI without copying it into the shared QSDK staging tree.
define Package/sbe-rpcd2026-mod-iwinfo-candidate/extra_provides
	printf '%s\n' libiwinfo.so;
endef

$(eval $(call BuildPackage,sbe-rpcd2026-candidate))
$(eval $(call BuildPackage,sbe-rpcd2026-mod-file-candidate))
$(eval $(call BuildPackage,sbe-rpcd2026-mod-rpcsys-candidate))
$(eval $(call BuildPackage,sbe-rpcd2026-mod-iwinfo-candidate))
