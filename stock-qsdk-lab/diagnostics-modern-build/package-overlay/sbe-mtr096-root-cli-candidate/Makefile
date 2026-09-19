include $(TOPDIR)/rules.mk

PKG_NAME:=sbe-mtr096-root-cli-candidate
PKG_VERSION:=0.96
PKG_RELEASE:=1

PKG_SOURCE:=mtr-0.96.tar.gz
PKG_SOURCE_URL:=https://www.bitwizard.nl/mtr/files
PKG_HASH:=ffd19a9f8d5f616c1ea2f0da9fbf9d1239bcecdf5a68912e831966d20929037a
PKG_BUILD_DIR:=$(BUILD_DIR)/mtr-0.96

PKG_LICENSE:=GPL-2.0-or-later
PKG_LICENSE_FILES:=COPYING
PKG_BUILD_PARALLEL:=1
PKG_BUILD_FLAGS:=gc-sections

include $(INCLUDE_DIR)/package.mk

define Package/sbe-mtr096-root-cli-candidate
  SECTION:=net
  CATEGORY:=Network
  TITLE:=SBE mtr 0.96 root-only CLI candidate
  SOURCE:=mtr-0.96.tar.gz
  DEPENDS:=+libncurses
endef

define Package/sbe-mtr096-root-cli-candidate/description
 Official mtr v0.96 release archive matched against the locked release tag.
 This evaluation package has no GTK, JSON or external IP-information lookup
 support.  Both executables are mode 0700: mtr-packet receives neither setuid
 nor file capabilities.
endef

TARGET_CFLAGS += -ffunction-sections -fdata-sections -fstack-protector-strong -D_FORTIFY_SOURCE=2
TARGET_LDFLAGS += -Wl,--gc-sections,--as-needed,-z,now,-z,relro,-z,noexecstack

CONFIGURE_ARGS += \
	--without-gtk \
	--without-jansson \
	--without-ipinfo \
	--with-ncursesw \
	--with-ncurses \
	--enable-ipv6 \
	--disable-braille \
	--disable-bash-completion

CONFIGURE_VARS += ac_cv_lib_cap_cap_set_proc=no

# Intentionally do not set PKG_INSTALL.  Upstream's install-exec-hook invokes
# setcap and falls back to setuid; copying the just-built binaries bypasses it.
define Package/sbe-mtr096-root-cli-candidate/install
	$(INSTALL_DIR) $(1)/usr/sbin
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/mtr $(1)/usr/sbin/mtr
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/mtr-packet $(1)/usr/sbin/mtr-packet
	chmod 0700 $(1)/usr/sbin/mtr $(1)/usr/sbin/mtr-packet
endef

$(eval $(call BuildPackage,sbe-mtr096-root-cli-candidate))
