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
	$(INSTALL_DIR) $(1)/usr/share/ucode/wwand/codec/mbim-schema
	$(INSTALL_DATA) ./src-ucode/*.uc $(1)/usr/share/ucode/wwand/
	$(INSTALL_DATA) ./src-ucode/codec/*.uc $(1)/usr/share/ucode/wwand/codec/
	$(INSTALL_DATA) ./src-ucode/codec/schema/*.uc $(1)/usr/share/ucode/wwand/codec/schema/
	# daemon.uc imports the MBIM modules at top level, so the MBIM schema must
	# ship too, otherwise the daemon fails to compile modem_mbim.uc/context_mbim.uc
	$(INSTALL_DATA) ./src-ucode/codec/mbim-schema/*.uc $(1)/usr/share/ucode/wwand/codec/mbim-schema/
	$(INSTALL_DIR) $(1)/usr/sbin
	$(INSTALL_BIN) ./src-ucode/main.uc $(1)/usr/sbin/wwand
	rm -f $(1)/usr/share/ucode/wwand/main.uc
	# esim.uc ships in the optional wwand-esim package
	rm -f $(1)/usr/share/ucode/wwand/esim.uc
	$(INSTALL_DIR) $(1)/lib/netifd/proto
	$(INSTALL_BIN) ./files/wwand-proto.sh $(1)/lib/netifd/proto/qmi.sh
	$(INSTALL_DIR) $(1)/usr/libexec/wwand
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

define Package/wwand-esim
  SECTION:=net
  CATEGORY:=Network
  TITLE:=eSIM (eUICC) profile management for wwand
  # lpac drives the SM-DP+ download/notification (ES9+ HTTPS on the router)
  # via the wwand APDU channel; jsonfilter is used by the glue script
  DEPENDS:=+wwand +lpac +jsonfilter
endef

define Package/wwand-esim/description
 Optional ES10c (SGP.22) profile management for wwand: EID, profile list,
 enable/disable/delete over the modem UIM APDU channel. SM-DP+ profile
 downloads and notification acknowledgements run lpac's AT driver on a free
 AT port (wwand keeps its own); the ES9+ HTTPS runs on the router, no
 dedicated modem APN is required.

 Two build requirements for the download (verified on the RG650E):
  * lpac's at driver must set the tty to raw mode — see
    wwand/patches-lpac/100-at-driver-termios.patch (drop into the lpac feed's
    patches/ dir). Without it the at driver hangs.
  * libcurl MUST be built with OpenSSL, not mbedtls. OpenWrt's mbedtls is
    feature-stripped and fails the GSMA SM-DP+ TLS with X509 feature
    unavailable; OpenSSL has the full curve/algorithm set.
endef

define Package/wwand-esim/install
	$(INSTALL_DIR) $(1)/usr/share/ucode/wwand
	$(INSTALL_DATA) ./src-ucode/esim.uc $(1)/usr/share/ucode/wwand/
	$(INSTALL_DIR) $(1)/usr/libexec/wwand
	$(INSTALL_BIN) ./files/wwand-esim-download $(1)/usr/libexec/wwand/esim-download
endef

$(eval $(call BuildPackage,wwand))
$(eval $(call BuildPackage,wwand-esim))
