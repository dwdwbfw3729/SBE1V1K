include $(TOPDIR)/rules.mk

PKG_NAME:=sbe-dropbear2026-candidate
PKG_UPSTREAM_VERSION:=2026.94
PKG_VERSION:=$(PKG_UPSTREAM_VERSION)
PKG_RELEASE:=3

PKG_SOURCE:=dropbear-$(PKG_UPSTREAM_VERSION).tar.bz2
PKG_SOURCE_URL:=https://matt.ucc.asn.au/dropbear/releases/
PKG_HASH:=e098034a843699200c8c977a991fff73159735bf795d5f72ef672c41a6b1ae81
PKG_BUILD_DIR:=$(BUILD_DIR)/dropbear-$(PKG_UPSTREAM_VERSION)

PKG_LICENSE:=MIT
PKG_LICENSE_FILES:=LICENSE libtomcrypt/LICENSE libtommath/LICENSE
PKG_BUILD_PARALLEL:=1

include $(INCLUDE_DIR)/package.mk

define Package/sbe-dropbear2026-candidate
  SECTION:=utils
  CATEGORY:=Utilities
  SOURCE:=$(PKG_SOURCE)
  TITLE:=SBE1V1K isolated Dropbear 2026.94 ABI candidate
  URL:=https://matt.ucc.asn.au/dropbear/dropbear.html
endef

define Package/sbe-dropbear2026-candidate/description
 Isolated QSDK-toolchain build for RAM/chroot validation.  Password and public
 key authentication are compiled in, while a blank password is accepted only
 when the server is explicitly started with -B.  Standard server-side TCP,
 Unix-stream, agent and X11 forwarding are compiled in.  The package installs
 no init script, host key, authorized_keys file, password or other credential.
endef

CONFIGURE_ARGS += \
	--disable-pam \
	--enable-openpty \
	--enable-syslog \
	--disable-lastlog \
	--disable-utmp \
	--disable-utmpx \
	--disable-wtmp \
	--disable-wtmpx \
	--disable-loginfunc \
	--disable-pututline \
	--disable-pututxline \
	--disable-zlib \
	--enable-bundled-libtom

TARGET_CFLAGS += -DARGTYPE=3 -ffunction-sections -fdata-sections
TARGET_LDFLAGS += -Wl,--gc-sections

define Build/Configure
	printf '%s\n' \
		'#define DEFAULT_PATH "/usr/sbin:/usr/bin:/sbin:/bin"' \
		'#define DROPBEAR_SVR_PASSWORD_AUTH 1' \
		'#define DROPBEAR_SVR_PAM_AUTH 0' \
		'#define DROPBEAR_SVR_PUBKEY_AUTH 1' \
		'#define DROPBEAR_SVR_LOCALTCPFWD 1' \
		'#define DROPBEAR_SVR_REMOTETCPFWD 1' \
		'#define DROPBEAR_SVR_LOCALSTREAMFWD 1' \
		'#define DROPBEAR_SVR_REMOTESTREAMFWD 1' \
		'#define DROPBEAR_SVR_AGENTFWD 1' \
		'#define DROPBEAR_X11FWD 1' \
		'#define DROPBEAR_USE_PASSWORD_ENV 0' \
		'#define DROPBEAR_DSS 0' \
		'#define DROPBEAR_RSA_SHA1 0' \
		'#define DROPBEAR_ENABLE_CBC_MODE 0' \
		'#define DROPBEAR_SHA1_HMAC 0' \
		'#define DROPBEAR_SHA1_96_HMAC 0' \
		> $(PKG_BUILD_DIR)/localoptions.h
	$(Build/Configure/Default)
endef

define Build/Compile
	+$(MAKE) $(PKG_JOBS) -C $(PKG_BUILD_DIR) \
		$(TARGET_CONFIGURE_OPTS) \
		PROGRAMS="dropbear dbclient dropbearkey scp" MULTI=1 SCPPROGRESS=1
endef

define Package/sbe-dropbear2026-candidate/install
	$(INSTALL_DIR) $(1)/usr/libexec/sbe-qsdk-lab/dropbear-2026.94
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/dropbearmulti \
		$(1)/usr/libexec/sbe-qsdk-lab/dropbear-2026.94/dropbear
	$(LN) dropbear $(1)/usr/libexec/sbe-qsdk-lab/dropbear-2026.94/dbclient
	$(LN) dropbear $(1)/usr/libexec/sbe-qsdk-lab/dropbear-2026.94/dropbearkey
	$(LN) dropbear $(1)/usr/libexec/sbe-qsdk-lab/dropbear-2026.94/scp
endef

$(eval $(call BuildPackage,sbe-dropbear2026-candidate))
