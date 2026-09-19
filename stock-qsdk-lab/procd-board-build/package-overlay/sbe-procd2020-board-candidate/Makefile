include $(TOPDIR)/rules.mk

PKG_NAME:=sbe-procd2020-board-candidate
PKG_VERSION:=2020.03.07~09b9bd82
PKG_RELEASE:=1

PKG_SOURCE:=procd-09b9bd828981a4f9271f8906f7b6f5af04e1a6f9.tar
PKG_SOURCE_URL:=https://git.openwrt.org/project/procd.git
PKG_HASH:=28c383e9179ae364e609d537befa19dae54444fe8af49f84a9765bba4585bd60
PKG_BUILD_DIR:=$(BUILD_DIR)/procd-09b9bd828981a4f9271f8906f7b6f5af04e1a6f9
PKG_BUILD_PARALLEL:=1
CMAKE_INSTALL:=1

PKG_LICENSE:=LGPL-2.1-only
PKG_LICENSE_FILES:=

include $(INCLUDE_DIR)/package.mk
include $(INCLUDE_DIR)/cmake.mk

define Package/sbe-procd2020-board-candidate
  SECTION:=base
  CATEGORY:=Base system
  SOURCE:=$(PKG_SOURCE)
  TITLE:=QSDK procd AArch64 board-info candidate
  DEPENDS:=+ubusd +ubus +libjson-script +ubox +libubox +libubus +libblobmsg-json +libjson-c
endef

define Package/sbe-procd2020-board-candidate/description
 Exact QSDK SPF12.2 procd baseline with the two QSDK runtime patches and the
 official OpenWrt AArch64 system.board compatibility backport.  The payload
 also includes the ABI-matched ujail required by modern service init scripts;
 stock init and unrelated helper binaries stay untouched.
endef

CMAKE_OPTIONS += \
	-DEARLY_PATH="/usr/sbin:/usr/bin:/sbin:/bin" \
	-DJAIL_SUPPORT=1 \
	-DSECCOMP_SUPPORT=0

# Match the QSDK procd recipe. The selected QSDK build configuration supplies
# its normal PIE, stack-protector, FORTIFY and full-RELRO policy globally.
TARGET_CFLAGS += -flto
TARGET_LDFLAGS += -flto

define Package/sbe-procd2020-board-candidate/install
	$(INSTALL_DIR) $(1)/sbin
	$(INSTALL_BIN) $(PKG_INSTALL_DIR)/usr/sbin/procd $(1)/sbin/procd
	$(INSTALL_BIN) $(PKG_INSTALL_DIR)/usr/sbin/ujail $(1)/sbin/ujail
endef

$(eval $(call BuildPackage,sbe-procd2020-board-candidate))
