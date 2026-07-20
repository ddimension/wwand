# OpenWrt package for the wwand connection manager.

include $(TOPDIR)/rules.mk

PKG_NAME:=wwand
PKG_RELEASE:=1

PKG_LICENSE:=GPL-2.0
PKG_MAINTAINER:=

include $(INCLUDE_DIR)/package.mk

define Package/wwand
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=WWAN
  TITLE:=Event-driven QMI connection manager
  DEPENDS:=+ucode +ucode-mod-fs +ucode-mod-struct +ucode-mod-uloop \
	+ucode-mod-ubus +ucode-mod-uci +ucode-mod-rtnl +ucode-mod-wwand-io \
	+kmod-usb-net-qmi-wwan
  CONFLICTS:=qmi-advanced uqmi
endef

define Package/wwand/description
  wwand is an event-driven connection manager daemon for QMI modems,
  supporting multiple modems and multiple parallel PDP contexts via QMAP
  multiplexing (rmnet and qmimux backends). It replaces the bash-based
  qmi-advanced package. Implemented in ucode; talks QMI natively over
  /dev/cdc-wdmX without spawning uqmi/qmicli.
endef

define Build/Configure
endef

define Build/Compile
endef

define Package/wwand/install
	$(INSTALL_DIR) $(1)/usr/share/ucode/wwand/codec/schema
	$(INSTALL_DATA) ./src-ucode/*.uc $(1)/usr/share/ucode/wwand/
	$(INSTALL_DATA) ./src-ucode/codec/*.uc $(1)/usr/share/ucode/wwand/codec/
	$(INSTALL_DATA) ./src-ucode/codec/schema/*.uc $(1)/usr/share/ucode/wwand/codec/schema/
	$(INSTALL_DIR) $(1)/usr/sbin
	$(INSTALL_BIN) ./src-ucode/main.uc $(1)/usr/sbin/wwand
	rm -f $(1)/usr/share/ucode/wwand/main.uc
	$(INSTALL_DIR) $(1)/lib/netifd/proto
	$(INSTALL_BIN) ./files/wwand-proto.sh $(1)/lib/netifd/proto/qmi.sh
	$(INSTALL_DIR) $(1)/usr/libexec/wwand
	$(INSTALL_BIN) ./files/wwand-context-monitor $(1)/usr/libexec/wwand/context-monitor
	$(INSTALL_BIN) ./files/wwand-migrate $(1)/usr/libexec/wwand/migrate
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/wwand.init $(1)/etc/init.d/wwand
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/wwand.config $(1)/etc/config/wwand
	$(INSTALL_DIR) $(1)/etc/hotplug.d/usbmisc
	$(INSTALL_DATA) ./files/wwand.hotplug $(1)/etc/hotplug.d/usbmisc/20-wwand
endef

define Package/wwand/conffiles
/etc/config/wwand
endef

$(eval $(call BuildPackage,wwand))
