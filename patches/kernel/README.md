# Kernel patches wwand benefits from

These are NOT applied by any wwand package — a package cannot patch the kernel.
They live here so they survive a `make dirclean` of a build tree and so the
reasoning is reviewable in one place. Drop them into the OpenWrt tree by hand:

    cp patches/kernel/969-*.patch \
       <openwrt>/target/linux/mediatek/patches-6.18/

## 969 — declare DUN on the generic Qualcomm MHI profile

Gives a PCIe/MHI modem its AT port. `mhi_wwan_ctrl` maps the MHI `DUN` channel
to `WWAN_PORT_AT`, i.e. `/dev/wwanXat0`, but the generic Qualcomm entry in
`mhi-pci-generic` does not declare that channel — so a module matching only
that entry has no AT port at all, and with it no vendor AT commands, no
protocol switch and no AT telemetry. Every vendor profile for these modems
declares DUN 32/33; the generic one does not.

Scoped to the mediatek target on purpose. MHI has no capability exchange —
`mhi_create_devices()` walks the HOST-declared channel list — so a device that
genuinely lacks DUN would get a port node that cannot be opened. Making this
safe everywhere means teaching `mhi_wwan_ctrl` not to publish a port whose
channel the device refuses to start; that is the shape an upstream submission
should take, as a pair:

1. `mhi_wwan_ctrl`: decline the probe when `mhi_prepare_for_transfer()` fails,
   instead of creating a port that errors on open.
2. `pci_generic`: add DUN to `modem_qcom_v1_mhi_channels`, now that
   over-declaring is self-correcting.

Note that ID-based scoping is NOT available for the hardware this was written
for: a Quectel RM520N-GL that reports 17cb:0308 with subsystem 17cb:0308 and no
vendor subsystem, and whose `AT+QCFG=?` offers no setting for the PCI identity.

wwand does not depend on this patch — `atcmd_mbim.uc` reaches AT over the MBIM
channel instead where the modem supports it. The patch is the better answer
where it applies, because a real port is full duplex and carries URCs.
