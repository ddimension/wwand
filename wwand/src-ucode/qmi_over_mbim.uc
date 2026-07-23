// wwand — QMI-over-MBIM passthrough transport shim.
//
// Presents the same tiny `hub` contract that transport.uc offers to the QMI
// stack (register/unregister a client keyed by service*256+cid; send a QMUX
// frame; feed decoded QMUX objects back via client.dispatch), but tunnels every
// frame through the MBIM QMI passthrough service on an already-open MBIM control
// channel. Because client.uc depends only on that contract, the ENTIRE QMI stack
// — client.uc, qmux, tlv, every codec/schema, qmi_backend.uc — runs unchanged
// over MBIM. This is how the MBIM backend reaches CDC-level telemetry/config
// (cells, CA, signal, band config) on modems that expose the passthrough.
//
//   let shim = qmi_over_mbim.create(mbim_client);
//   let nas  = client.create(shim, nas_schema, cid, hooks);   // as over qmux
//   nas.request('GET_SIGNAL_INFO', {}, (err, data) => …);

'use strict';

import * as struct from 'struct';
import * as mbim from './codec/mbim.uc';
import * as qmux from './codec/qmux.uc';
import * as qmi_pt from './codec/mbim-schema/qmi_passthrough.uc';

// create(mc, opts): mc is an opened mbim_client. Returns a hub-shaped object.
export function create(mc, opts)
{
	let self = { clients: {}, closed: false };
	let log = opts?.log ?? ((level, msg) => null);

	// route a decoded QMUX frame (response or indication) to its client
	let deliver = (frame) => {
		let dec = qmux.decode(frame);

		if (!dec)
			return;

		let client = self.clients[dec.service * 256 + dec.cid];

		if (client)
			client.dispatch(dec);
	};

	// --- hub contract used by client.uc ------------------------------------
	self.register = function(client) {
		self.clients[client.service * 256 + client.cid] = client;
	};

	self.unregister = function(client) {
		delete self.clients[client.service * 256 + client.cid];
	};

	self.send = function(frame) {
		if (self.closed)
			return false;

		// `frame` is a raw QMUX frame from qmux.encode(); tunnel it as the opaque
		// InformationBuffer of an MBIM COMMAND to the QMI passthrough CID and
		// unwrap the QMUX reply.
		let req = qmux.decode(frame);

		mc.command_raw(qmi_pt.service, qmi_pt.CID_QMI_MSG, frame, (err, info) => {
			if (err) {
				log('debug', sprintf('qmi-over-mbim: passthrough error %J', err));

				// The modem has no QMI passthrough service (or rejected it). There
				// is no QMUX reply to dispatch, so synthesize a QMI error response
				// (result TLV = failure) for the pending request — this makes the
				// caller fail FAST instead of waiting out its timeout, which is
				// what lets _ensure_pt fall back to native/AT promptly.
				if (req)
					deliver(qmux.encode(req.service, req.cid, req.txn, req.msg_id,
						struct.pack('<BHHH', 0x02, 4, 1, 0), 'response'));

				return;
			}

			deliver(info);
		});

		return true;
	};

	self.send_raw = self.send;

	self.close = function() {
		self.closed = true;
		self.clients = {};
	};

	// unsolicited QMI indications arrive as MBIM INDICATE_STATUS on the QMI CID;
	// the passthrough info is the raw QMUX indication frame (2nd on() arg = msg)
	mc.on(qmi_pt, 'QMI_MSG', (data, msg) => deliver(msg.info));

	return self;
}
