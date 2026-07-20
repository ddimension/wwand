# OpenWrt package for the wwand native transport module.

include $(TOPDIR)/rules.mk

PKG_NAME:=ucode-mod-wwand-io
PKG_RELEASE:=1

PKG_LICENSE:=GPL-2.0
PKG_MAINTAINER:=

include $(INCLUDE_DIR)/package.mk
include $(INCLUDE_DIR)/cmake.mk

define Package/ucode-mod-wwand-io
  SECTION:=lang
  CATEGORY:=Languages
  SUBMENU:=ucode
  TITLE:=Message-oriented cdc-wdm/tty I/O module for wwand
  DEPENDS:=+libucode
endef

define Package/ucode-mod-wwand-io/description
  Minimal native ucode extension providing non-blocking, message-oriented
  I/O on QMI control devices (/dev/cdc-wdmX) and raw tty access for AT
  commands. Used by the wwand connection manager.
endef

define Package/ucode-mod-wwand-io/install
	$(INSTALL_DIR) $(1)/usr/lib/ucode
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/wwand_io.so $(1)/usr/lib/ucode/
endef

$(eval $(call BuildPackage,ucode-mod-wwand-io))
