#
# LuCI status page for the wwand modem daemon.
# Adds Status → Modem: a live signal / cell-environment view, useful for
# antenna alignment (peak-hold on RSRP/SINR).
#

include $(TOPDIR)/rules.mk

LUCI_TITLE:=Modem status page for wwand (signal / cell alignment)
LUCI_DEPENDS:=+wwand
LUCI_PKGARCH:=all

PKG_LICENSE:=GPL-2.0-only
PKG_MAINTAINER:=

include ../../luci.mk

# call BuildPackage - OpenWrt buildroot signature
