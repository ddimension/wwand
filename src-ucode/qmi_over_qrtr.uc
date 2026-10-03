// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 wwand contributors
// wwand — QMI-over-QRTR transport shim.
//
// Presents the same `hub` contract that transport.uc/qmi_over_mbim.uc offer to the
// QMI stack (register/unregister a client keyed by service*256+cid; send a QMUX
// frame; feed decoded QMUX objects back via client.dispatch), but carries every
// message over AF_QIPCRTR sockets instead of a cdc-wdm QMUX channel. Because
// client.uc depends only on that contract, the ENTIRE QMI stack — client.uc, qmux,
// tlv, every codec/schema, qmi_backend.uc — runs unchanged over QRTR. This is how
// wwand reaches a Qualcomm SDX modem on PCIe/MHI whose QMI lives on QRTR
// (mhi0_IPCR -> qcom_mhi_qrtr), where there is no cdc-wdm QMUX device at all.
//
//   let hub = qmi_over_qrtr.create({ log, on_gone });
//   let ctl = client.create(hub, ctl_schema, 0, hooks);   // as over qmux
//   ctl.request('ALLOCATE_CID', { service: 2 }, (e, d) => ...);
//
// TWO structural differences from QMUX, handled here so the stack above cannot
// tell (docs/gotchas + the QMI-over-QRTR framing verified on a Quectel RG520N,
// 2026-10-01):
//
//   1. There is NO CTL service on QRTR — the socket itself is the client, and
//      each QMI service is its own (node,port) endpoint. So CTL (service 0) is
//      EMULATED locally: SYNC/GET_VERSION_INFO/ALLOCATE_CID/RELEASE_CID are
//      answered from here, never put on the wire. ALLOCATE_CID hands out a cid we
//      pick (one per service — the core backend runs one client per service).
//
//   2. There is NO QMUX header on the wire — a service message is the bare SDU
//      ([flags][txn u16][msg_id u16][len u16][TLVs]), which is exactly a wwand
//      QMUX frame minus its 6-byte header. So send() strips the header and
//      sendto()s the SDU to the service's endpoint; the reader prepends a
//      synthetic header (service from the source-address map, our assigned cid)
//      and hands a normal QMUX frame to the shared decoder.

'use strict';

import * as struct from 'struct';
import * as uloop from 'uloop';
import * as qmit from 'wwand_io';
import * as qmux from 'wwand.codec.qmux';
import * as tlv from 'wwand.codec.tlv';
import * as ctlmod from 'wwand.codec.schema.ctl';

const CTL = 0x00;
// result TLV = success (type 0x02, len 4, result 0, error 0) — every QMI response
// carries it, and client.uc keys success/failure off _result (tlv.uc)
const RESULT_OK = struct.pack('<BHHH', 0x02, 4, 0, 0);

// create(opts): opts.log(level,msg), opts.on_gone(hub), opts.io (inject for tests)
export function create(opts)
{
	let io = opts?.io ?? qmit;
	let log = opts?.log ?? ((l, m) => null);

	let h = io.qrtr_open();

	if (!h) {
		log('warn', sprintf('qrtr: open failed: %s', io.last_error() ?? '?'));

		return null;
	}

	let self = {
		clients: {},
		closed: false,
		svc_addr: {},   // 'service' -> { node, port }   (send routing)
		addr_svc: {},   // 'node:port' -> service         (recv reverse routing)
		svc_cid:  {},   // 'service' -> cid               (assigned in ALLOCATE_CID)
		next_cid: 1,
	};

	// One-shot synchronous discovery (wwand_io.qdiscover): the backend allocates a
	// CID for a service the instant the channel is up, which needs that service's
	// (node,port). Prefer the MODEM node — the node hosting DMS (service 2) — and
	// map only its services, so SoC-side services (IPA/DPM, on another node) never
	// shadow the modem's low-numbered QMI services.
	let servers = h.qdiscover(2000) ?? [];
	let modem_node = null;

	for (let s in servers)
		if (s.service == 0x02) { modem_node = s.node; break; }

	if (modem_node == null && length(servers))
		modem_node = servers[0].node;

	for (let s in servers) {
		if (s.node != modem_node)
			continue;

		self.svc_addr[sprintf('%d', s.service)] = { node: s.node, port: s.port };
		self.addr_svc[sprintf('%d:%d', s.node, s.port)] = s.service;
	}

	log('notice', sprintf('qrtr: modem node %s, %d services',
	                      (modem_node == null) ? '?' : sprintf('%d', modem_node),
	                      length(self.svc_addr)));

	// route a decoded QMUX frame (response or indication) to its client
	let deliver = (frame) => {
		let dec = qmux.decode(frame);

		if (!dec)
			return;

		let client = self.clients[dec.service * 256 + dec.cid];

		if (!client && dec.kind == 'indication' && dec.cid == 0xff) {
			for (let k, c in self.clients)
				if (c.service == dec.service)
					c.dispatch(dec);

			return;
		}

		if (client)
			client.dispatch(dec);
	};

	// synthesize a CTL response and deliver it on the NEXT loop iteration — never
	// re-enter client.request()'s stack (it calls hub.send synchronously)
	let ctl_reply = (txn, msg_id, extra_tlvs) => {
		let frame = qmux.encode(CTL, 0, txn, msg_id, RESULT_OK + (extra_tlvs ?? ''), 'response');

		uloop.timer(0, () => { if (!self.closed) deliver(frame); });
	};

	// CTL (service 0) is emulated: QRTR has no CTL service on the wire
	let handle_ctl = (dec) => {
		let m = ctlmod.default.messages;

		if (dec.msg_id == m.SYNC.id) {
			ctl_reply(dec.txn, dec.msg_id, '');
		}
		else if (dec.msg_id == m.GET_VERSION_INFO.id) {
			let list = [];

			// the CTL version list encodes each service id as a u8, but a QRTR
			// modem also registers vendor services with ids > 255 (e.g. 1071, 4097
			// on the RG520N). They are never QMI CTL services and the backend never
			// allocates them, so leave them out — packing one as u8 would throw.
			for (let svc, a in self.svc_addr)
				if (+svc <= 255)
					push(list, { service: +svc, major: 1, minor: 0 });

			ctl_reply(dec.txn, dec.msg_id,
			          tlv.pack(m.GET_VERSION_INFO.resp, { services: list }));
		}
		else if (dec.msg_id == m.ALLOCATE_CID.id) {
			let req = tlv.unpack(m.ALLOCATE_CID.req, dec.tlvs);
			let key = sprintf('%d', req.service);
			let cid = self.svc_cid[key];

			// one cid per service (the core backend runs one client per service)
			if (cid == null) {
				cid = self.next_cid++;

				if (self.next_cid > 0xff)
					self.next_cid = 1;

				self.svc_cid[key] = cid;
			}

			ctl_reply(dec.txn, dec.msg_id,
			          tlv.pack(m.ALLOCATE_CID.resp, { allocation: { service: req.service, cid: cid } }));
		}
		else if (dec.msg_id == m.RELEASE_CID.id) {
			let req = tlv.unpack(m.RELEASE_CID.req, dec.tlvs);

			if (req.release?.service != null)
				delete self.svc_cid[sprintf('%d', req.release.service)];

			ctl_reply(dec.txn, dec.msg_id,
			          tlv.pack(m.RELEASE_CID.resp, { release: req.release }));
		}
		else {
			// unknown CTL request: answer success, best-effort
			ctl_reply(dec.txn, dec.msg_id, '');
		}
	};

	self.register = function(client) {
		self.clients[client.service * 256 + client.cid] = client;
	};

	self.unregister = function(client) {
		delete self.clients[client.service * 256 + client.cid];
	};

	self.send = function(frame) {
		if (self.closed)
			return false;

		let dec = qmux.decode(frame);

		if (!dec)
			return false;

		if (dec.service == CTL) {
			handle_ctl(dec);

			return true;
		}

		let addr = self.svc_addr[sprintf('%d', dec.service)];

		if (!addr) {
			log('warn', sprintf('qrtr: no QRTR address for service %d', dec.service));

			return false;
		}

		// the QRTR SDU is the QMUX frame minus its 6-byte header
		let r = h.qsend(addr.node, addr.port, substr(frame, 6));

		// false = hard error; null = EAGAIN (rare for small datagrams — the QMI
		// request then times out and retries, which is correct)
		return (r !== false);
	};

	self.send_raw = self.send;

	self.close = function() {
		if (self.closed)
			return;

		self.closed = true;
		self.clients = {};

		if (self._uh) {
			self._uh.delete();
			self._uh = null;
		}

		h.close();
	};

	// async service responses + unsolicited indications
	self._uh = uloop.handle(h.fileno(), (ev) => {
		if (self.closed)
			return;

		for (;;) {
			let m = h.qread();

			if (m === null)
				break;

			if (m === false) {
				self.close();

				if (opts?.on_gone)
					opts.on_gone(self);

				return;
			}

			let svc = self.addr_svc[sprintf('%d:%d', m.node, m.port)];

			// a datagram from an address we did not map (a stray control packet, a
			// late NEW_SERVER) has no client — ignore it
			if (svc == null)
				continue;

			let cid = self.svc_cid[sprintf('%d', svc)] ?? 0;

			// wrap the bare SDU back into a QMUX frame for the shared QMI decoder:
			// [0x01][len u16][flags 0x80][service][cid] + SDU
			deliver(struct.pack('<BHBBB', 0x01, 5 + length(m.data), 0x80, svc, cid) + m.data);
		}
	}, uloop.ULOOP_READ);

	if (!self._uh) {
		h.close();

		return null;
	}

	return self;
};
