// wwand — QMUX framing for QMI-over-cdc-wdm.
//
// Frame layout:
//   [if_type=0x01] [len u16le] [ctrl_flags u8] [service u8] [client u8] [SDU]
//   len = complete frame length minus the 1-byte if_type marker.
// SDU layout:
//   CTL (service 0):  [flags u8] [txn u8]    [msg_id u16le] [msg_len u16le] [TLVs]
//     flags: 0x00 request, 0x01 response, 0x02 indication
//   other services:   [flags u8] [txn u16le] [msg_id u16le] [msg_len u16le] [TLVs]
//     flags: 0x00 request, 0x02 response, 0x04 indication
//
// decode() returns null on garbage and never throws.

'use strict';

import * as struct from 'struct';

export const QMI_SERVICE_CTL = 0x00;

// kind: 'request' (default) | 'response' | 'indication' — the latter two are
// used by tests/mocks to synthesize modem-to-host frames.
export function encode(service, cid, txn, msg_id, tlv_bytes, kind)
{
	tlv_bytes = tlv_bytes ?? '';

	let sdu, sflags, sender;

	if (kind == 'response')
		sflags = (service == QMI_SERVICE_CTL) ? 0x01 : 0x02;
	else if (kind == 'indication')
		sflags = (service == QMI_SERVICE_CTL) ? 0x02 : 0x04;
	else
		sflags = 0x00;

	sender = sflags ? 0x80 : 0x00;

	if (service == QMI_SERVICE_CTL)
		sdu = struct.pack('<BB', sflags, txn & 0xff);
	else
		sdu = struct.pack('<BH', sflags, txn & 0xffff);

	sdu += struct.pack('<HH', msg_id, length(tlv_bytes)) + tlv_bytes;

	return struct.pack('<BHBBB', 0x01, 5 + length(sdu), sender, service, cid) + sdu;
}

export function decode(buf)
{
	let len = length(buf ?? '');

	// smallest valid frame: 6 byte QMUX header + 6 byte CTL SDU
	if (len < 12 || ord(buf, 0) != 0x01)
		return null;

	let h = struct.unpack('<HBBB', substr(buf, 1, 5));
	let qlen = h[0], flags = h[1], service = h[2], cid = h[3];

	if (qlen + 1 > len)
		return null;

	let pos = 6;
	let sflags = ord(buf, pos++);
	let txn, kind;

	if (service == QMI_SERVICE_CTL) {
		txn = ord(buf, pos++);
		kind = (sflags & 0x02) ? 'indication' : ((sflags & 0x01) ? 'response' : 'request');
	}
	else {
		if (pos + 2 > len)
			return null;

		txn = struct.unpack('<H', substr(buf, pos, 2))[0];
		pos += 2;
		kind = (sflags & 0x04) ? 'indication' : ((sflags & 0x02) ? 'response' : 'request');
	}

	if (pos + 4 > len)
		return null;

	let mh = struct.unpack('<HH', substr(buf, pos, 4));

	pos += 4;

	let mlen = mh[1];

	// tolerate short frames, tlv.unpack() flags truncation
	if (pos + mlen > len)
		mlen = len - pos;

	return {
		service: service,
		cid: cid,
		sender: flags,
		kind: kind,
		txn: txn,
		msg_id: mh[0],
		tlvs: substr(buf, pos, mlen),
	};
}
