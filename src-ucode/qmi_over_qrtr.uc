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
// (mhi0_IPCR -> qcom_mhi_qrtr), where there is no cdc-wdm QMUX device at all
// (HW-verified by the author of ddimension/wwand#46 on a Quectel RG520N-EB on an
// IPQ5018, 2026-10-01).
//
//   let hub = qmi_over_qrtr.create({ log, on_gone, node });
//   let ctl = client.create(hub, ctl_schema, 0, hooks);   // as over qmux
//   ctl.request('ALLOCATE_CID', { service: 2 }, (e, d) => ...);
//
// How QRTR differs from QMUX, and why each piece below exists:
//
//   1. There is NO CTL service on QRTR. CTL (service 0) is emulated here:
//      SYNC / GET_VERSION_INFO / ALLOCATE_CID / RELEASE_CID never reach the wire
//      (those four are all the CTL wwand sends).
//
//   2. A QMI CLIENT IS A SOCKET. A service tells its clients apart by the
//      source (node, port) of their datagrams; there is no client id on the
//      wire, so the cid is a local name for one socket. Every emulated
//      ALLOCATE_CID therefore opens its own socket, and RELEASE_CID closes it.
//      One shared socket would make all clients of a service ONE client on the
//      modem — and wwand runs several WDS clients at once (the modem's own,
//      modem_init_qmi.uc, plus one per IP family and attempt for every
//      connection, context.uc): their sessions, IP families and mux bindings
//      would overwrite each other, and the reply to one would reach the other.
//      The kernel's own QMI clients do the same, one socket per handle
//      (net/qrtr: qmi_interface.c qmi_handle_init, linux 6.18.41).
//
//   3. There is NO QMUX header on the wire — a service message is the bare SDU
//      ([flags][txn u16][msg_id u16][len u16][TLVs]), a wwand QMUX frame minus
//      its 6-byte header. send() strips the header; a socket's reader prepends
//      a synthetic one with the service and THAT socket's cid.
//
//   4. The name server keeps talking. The NEW_LOOKUP that discovery sends stays
//      registered, so the kernel name server reports every later NEW_SERVER and
//      DEL_SERVER to the lookup socket (net/qrtr/ns.c lookup_notify, linux
//      6.18.41). A modem restart (SSR, a DMS reset by the recovery ladder, a
//      PCIe re-enumeration) shows up only there: its services leave and come
//      back on new ports, while every socket stays perfectly fine. So DMS
//      leaving the modem's node is this hub's "device gone".

'use strict';

import * as struct from 'struct';
import * as uloop from 'uloop';
import * as qmit from 'wwand_io';
import * as qmux from 'wwand.codec.qmux';
import * as tlv from 'wwand.codec.tlv';
import * as ctlmod from 'wwand.codec.schema.ctl';
import * as discovery from 'wwand.discovery';

const CTL = 0x00;

// include/uapi/linux/qrtr.h (linux 6.18.41): enum qrtr_pkt_type, and the
// control port every node's name server listens on
const QRTR_TYPE_NEW_SERVER = 4;
const QRTR_TYPE_DEL_SERVER = 5;
const QRTR_PORT_CTRL = 0xfffffffe;

// result TLV (type 0x02, len 4, result u16, error u16) — every QMI response
// carries it, and client.uc keys success/failure off _result (tlv.uc)
function result_tlv(err)
{
	return struct.pack('<BHHH', 0x02, 4, err ? 1 : 0, err ?? 0);
}

// QMI_PROTOCOL_ERROR_CLIENT_IDS_EXHAUSTED (libqmi qmi-errors.h, 1.38): what
// a real CTL answers when it cannot hand out another client — the closest
// truth when the socket for a new client cannot be opened
const QMI_ERR_CLIENT_IDS_EXHAUSTED = 0x05;

// qrtr_ctrl_pkt: le32 cmd, then { le32 service, instance, node, port } for
// NEW_SERVER / DEL_SERVER (include/uapi/linux/qrtr.h, linux 6.18.41). null
// for anything shorter or of another type.
export function parse_ctrl(data)
{
	if (length(data ?? '') < 20)
		return null;

	let v = struct.unpack('<IIIII', data);

	if (v[0] != QRTR_TYPE_NEW_SERVER && v[0] != QRTR_TYPE_DEL_SERVER)
		return null;

	return { cmd: (v[0] == QRTR_TYPE_NEW_SERVER) ? 'new' : 'del',
	         service: v[1], instance: v[2], node: v[3], port: v[4] };
};

// create(opts): opts.log(level,msg), opts.on_gone(hub), opts.node (the QRTR
// node to use; default: the one serving DMS), opts.io (inject for tests),
// opts.discover_ms (the bound on the synchronous lookup, default 1000).
// null when no socket can be opened or no node on the bus serves DMS.
export function create(opts)
{
	let io = opts?.io ?? qmit;
	let log = opts?.log ?? ((l, m) => null);

	let lookup = io.qrtr_open();

	if (!lookup) {
		log('warn', sprintf('qrtr: open failed: %s', io.last_error() ?? '?'));

		return null;
	}

	// Synchronous, because the backend allocates a client for DMS the instant
	// the channel is up and that needs DMS's address. Bounded and short in
	// practice: the daemon only gets here after its presence probe saw DMS,
	// and the name server ends the list with an empty entry within tens of
	// milliseconds.
	let servers = lookup.qdiscover(opts?.discover_ms ?? 1000) ?? [];
	let node = discovery.qrtr_pick_node(servers, opts?.node);

	if (node == null) {
		log('warn', (opts?.node != null)
			? sprintf('qrtr: node %d serves no QMI DMS', opts.node)
			: 'qrtr: no node on the bus serves QMI DMS');
		lookup.close();

		return null;
	}

	let self = {
		node: node,
		clients: {},     // service*256+cid -> client (client.uc)
		socks: {},       // service*256+cid -> { h, uh }
		svc_addr: {},    // 'service' -> port on `node`
		closed: false,
	};

	for (let s in servers)
		if (s.node == node)
			self.svc_addr[sprintf('%d', s.service)] = s.port;

	log('notice', sprintf('qrtr: modem node %d, %d services', node, length(self.svc_addr)));

	let key = (service, cid) => service * 256 + cid;

	// route a decoded QMUX frame (response or indication) to its client
	let deliver = (frame) => {
		let dec = qmux.decode(frame);

		if (!dec)
			return;

		let client = self.clients[key(dec.service, dec.cid)];

		if (client)
			client.dispatch(dec);
	};

	let gone;

	let close_sock = (k) => {
		let s = self.socks[k];

		if (!s)
			return;

		delete self.socks[k];
		s.uh?.delete();
		s.h.close();
	};

	// one reader per client socket: whatever arrives on it is that client's
	let watch = (service, cid, h) => uloop.handle(h.fileno(), (ev) => {
		for (;;) {
			if (self.closed)
				return;

			let m = h.qread();

			if (m === null)
				return;

			// a socket error here is the remote end resetting (the modem
			// node went away), not a fault of this one client
			if (m === false)
				return gone(sprintf('socket error on the client for service %d', service));

			// only the service's own endpoint speaks for it; a stray datagram
			// (a late reply from a previous incarnation's port) is dropped
			if (m.node != node || m.port != self.svc_addr[sprintf('%d', service)])
				continue;

			deliver(struct.pack('<BHBBB', 0x01, 5 + length(m.data), 0x80, service, cid) + m.data);
		}
	}, uloop.ULOOP_READ);

	// synthesize a CTL response and deliver it on the NEXT loop iteration — never
	// re-enter client.request()'s stack (it calls hub.send synchronously)
	let ctl_reply = (txn, msg_id, err, extra_tlvs) => {
		let frame = qmux.encode(CTL, 0, txn, msg_id, result_tlv(err) + (extra_tlvs ?? ''), 'response');

		uloop.timer(0, () => { if (!self.closed) deliver(frame); });
	};

	// the lowest cid of this service with no socket behind it, or null
	let free_cid = (service) => {
		for (let cid = 1; cid < 0xff; cid++)
			if (!self.socks[key(service, cid)])
				return cid;

		return null;
	};

	// CTL (service 0) is emulated: QRTR has no CTL service on the wire
	let handle_ctl = (dec) => {
		let m = ctlmod.default.messages;

		if (dec.msg_id == m.SYNC.id) {
			ctl_reply(dec.txn, dec.msg_id);
		}
		else if (dec.msg_id == m.GET_VERSION_INFO.id) {
			let list = [];

			// the CTL version list encodes each service id as a u8, but a QRTR
			// modem also registers vendor services with ids > 255 (e.g. 1071, 4097
			// on the RG520N). They are never QMI CTL services and the backend never
			// allocates them, so leave them out — packing one as u8 would throw.
			for (let svc, port in self.svc_addr)
				if (+svc <= 255)
					push(list, { service: +svc, major: 1, minor: 0 });

			ctl_reply(dec.txn, dec.msg_id, null,
			          tlv.pack(m.GET_VERSION_INFO.resp, { services: list }));
		}
		else if (dec.msg_id == m.ALLOCATE_CID.id) {
			let req = tlv.unpack(m.ALLOCATE_CID.req, dec.tlvs);
			let cid = free_cid(req.service);
			let h = (cid != null) ? io.qrtr_open() : null;
			let uh = h ? watch(req.service, cid, h) : null;

			if (!uh) {
				log('warn', sprintf('qrtr: no socket for a new client of service %d: %s',
					req.service, (cid == null) ? 'every cid in use' : (io.last_error() ?? '?')));
				h?.close();

				return ctl_reply(dec.txn, dec.msg_id, QMI_ERR_CLIENT_IDS_EXHAUSTED);
			}

			self.socks[key(req.service, cid)] = { h: h, uh: uh };
			ctl_reply(dec.txn, dec.msg_id, null,
			          tlv.pack(m.ALLOCATE_CID.resp, { allocation: { service: req.service, cid: cid } }));
		}
		else if (dec.msg_id == m.RELEASE_CID.id) {
			let req = tlv.unpack(m.RELEASE_CID.req, dec.tlvs);

			if (req.release?.service != null)
				close_sock(key(req.release.service, req.release.cid));

			ctl_reply(dec.txn, dec.msg_id, null,
			          tlv.pack(m.RELEASE_CID.resp, { release: req.release }));
		}
		else {
			// wwand sends no other CTL request; answering one with success
			// would claim something was done that never was
			ctl_reply(dec.txn, dec.msg_id, 0x5e);   // QMI_PROTOCOL_ERROR_NOT_SUPPORTED
		}
	};

	self.register = function(client) {
		self.clients[key(client.service, client.cid)] = client;
	};

	self.unregister = function(client) {
		delete self.clients[key(client.service, client.cid)];
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

		let s = self.socks[key(dec.service, dec.cid)];
		let port = self.svc_addr[sprintf('%d', dec.service)];

		if (!s || port == null) {
			log('warn', sprintf('qrtr: %s for service %d', !s
				? sprintf('no client socket for cid %d', dec.cid)
				: 'no server on the modem node', dec.service));

			return false;
		}

		// the QRTR SDU is the QMUX frame minus its 6-byte header
		let r = s.h.qsend(node, port, substr(frame, 6));

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

		for (let k in keys(self.socks))
			close_sock(+k);

		self._uh?.delete();
		self._uh = null;
		lookup.close();
	};

	gone = (why) => {
		if (self.closed)
			return;

		log('warn', sprintf('qrtr: modem node %d gone (%s)', node, why));
		self.close();

		if (opts?.on_gone)
			opts.on_gone(self);
	};

	// the name server's reports on the lookup socket (4. above)
	self._uh = uloop.handle(lookup.fileno(), (ev) => {
		for (;;) {
			if (self.closed)
				return;

			let m = lookup.qread();

			if (m === null)
				return;

			if (m === false)
				return gone('lookup socket error');

			if (m.port != QRTR_PORT_CTRL)
				continue;

			let c = parse_ctrl(m.data);

			if (!c || c.node != node)
				continue;

			let skey = sprintf('%d', c.service);

			// a deletion names the endpoint it deletes: one whose service has
			// meanwhile re-registered on another port is already superseded,
			// and acting on it would drop the live mapping — for DMS, declare
			// a modem gone that just came back (the name server reports in
			// event order per lookup, but a restart's NEW for the new port and
			// DEL for the old one are two events)
			if (c.cmd == 'del' && self.svc_addr[skey] != c.port)
				continue;

			if (c.cmd == 'del' && c.service == discovery.QRTR_SVC_DMS)
				return gone('DMS left the bus');

			// DMS on a NEW port is DMS restarted, whichever of the two
			// reports comes first: every modem-side client is gone with it,
			// so the hub must be rebuilt, not re-pointed
			if (c.cmd == 'new' && c.service == discovery.QRTR_SVC_DMS &&
			    self.svc_addr[skey] != null && self.svc_addr[skey] != c.port)
				return gone('DMS re-registered on another port');

			if (c.cmd == 'del')
				delete self.svc_addr[skey];
			else
				self.svc_addr[skey] = c.port;
		}
	}, uloop.ULOOP_READ);

	if (!self._uh) {
		lookup.close();

		return null;
	}

	return self;
};
