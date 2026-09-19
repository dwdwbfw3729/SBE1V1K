include $(TOPDIR)/rules.mk

PKG_NAME:=sbe-ntfs3g2026-candidate
PKG_VERSION:=2026.7.7
PKG_RELEASE:=1

PKG_SOURCE:=ntfs-3g_ntfsprogs-$(PKG_VERSION).tgz
PKG_SOURCE_URL:=https://download.tuxera.com/opensource
PKG_HASH:=d67b769025d32860549d35c2147e45024d172f81c540d750390ce3602c059dab
PKG_BUILD_DIR:=$(BUILD_DIR)/ntfs-3g-$(PKG_VERSION)

PKG_LICENSE:=GPL-2.0-only LGPL-2.1-or-later
PKG_LICENSE_FILES:=COPYING COPYING.LIB
PKG_CPE_ID:=cpe:/a:tuxera:ntfs-3g
PKG_FIXUP:=autoreconf
PKG_INSTALL:=1
PKG_BUILD_PARALLEL:=1

include $(INCLUDE_DIR)/package.mk

define Package/sbe-ntfs3g2026-candidate
  SECTION:=utils
  CATEGORY:=Utilities
  SOURCE:=$(PKG_SOURCE)
  SUBMENU:=Filesystem
  TITLE:=SBE RAM-test candidate for NTFS-3G 2026.7.7
  DEPENDS:=+kmod-fuse +libpthread
endef

define Package/sbe-ntfs3g2026-candidate/description
 This package is a non-release replacement-binary candidate using the bundled
 FUSE-lite userland and the factory Linux 5.4.213 fuse.ko ABI.
endef

CONFIGURE_ARGS += \
	--enable-shared \
	--disable-static \
	--disable-ldconfig \
	--disable-mtab \
	--disable-plugins \
	--disable-crypto \
	--disable-ntfsprogs \
	--disable-extras \
	--with-fuse=internal

TARGET_CFLAGS += -fstack-protector-strong -D_FORTIFY_SOURCE=2
TARGET_LDFLAGS += -Wl,-z,now,-z,relro,-z,noexecstack

define Build/Prepare
	rm -rf $(PKG_BUILD_DIR)
	mkdir -p $(PKG_BUILD_DIR)
	$(TAR) -xzf $(DL_DIR)/$(PKG_SOURCE) -C $(PKG_BUILD_DIR) --strip 1
	$(Build/Patch)
endef

define Package/sbe-ntfs3g2026-candidate/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(PKG_INSTALL_DIR)/usr/bin/ntfs-3g $(1)/usr/bin/
	$(INSTALL_BIN) $(PKG_INSTALL_DIR)/usr/bin/ntfs-3g.probe $(1)/usr/bin/
	$(INSTALL_DIR) $(1)/usr/lib
	$(CP) $(PKG_INSTALL_DIR)/usr/lib/libntfs-3g.so.* $(1)/usr/lib/
	$(INSTALL_DIR) $(1)/sbin
	$(LN) ../usr/bin/ntfs-3g $(1)/sbin/mount.ntfs-3g
	$(LN) ../usr/bin/ntfs-3g $(1)/sbin/mount.ntfs
endef

$(eval $(call BuildPackage,sbe-ntfs3g2026-candidate))
