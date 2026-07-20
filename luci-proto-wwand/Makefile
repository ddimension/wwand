#
# LuCI network-manager protocol handler for the wwand modem daemon.
# Registers the 'qmi' protocol UI (replaces luci-proto-qmi — both install
# the same protocol/qmi.js path, so only one can be installed).
#

include $(TOPDIR)/rules.mk

LUCI_TITLE:=Support for QMI/5G cellular modems (wwand)
LUCI_DEPENDS:=+wwand

PKG_LICENSE:=GPL-2.0-only
PKG_MAINTAINER:=

include ../../luci.mk

# call BuildPackage - OpenWrt buildroot signature
