// wwand tests — MBIM modem + context integration against the MBIM mock hub.
//
// The MBIM counterpart to test_context.uc (QMI): drives modem_mbim through the
// real OPEN -> CAPS -> SUBSCRIBER -> REGISTER -> PACKET_SERVICE bring-up to
// READY, connects a context (CONNECT -> IP_CONFIGURATION), and validates the
// loss-detection paths added for cdc_mbim — where the netdev carrier does not
// follow the session, so the control-plane indications are the only signal:
//   * unsolicited MBIM_CID_CONNECT deactivation -> context down/disconnected
//   * REGISTER_STATE deregister -> modem 'deregistered' + context 'suspend'
//   * reconnect in place after a drop.

'use strict';

import { eq, ok, done } from './lib/check.uc';
import * as uloop from 'uloop';
import * as struct from 'struct';
import * as mbim_mockhub from './lib/mbim_mockhub.uc';
import * as modem_mbim from 'wwand/modem_mbim.uc';
import * as context_mbim from 'wwand/context_mbim.uc';
import * as bc from 'wwand/codec/mbim-schema/basic_connect.uc';

uloop.init();

function p32(v) { return struct.pack('<I', v); }

// a valid IP_CONFIGURATION InformationBuffer (1 IPv4 /30, gateway, 2 DNS) in the
// real count+offset layout. encode_info can't produce count+offset arrays (it
// only ever encodes request buffers in production), so hand it to the mock raw.
function build_ipcfg() {
	let fixedlen = 4 * 15;
	let v4addr_off = fixedlen;
	let v4addr = p32(30) + chr(37, 83, 58, 112);
	let gw_off = v4addr_off + length(v4addr);
	let gw = chr(37, 83, 58, 113);
	let dns_off = gw_off + length(gw);
	let dns = chr(10, 74, 210, 210) + chr(10, 74, 210, 211);

	let fixed =
		p32(0) +               // session_id
		p32(1) + p32(0) +      // v4 avail, v6 avail
		p32(1) +               // v4 count
		p32(v4addr_off) +      // v4 addr offset
		p32(0) + p32(0) +      // v6 count, v6 addr offset
		p32(gw_off) +          // v4 gw ref
		p32(0) +               // v6 gw ref
		p32(2) +               // v4 dns count
		p32(dns_off) +         // v4 dns offset
		p32(0) + p32(0) +      // v6 dns count, offset
		p32(1500) + p32(0);    // v4 mtu, v6 mtu

	return fixed + v4addr + gw + dns;
}

function base_handlers() {
	return {
		DEVICE_CAPS: {
			device_type: 1, cellular_class: 1, voice_class: 1, sim_class: 2,
			data_class: 0x3f, sms_caps: 0, control_caps: 0, max_sessions: 8,
			custom_data_class: '', device_id: '359072060000000',
			firmware_info: 'EG06ELAR04A20M4G', hardware_info: 'EG06-E',
		},
		SUBSCRIBER_READY_STATUS: {
			ready_state: bc.READY_STATE_INITIALIZED,
			subscriber_id: '262011234567890', sim_iccid: '89490200001022832490',
			ready_info: 0, telephone_numbers_count: 0,
		},
		REGISTER_STATE: {
			nw_error: 0, register_state: bc.REGISTER_STATE_HOME, register_mode: 1,
			available_data_classes: 0x20, current_cellular_class: 1,
			provider_id: '26201', provider_name: 'Telekom.de',
			roaming_text: '', registration_flag: 0,
		},
		PACKET_SERVICE: {
			nw_error: 0, packet_service_state: bc.PACKET_SERVICE_STATE_ATTACHED,
			highest_available_data_class: 0x20,
		},
		CONNECT: (args) => (args.activation_command == bc.ACTIVATION_CMD_ACTIVATE)
			? { session_id: args.session_id, activation_state: bc.ACTIVATION_ACTIVATED,
			    voice_call_state: 0, ip_type: args.ip_type,
			    context_type: bc.CONTEXT_TYPE_INTERNET, nw_error: 0 }
			: { session_id: args.session_id, activation_state: bc.ACTIVATION_DEACTIVATED,
			    voice_call_state: 0, ip_type: 0,
			    context_type: bc.CONTEXT_TYPE_INTERNET, nw_error: 0 },
		IP_CONFIGURATION: { __raw: build_ipcfg() },
	};
}

function last_event(arr, name) {
	let r = null;
	for (let e in arr)
		if (e.event == name) r = e;
	return r;
}

function any_event(arr, name, from) {
	for (let i = from ?? 0; i < length(arr); i++)
		if (arr[i].event == name) return true;
	return false;
}

let mock = mbim_mockhub.create({ schema: bc, handlers: base_handlers() });
let mevents = [], cevents = [];
let ctx = null, modem = null, guard = null;

let start_scenario, step_loss, step_reconnect, step_suspend, finish;

modem = modem_mbim.create({
	id: 'm0', device: '/dev/mock0',
	config: { apn: 'internet.t-d1.de', mux_id: 0 },
	timing: { settle: 1, reg_timeout: 500, backoff_min: 1, backoff_max: 5, at_drain: 1 },
	// starve the AT side channel: no tty found -> best-effort skip
	at: { fx: { read: () => null, glob: () => [] } },
	deps: {
		transport_open: mock.transport_open,
		log: () => null,
		on_event: (m, event, data) => {
			push(mevents, { event: event, data: data });

			if (event == 'registered' && !ctx) {
				ctx = context_mbim.create({
					name: 'wan', modem: m,
					config: { apn: 'internet.t-d1.de', mux_id: 0 },
					deps: {
						log: () => null,
						on_event: (c, ev, d) => push(cevents, { event: ev, data: d }),
					},
				});

				start_scenario();
			}
		},
	},
});

start_scenario = () => {
	ok(true, 'modem reached READY (OPEN->CAPS->SUBSCRIBER->REGISTER->PACKET_SERVICE)');
	eq(modem.info.imsi, '262011234567890', 'subscriber id read from SUBSCRIBER_READY');

	ctx.up((err, settings) => {
		eq(err, null, 'context up succeeds');
		eq(ctx.state, 'CONNECTED', 'context CONNECTED');
		eq(settings?.ipv4?.addr, '37.83.58.112', 'ipv4 address decoded from IP_CONFIGURATION');
		eq(settings?.ipv4?.gateway, '37.83.58.113', 'ipv4 gateway decoded');
		eq(settings?.ipv4?.dns, [ '10.74.210.210', '10.74.210.211' ], 'ipv4 dns decoded');
		step_loss();
	});
};

// unsolicited CONNECT deactivation -> the context must tear down
step_loss = () => {
	mock.indicate('CONNECT', { session_id: 0, activation_state: bc.ACTIVATION_DEACTIVATED,
	                           voice_call_state: 0, ip_type: 0,
	                           context_type: bc.CONTEXT_TYPE_INTERNET, nw_error: 0 });

	uloop.timer(20, () => {
		eq(ctx.state, 'IDLE', 'CONNECT-deactivate indication -> context IDLE');
		let d = last_event(cevents, 'down');
		ok(d && d.data?.reason == 'disconnected', 'context emitted down/disconnected');
		step_reconnect();
	});
};

// the daemon would retry after a disconnect — the context reconnects in place
step_reconnect = () => {
	ctx.up((err) => {
		eq(err, null, 'context reconnects after drop');
		eq(ctx.state, 'CONNECTED', 'reconnected CONNECTED');
		step_suspend();
	});
};

// registration loss -> modem 'deregistered' + context 'suspend'
step_suspend = () => {
	let from = length(cevents);

	mock.indicate('REGISTER_STATE', { nw_error: 0, register_state: 0, register_mode: 0,
	                                  available_data_classes: 0, current_cellular_class: 0,
	                                  provider_id: '', provider_name: '', roaming_text: '',
	                                  registration_flag: 0 });

	uloop.timer(20, () => {
		ok(any_event(mevents, 'deregistered'), 'REGISTER_STATE deregister -> modem deregistered');
		ok(any_event(cevents, 'suspend', from), 'registration loss -> context suspend');
		finish();
	});
};

finish = () => {
	if (guard) guard.cancel();
	modem.stop();
	uloop.end();
};

guard = uloop.timer(3000, () => {
	ok(false, 'scenario timed out');
	uloop.end();
});

modem.start();
uloop.run();

done('test_context_mbim');
