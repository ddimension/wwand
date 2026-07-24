#!/bin/sh
# wwand — thin netifd proto handler. All modem logic lives in the wwand
# daemon; this shim only relays context up/down over ubus and feeds the
# resulting static IP configuration to netifd (modeled after the
# modemmanager proto handler).

[ -n "$INCLUDE_ONLY" ] || {
	. /lib/functions.sh
	. ../netifd-proto.sh
	init_proto "$@"
}

proto_wwand_init_config() {
	available=1
	renew_handler=1
	# The daemon owns the context lifecycle and drives netifd (up/down/renew)
	# over ubus, so there is no per-interface supervisor task. Setup applies the
	# config once; the interface then stays up until the daemon drives it down.
	no_proto_task=1
	proto_config_add_string context

	# network-native model: the interface references a wwand_modem via `option
	# modem` and carries the connection (apn/auth/… reused from the block below)
	# inline. Declared so netifd tracks them; the daemon reads them from uci.
	proto_config_add_string modem
	proto_config_add_string pdp_type
	proto_config_add_string profile
	proto_config_add_string use_pushed_prefix
	proto_config_add_string settings_poll

	# legacy qmi-advanced options: accepted so old configs keep parsing;
	# interpreted by the wwand compat layer, not by this shim
	proto_config_add_string "device:device"
	proto_config_add_string ctldevice
	proto_config_add_string apn
	proto_config_add_string auth
	proto_config_add_string username
	proto_config_add_string password
	proto_config_add_string pincode
	proto_config_add_string delay
	proto_config_add_string modes
	proto_config_add_string ipv4
	proto_config_add_string ipv6
	proto_config_add_string mcc
	proto_config_add_string mnc
	proto_config_add_string mtu
	proto_config_add_string use_pushed_mtu
	proto_config_add_string location
	proto_config_add_string zero_rx_timeout
	proto_config_add_string failreboot
	proto_config_add_string strongestnetwork
	proto_config_add_string autocreateif
	proto_config_add_string customroutes
	proto_config_add_string dhcp
	proto_config_add_array "at_init:list(string)"

	proto_config_add_defaults
}

# Build and send a netifd proto update from a wwand context reply. Shared by
# setup and renew so the address/route/DNS handling is identical — and, per the
# VRF invariant, addressing/routing stays entirely in netifd (proto_add_*),
# never direct netlink. Args: interface netdev resp defaultroute peerdns
_wwand_apply_settings() {
	local interface="$1" netdev="$2" resp="$3" defaultroute="$4" peerdns="$5"

	# extract everything from the reply FIRST — proto_init_update and the
	# reply parsing share the same jshn state, mixing them corrupts the
	# update message sent to netifd
	local v4_addr v4_prefix v4_gateway v4_dns
	json_load "$resp"
	if json_select ipv4 2>/dev/null; then
		json_get_var v4_addr addr
		json_get_var v4_prefix prefix
		json_get_var v4_gateway gateway
		if json_select dns 2>/dev/null; then
			json_get_values v4_dns
			json_select ..
		fi
		json_select ..
	fi

	local v6_addr v6_plen v6_gateway v6_dns
	json_load "$resp"
	if json_select ipv6 2>/dev/null; then
		json_get_var v6_addr addr
		json_get_var v6_plen plen
		json_get_var v6_gateway gateway
		if json_select dns 2>/dev/null; then
			json_get_values v6_dns
			json_select ..
		fi
		json_select ..
	fi

	# no proto_set_keep: every update carries the complete address/route/DNS
	# set, and netifd only applies the diff anyway. With keep=1 entries missing
	# from an update survive forever — stale addresses and host routes piled
	# up across reconnect generations.
	proto_init_update "$netdev" 1

	[ -n "$v4_addr" ] && {
		proto_add_ipv4_address "$v4_addr" "${v4_prefix:-32}"
		# no gateway on the default route (old dialer behavior): the address
		# is a /32 on a p2p link, so the modem-reported gateway is off-link
		# and a via-route would be rejected — a device route always works
		[ "$defaultroute" = 0 ] || proto_add_ipv4_route "0.0.0.0" 0

		[ "$peerdns" = 0 ] || {
			for d in $v4_dns; do
				proto_add_dns_server "$d"
			done
		}
	}

	[ -n "$v6_addr" ] && {
		proto_add_ipv6_address "$v6_addr" "128"
		# RFC 7278: extend the delegated /64 towards LAN (pointless for /128)
		[ "${v6_plen:-64}" -lt 128 ] 2>/dev/null && \
			proto_add_ipv6_prefix "${v6_addr}/${v6_plen:-64}"
		[ -n "$v6_gateway" ] && proto_add_ipv6_route "$v6_gateway" 128
		[ "$defaultroute" = 0 ] || \
			proto_add_ipv6_route "::0" 0 "$v6_gateway" "" "" "${v6_addr}/${v6_plen:-64}"

		[ "$peerdns" = 0 ] || {
			for d in $v6_dns; do
				proto_add_dns_server "$d"
			done
		}
	}

	proto_send_update "$interface"
}

proto_wwand_setup() {
	local interface="$1"
	local defaultroute peerdns metric $PROTO_DEFAULT_OPTIONS
	json_get_vars defaultroute peerdns metric $PROTO_DEFAULT_OPTIONS

	# wait for the daemon
	ubus -t 30 wait_for wwand 2>/dev/null || {
		echo "wwand is not running"
		proto_notify_error "$interface" NO_DAEMON
		sleep 5
		return 1
	}

	local resp
	resp="$(ubus -t 180 call wwand context_up "{\"interface\":\"$interface\"}" 2>/dev/null)" || {
		echo "context_up failed for $interface"
		proto_notify_error "$interface" CONNECT_FAILED
		return 1
	}

	local up error netdev pushed_mtu use_pushed_mtu mtu
	json_load "$resp"
	json_get_vars up error netdev pushed_mtu use_pushed_mtu mtu

	[ "$up" = "1" ] || {
		echo "connection failed: ${error:-unknown}"

		case "$error" in
			sim_blocked)
				proto_notify_error "$interface" PIN_FAILED
				proto_block_restart "$interface"
				;;
			no_such_context)
				# transient during startup races: retry, do not block
				proto_notify_error "$interface" NO_CONTEXT
				sleep 5
				;;
			modem_absent)
				# the modem's control device is not present yet (after boot, a
				# modem reboot or a power-cycle). Surface it distinctly so the
				# network overview shows "waiting for modem" instead of a generic
				# failure; keep retrying (the daemon binds it once hotplug fires).
				echo "waiting for modem (control device not present)"
				proto_notify_error "$interface" WAITING_MODEM
				sleep 8
				;;
			*)
				proto_notify_error "$interface" CONNECT_FAILED
				# netifd re-runs setup immediately after a failed task; without
				# a pause here a no-service condition becomes a hot loop that
				# also climbs the daemon's recovery ladder
				sleep 10
				;;
		esac

		return 1
	}

	[ -n "$netdev" ] || {
		echo "daemon did not report a network device"
		proto_notify_error "$interface" NO_IFACE
		return 1
	}

	# MTU (incl. use_pushed_mtu semantics) is applied by the daemon itself
	# via rtnl before it reports the context up — nothing to do here

	_wwand_apply_settings "$interface" "$netdev" "$resp" "$defaultroute" "$peerdns"

	# no-proto-task: no supervisor process. The interface now stays up; the
	# daemon reconnects transient drops in place (renew) and only drives
	# 'network.interface <x> down' on a permanent loss, which runs the teardown.
}

proto_wwand_teardown() {
	local interface="$1"

	ubus -t 30 call wwand context_down "{\"interface\":\"$interface\"}" >/dev/null 2>&1
	# no link-down update here: netifd rejects notify_proto while in S_TEARDOWN
	# and drops the link itself once this script exits
}

# netifd renew: refresh the interface's IP settings in place, without a
# teardown. Driven by the wwand daemon (network.interface renew) whenever it
# (re)establishes a context or the modem pushes new settings (v6 prefix, DNS,
# MTU). netifd diffs the update against the live config and applies only the
# delta — so PD/VRF dependencies are preserved.
proto_wwand_renew() {
	local interface="$1"
	local defaultroute peerdns metric $PROTO_DEFAULT_OPTIONS
	json_get_vars defaultroute peerdns metric $PROTO_DEFAULT_OPTIONS

	local resp
	resp="$(ubus -t 30 call wwand context_settings "{\"interface\":\"$interface\"}" 2>/dev/null)" || return 0

	local up netdev
	json_load "$resp"
	json_get_vars up netdev

	# not connected (or daemon busy): leave the running config untouched — the
	# daemon reconnects transient drops in place and only downs the interface
	# on a permanent loss
	[ "$up" = "1" ] && [ -n "$netdev" ] || return 0

	_wwand_apply_settings "$interface" "$netdev" "$resp" "$defaultroute" "$peerdns"
}

# Back-compat: `proto qmi` is the name this handler shipped under historically
# (and stock qmi-advanced/uqmi used). Interfaces still saved that way — plus
# stock configs migrated in place — must keep working, so the legacy name maps
# onto the same functions. New configs use `proto wwand`; the daemon and LuCI
# accept both, and migration/LuCI rewrite to `wwand` on save.
proto_qmi_init_config() { proto_wwand_init_config "$@"; }
proto_qmi_setup()       { proto_wwand_setup "$@"; }
proto_qmi_teardown()    { proto_wwand_teardown "$@"; }
proto_qmi_renew()       { proto_wwand_renew "$@"; }

[ -n "$INCLUDE_ONLY" ] || {
	add_protocol wwand
	add_protocol qmi
}
