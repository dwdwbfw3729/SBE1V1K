include $(TOPDIR)/rules.mk

PKG_NAME:=sbe-htop353-candidate
PKG_VERSION:=3.5.3
PKG_RELEASE:=1

PKG_SOURCE:=htop-3.5.3.tar.xz
PKG_SOURCE_URL:=https://github.com/htop-dev/htop/releases/download/3.5.3
PKG_HASH:=a8b164386494cb85bb255a415a3f5f80afe7a0c4491da5d113b3a0f951087e65
PKG_BUILD_DIR:=$(BUILD_DIR)/htop-3.5.3

PKG_LICENSE:=GPL-2.0-or-later
PKG_LICENSE_FILES:=COPYING
PKG_FIXUP:=autoreconf
PKG_BUILD_PARALLEL:=1
PKG_INSTALL:=1

include $(INCLUDE_DIR)/package.mk

define Package/sbe-htop353-candidate
  SECTION:=admin
  CATEGORY:=Administration
  TITLE:=SBE htop 3.5.3 minimal candidate
  SOURCE:=htop-3.5.3.tar.xz
  DEPENDS:=+libncurses
endef

define Package/sbe-htop353-candidate/description
 Official htop 3.5.3, the latest stable release verified on 2026-09-14.
 Unicode and native Linux CPU-affinity support are retained.  Optional
 capabilities, delay accounting, sensors, hwloc, backtrace, demangling and
 PCP dependencies are deliberately disabled.
endef

TARGET_CFLAGS += -ffunction-sections -fdata-sections -fstack-protector-strong -D_FORTIFY_SOURCE=2
TARGET_LDFLAGS += -Wl,--gc-sections,--as-needed,-z,now,-z,relro,-z,noexecstack

CONFIGURE_ARGS += \
	--disable-static \
	--disable-pcp \
	--enable-unicode \
	--enable-affinity \
	--disable-backtrace \
	--with-libunwind=no \
	--disable-demangling \
	--disable-hwloc \
	--disable-capabilities \
	--disable-delayacct \
	--disable-sensors \
	--disable-werror \
	--disable-debug \
	--with-curses=ncursesw \
	--with-proc=/proc

CONFIGURE_VARS += \
	ac_cv_file__proc_stat=yes \
	ac_cv_file__proc_meminfo=yes \
	CURSES_CFLAGS= \
	CURSES_LIBS=-lncursesw

define Package/sbe-htop353-candidate/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(PKG_INSTALL_DIR)/usr/bin/htop $(1)/usr/bin/htop
endef

$(eval $(call BuildPackage,sbe-htop353-candidate))
