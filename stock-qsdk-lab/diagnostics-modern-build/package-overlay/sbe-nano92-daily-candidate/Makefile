include $(TOPDIR)/rules.mk

PKG_NAME:=sbe-nano92-daily-candidate
PKG_VERSION:=9.2
PKG_RELEASE:=1

PKG_SOURCE:=nano-9.2.tar.xz
PKG_SOURCE_URL:=https://www.nano-editor.org/dist/v9
PKG_HASH:=05ecb99247b782e8a5b3a25ed4101dd034b0236902f7449bc9795b717642f7e9
PKG_BUILD_DIR:=$(BUILD_DIR)/nano-9.2

PKG_LICENSE:=GPL-3.0-or-later
PKG_LICENSE_FILES:=COPYING
PKG_BUILD_PARALLEL:=1
PKG_INSTALL:=1

include $(INCLUDE_DIR)/package.mk

define Package/sbe-nano92-daily-candidate
  SECTION:=utils
  CATEGORY:=Utilities
  SUBMENU:=Editors
  TITLE:=SBE GNU nano 9.2 daily-use candidate
  SOURCE:=nano-9.2.tar.xz
  DEPENDS:=+libncurses
endef

define Package/sbe-nano92-daily-candidate/description
 Official GNU nano 9.2 with a practical router-console feature set.  UTF-8,
 help, multiple buffers, file browser, nanorc, color, mouse and completion are
 retained.  External formatter, linter and speller execution is disabled.
endef

TARGET_CFLAGS += -ffunction-sections -fdata-sections -fstack-protector-strong -D_FORTIFY_SOURCE=2
TARGET_LDFLAGS += -Wl,--gc-sections,--as-needed,-z,now,-z,relro,-z,noexecstack

CONFIGURE_ARGS += \
	--disable-nls \
	--enable-utf8 \
	--enable-help \
	--enable-linenumbers \
	--enable-browser \
	--enable-color \
	--enable-comment \
	--enable-justify \
	--enable-mouse \
	--enable-multibuffer \
	--enable-nanorc \
	--enable-operatingdir \
	--enable-tabcomp \
	--enable-wordcomp \
	--enable-wrapping \
	--disable-extra \
	--disable-formatter \
	--disable-histories \
	--disable-libmagic \
	--disable-linter \
	--disable-speller \
	--disable-debug

CONFIGURE_VARS += \
	ac_cv_header_regex_h=no \
	NCURSESW_CFLAGS= \
	NCURSESW_LIBS=-lncursesw

define Package/sbe-nano92-daily-candidate/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(PKG_INSTALL_DIR)/usr/bin/nano $(1)/usr/bin/nano
endef

$(eval $(call BuildPackage,sbe-nano92-daily-candidate))
