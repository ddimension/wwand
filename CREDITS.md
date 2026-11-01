<!-- SPDX-License-Identifier: GPL-2.0-only -->

# Credits

wwand is shaped by the people who run it on hardware the maintainer does not
have, read its code, and take the time to write down what they saw. Thank
you — many fixes in this tree exist because someone reported, tested or
argued for them.

Listed by GitHub account, across the wwand repositories (wwand,
luci-app-wwand, luci-proto-wwand, wwand-lpac, openwrt-repo and the plugin
repos) and the upstream submissions openwrt/packages#30185 and
openwrt/luci#8917. Bots are left out. Missing, or listed wrongly? Open an
issue or a pull request against this file.

## Code

Pull requests — merged, taken in another form, or still under review; each one
moved the code.

- **[@xhudan](https://github.com/xhudan)**
  - [wwand#46](https://github.com/ddimension/wwand/issues/46) Add a QMI-over-QRTR transport for PCIe/MHI modems
  - [wwand#53](https://github.com/ddimension/wwand/issues/53) context: stop re-attempting IPv6 once a carrier refuses it
  - [wwand#56](https://github.com/ddimension/wwand/issues/56) telemetry: retire a QMI-context AT+QENG that never answers
  - [wwand#60](https://github.com/ddimension/wwand/issues/60) telemetry: give up polling a wholly-dead AT telemetry channel
  - [wwand#64](https://github.com/ddimension/wwand/issues/64) qmi_over_qrtr: bound the per-wakeup socket drain
  - [wwand#65](https://github.com/ddimension/wwand/issues/65) modem: fall back to a modem reset when zero-rx has no repower
  - reported: [wwand#59](https://github.com/ddimension/wwand/issues/59), [wwand#61](https://github.com/ddimension/wwand/issues/61)
- **[@MayorBug](https://github.com/MayorBug)**
  - [openwrt-repo#1](https://github.com/ddimension/openwrt-repo/issues/1) Update Quectel PCIe MHI to 1.6.0 and add NSS support
  - [wwand#49](https://github.com/ddimension/wwand/issues/49) Support vendor Quectel MHI discovery and datapath restarts
  - [wwand#50](https://github.com/ddimension/wwand/issues/50) Prepare configured PCIe transport before manager startup
- **[@fabianthoma](https://github.com/fabianthoma)**
  - [wwand#18](https://github.com/ddimension/wwand/issues/18) start_network handle NO_EFFECT (modem is already connected)
- **[@maurerr](https://github.com/maurerr)**
  - [wwand#43](https://github.com/ddimension/wwand/issues/43) Band allow-lists for AT/NCM modems (Fibocom `+GTACT`)

## Reports and testing

Issues: bugs found, logs captured, fixes confirmed on hardware.

- **[@obsy](https://github.com/obsy)** — 26 issues
  - [luci-app-wwand#1](https://github.com/ddimension/luci-app-wwand/issues/1) Displaying an object instead of data when there is no connection.
  - [luci-app-wwand#4](https://github.com/ddimension/luci-app-wwand/issues/4) PLMN missing....
  - [luci-app-wwand#5](https://github.com/ddimension/luci-app-wwand/issues/5) "Preferred networks (NAS)" section should be removed from Status/Modem
  - [luci-app-wwand#6](https://github.com/ddimension/luci-app-wwand/issues/6) Displays null
  - [luci-app-wwand#9](https://github.com/ddimension/luci-app-wwand/issues/9) Missing feature
  - [luci-app-wwand#10](https://github.com/ddimension/luci-app-wwand/issues/10) Various nomenclatures for "* technology"
  - [luci-app-wwand#11](https://github.com/ddimension/luci-app-wwand/issues/11) How to disable GNSS?
  - [luci-app-wwand#12](https://github.com/ddimension/luci-app-wwand/issues/12) Second SIM slot
  - [luci-app-wwand#13](https://github.com/ddimension/luci-app-wwand/issues/13) Empty bar
  - [luci-app-wwand#14](https://github.com/ddimension/luci-app-wwand/issues/14) A different look of the modem tools tab
  - [luci-app-wwand#15](https://github.com/ddimension/luci-app-wwand/issues/15) Remove such descriptions
  - [luci-proto-wwand#1](https://github.com/ddimension/luci-proto-wwand/issues/1) Modem status in new interface
  - [wwand#1](https://github.com/ddimension/wwand/issues/1) wwan issue
  - [wwand#2](https://github.com/ddimension/wwand/issues/2) Bad operator name decoding
  - [wwand#3](https://github.com/ddimension/wwand/issues/3) Radio on/off
  - [wwand#5](https://github.com/ddimension/wwand/issues/5) Problem with two modems
  - [wwand#7](https://github.com/ddimension/wwand/issues/7) MBIM: error in latest version
  - [wwand#9](https://github.com/ddimension/wwand/issues/9) MBIM:  NETDEV WATCHDOG
  - [wwand#10](https://github.com/ddimension/wwand/issues/10) Vendor in modem_probe
  - [wwand#11](https://github.com/ddimension/wwand/issues/11) IPv6 config
  - [wwand#12](https://github.com/ddimension/wwand/issues/12) Modem temperature
  - [wwand#13](https://github.com/ddimension/wwand/issues/13) [RFC] Built-in Connection Monitor
  - [wwand#14](https://github.com/ddimension/wwand/issues/14) [RFC] Live graph
  - [wwand#17](https://github.com/ddimension/wwand/issues/17) ucode wrror
  - [wwand#21](https://github.com/ddimension/wwand/issues/21) FM350-GL - Displays AT commands
  - [wwand#38](https://github.com/ddimension/wwand/issues/38) Radio off (software)
- **[@xsetiadi](https://github.com/xsetiadi)** — 13 issues
  - [wwand#23](https://github.com/ddimension/wwand/issues/23) request aarch64_generic
  - [wwand#25](https://github.com/ddimension/wwand/issues/25) Feature request: make the dead-bearer poll count configurable (e.g., 2 polls instead of 3)
  - [wwand#26](https://github.com/ddimension/wwand/issues/26) wwand-esim and wwand-qmi should not hard-require kmod packages that may not exist on snapshot
  - [wwand#27](https://github.com/ddimension/wwand/issues/27) FM350-GL: cannot switch to empty eUICC — AT+GTDUALSIM=1 and AT+SIMTYPE=1 both return ERROR
  - [wwand#28](https://github.com/ddimension/wwand/issues/28) FM350-GL: no vendor slot recipe on NCM/AT backend — sim_slot, wwandctl slot, and LuCI "Switch now" all fail
  - [wwand#29](https://github.com/ddimension/wwand/issues/29) wwandctl sms always reports "no messages" — daemon receives valid PDUs but parser returns empty (FM350-GL)
  - [wwand#32](https://github.com/ddimension/wwand/issues/32) Slot switch recovery leaves interface without IPv4 address — PDP misclassified as IPv6-only, netifd never gets address or route
  - [wwand#33](https://github.com/ddimension/wwand/issues/33) parse_ethermal averages a secondary sensor into the reported temperature — 10°C too low when field 3 exceeds the 10-threshold
  - [wwand#34](https://github.com/ddimension/wwand/issues/34) Make automatic SIM slot switching user-triggered only; never auto-switch during recovery
  - [wwand#35](https://github.com/ddimension/wwand/issues/35) eSIM profile switch to non-primary profile causes permanent PDP context activation failure and interface lockout in ifdown state
  - [wwand#37](https://github.com/ddimension/wwand/issues/37) LuCI modem page crashes with "Cannot read properties of undefined (reading 'fmtMnc')" on wwand 1.6.7_p58
  - [wwand#45](https://github.com/ddimension/wwand/issues/45) [Feature Request] Add LTE/5G band locking support for Fibocom FM350-GL (NCM/RNDIS mode)
  - [wwand#67](https://github.com/ddimension/wwand/issues/67) [Bug] Daemon fails to start after snapshot upgrade due to libucode ABI mismatch and dependency conflicts on downgrade
- **[@simsasss](https://github.com/simsasss)** — 7 issues
  - [luci-app-wwand#7](https://github.com/ddimension/luci-app-wwand/issues/7) Creating new interface wwand_modem options get deleted
  - [openwrt-repo#2](https://github.com/ddimension/openwrt-repo/issues/2) Quectel EG060K-EA CA graph display only one carrier
  - [openwrt-repo#3](https://github.com/ddimension/openwrt-repo/issues/3) Feature request: add modem action to reinit SIM card
  - [openwrt-repo#4](https://github.com/ddimension/openwrt-repo/issues/4) Reboot action prioritize reset pin
  - [wwand#15](https://github.com/ddimension/wwand/issues/15) wwand segfault on restart
  - [wwand#16](https://github.com/ddimension/wwand/issues/16) wwand fails to auto detect communication channel with EC200A
  - [wwand#19](https://github.com/ddimension/wwand/issues/19) EC200A does not have some AT commands
- **[@MassiPi](https://github.com/MassiPi)** — 6 issues
  - [wwand#39](https://github.com/ddimension/wwand/issues/39) Problem setting desidered SIM slot for interface
  - [wwand#40](https://github.com/ddimension/wwand/issues/40) [NR7101] Modem not armed after every reboot
  - [wwand#42](https://github.com/ddimension/wwand/issues/42) [feature request] Passthrough connection
  - [wwand#44](https://github.com/ddimension/wwand/issues/44) 404 for new page wwand-sims
  - [wwand#47](https://github.com/ddimension/wwand/issues/47) [NR7101] AT port missing at first boot
  - [wwand#68](https://github.com/ddimension/wwand/issues/68) Move band change log to "debug"
- **[@marcinnet-25](https://github.com/marcinnet-25)** — 5 issues
  - [wwand#54](https://github.com/ddimension/wwand/issues/54) Feature request: Support separate IPv4 and IPv6 APNs for dual-stack connectivity
  - [wwand#57](https://github.com/ddimension/wwand/issues/57) Unnecessary eUICC detection on Quectel EG12-EA during startup
  - [wwand#58](https://github.com/ddimension/wwand/issues/58) Quectel EG12-EA: 4G cell lock is not applied (QNWLOCK returns ERROR)
  - [wwand#62](https://github.com/ddimension/wwand/issues/62) WAN fails to reconnect after LTE band change with Quectel EG12-EA
  - [wwand#69](https://github.com/ddimension/wwand/issues/69) wwand-gps: Unnecessary CPU usage while the device is idle
- **[@liaohongxing](https://github.com/liaohongxing)** — 3 issues
  - [wwand#31](https://github.com/ddimension/wwand/issues/31) IPv6 doesn’t work.
  - [wwand#36](https://github.com/ddimension/wwand/issues/36) LAN-side IPv6 fails to access the Internet after multiple reboots
  - [wwand#51](https://github.com/ddimension/wwand/issues/51) Several at log errors and collectd issues
- **[@miku2365](https://github.com/miku2365)** — 3 issues
  - [wwand#8](https://github.com/ddimension/wwand/issues/8) IPv6 has no default route
  - [wwand#30](https://github.com/ddimension/wwand/issues/30) After running for a while, the log starts to repeat protocol error counter at 5.
  - [wwand#71](https://github.com/ddimension/wwand/issues/71) Watchcat example script fails
- **[@kszaq](https://github.com/kszaq)** — 2 issues
  - [wwand#55](https://github.com/ddimension/wwand/issues/55) Resetting radio technology / bands in Modem Tools does not work
  - [wwand#63](https://github.com/ddimension/wwand/issues/63) MBIM error 2 on router boot
- **[@mrhaav](https://github.com/mrhaav)** — 2 issues
  - [wwand#52](https://github.com/ddimension/wwand/issues/52) Reattach on EPS service not allowed
  - [wwand#70](https://github.com/ddimension/wwand/issues/70) T99W175: monitor temperature
- **[@patrakov](https://github.com/patrakov)** — 1 issue
  - [luci-app-wwand#8](https://github.com/ddimension/luci-app-wwand/issues/8) Feature request: a way to quickly delete all or almost all messages
- **[@micw](https://github.com/micw)** — 1 issue
  - [wwand#48](https://github.com/ddimension/wwand/issues/48) Make "board.uc" modular
- **[@przemekp1](https://github.com/przemekp1)** — 1 issue
  - [wwand#6](https://github.com/ddimension/wwand/issues/6) MBIM: LTE fails on first boot activation with CONNECT_FAILED, but succeeds after ifdown/ifup (Sierra EM7455B)
- **[@4IceG](https://github.com/4IceG)** — 1 issue
  - [wwand#66](https://github.com/ddimension/wwand/issues/66) Very slow response of the wwand on the Xunison D50 (rmnet_nss - Quectel RM500Q-AE 5G modem)
- **[@leideno](https://github.com/leideno)** — 1 issue
  - [wwand#41](https://github.com/ddimension/wwand/issues/41) No Gateway/Routing address for wwand interfaces
- **[@olivluca](https://github.com/olivluca)** — 1 issue
  - [wwand#4](https://github.com/ddimension/wwand/issues/4) question: roaming and connectivity check
- **[@LS3434](https://github.com/LS3434)** — 1 issue
  - [luci-app-wwand#2](https://github.com/ddimension/luci-app-wwand/issues/2) Wrong uptime being displayed

## Review and discussion

Comments, reviews and testing in threads opened by others.

- **[@Daniel-dk](https://github.com/Daniel-dk)** — [wwand#4](https://github.com/ddimension/wwand/issues/4)
- **[@kuncy7](https://github.com/kuncy7)** — [wwand#20](https://github.com/ddimension/wwand/issues/20)
- **[@4920441](https://github.com/4920441)** — [openwrt/packages#30185](https://github.com/openwrt/packages/pull/30185)
- **[@GithPK](https://github.com/GithPK)** — [openwrt/packages#30185](https://github.com/openwrt/packages/pull/30185)
- **[@lynxthecat](https://github.com/lynxthecat)** — [openwrt/packages#30185](https://github.com/openwrt/packages/pull/30185)
- **[@BKPepe](https://github.com/BKPepe)** — [openwrt/packages#30185](https://github.com/openwrt/packages/pull/30185)

Generated from the GitHub history on 2026-10-24; keep it current when a new
name turns up in an issue or a pull request.
