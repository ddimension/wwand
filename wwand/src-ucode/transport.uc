// wwand — transport hub: wraps the native wwand_io handle, registers the
// fd with uloop and routes decoded QMUX messages to attached service clients.
//
// let hub = transport.open('/dev/cdc-wdm0', {
//     on_gone:      (hub) => { ... },        // device disappeared
//     on_unhandled: (hub, dec) => { ... },   // no client matched
// });
// hub.register(client);   // client provides .service, .cid, .dispatch(dec)
// hub.send(frame);
// hub.close();
//
// Note: QMI control messages are tiny; writes go straight to the (non-
// blocking) fd without a queue. A failed/short write is reported to the
// caller and counts as a request error upstream.

'use strict';

import * as qmit from 'wwand_io';
import * as uloop from 'uloop';
import * as qmux from './codec/qmux.uc';

export function open(path, cbs)
{
	let handle = qmit.open(path);

	if (!handle)
		return null;

	let hub = {
		path: path,
		clients: {},
		closed: false,
	};

	hub.register = function(client) {
		hub.clients[sprintf('%d:%d', client.service, client.cid)] = client;
	};

	hub.unregister = function(client) {
		delete hub.clients[sprintf('%d:%d', client.service, client.cid)];
	};

	hub.send = function(frame) {
		if (hub.closed)
			return false;

		let w = handle.write(frame);

		return (w === length(frame));
	};

	// raw frame writer — identical to send(), named for the MBIM client which
	// deals in whole messages already
	hub.send_raw = hub.send;

	hub.close = function() {
		if (hub.closed)
			return;

		hub.closed = true;

		if (hub._uhandle) {
			hub._uhandle.delete();
			hub._uhandle = null;
		}

		handle.close();
	};

	hub._dispatch = function(dec) {
		let client = hub.clients[sprintf('%d:%d', dec.service, dec.cid)];

		// broadcast indications (e.g. NAS) arrive on cid 0xff
		if (!client && dec.kind == 'indication' && dec.cid == 0xff) {
			for (let key, c in hub.clients)
				if (c.service == dec.service)
					c.dispatch(dec);

			return;
		}

		if (client)
			client.dispatch(dec);
		else if (cbs?.on_unhandled)
			cbs.on_unhandled(hub, dec);
	};

	hub._uhandle = uloop.handle(handle.fileno(), (events) => {
		while (true) {
			let msg = handle.read();

			if (msg === null)
				break;

			if (msg === false) {
				hub.close();

				if (cbs?.on_gone)
					cbs.on_gone(hub);

				return;
			}

			// MBIM devices hand whole messages to a single raw handler
			// (no per-service QMUX demux); QMI devices decode QMUX
			if (cbs?.on_raw) {
				cbs.on_raw(hub, msg);
				continue;
			}

			let dec = qmux.decode(msg);

			if (dec)
				hub._dispatch(dec);
			else if (cbs?.on_unhandled)
				cbs.on_unhandled(hub, { raw: msg });
		}
	}, uloop.ULOOP_READ);

	if (!hub._uhandle) {
		handle.close();

		return null;
	}

	return hub;
}
