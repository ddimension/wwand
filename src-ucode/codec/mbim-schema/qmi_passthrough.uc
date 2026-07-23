// wwand — MBIM "QMI over MBIM" passthrough service (MBIM 1.14+).
//
// A single CID that tunnels a raw QMI/QMUX frame in either direction: the
// request carries a QMUX frame as its opaque InformationBuffer, the response
// carries the QMUX reply, and unsolicited QMI indications arrive as
// INDICATE_STATUS on the same CID. Quectel (and most Qualcomm) modems expose it,
// so wwand's whole QMI stack (client.uc / qmux / tlv / schemas / qmi_backend)
// can run over an MBIM control channel unchanged — see qmi_over_mbim.uc.
//
// Service UUID verified against libmbim mbim-uuid.c (uuid_qmi, MBIM_SERVICE_QMI).
// The InformationBuffer is opaque bytes, not a schema struct, so the transport
// uses mbim_client.command_raw()/on() with the raw msg.info rather than the
// field codec; commands[] exists only so mbim_client.on() can resolve the CID.

'use strict';

export const SERVICE_UUID = 'd1a30bc2-f97a-6e43-bf65-c7e24fb0f0d3';
export const service = SERVICE_UUID;

export const CID_QMI_MSG = 1;

export const commands = {
	QMI_MSG: { cid: 1, notification: {} },
};

export default commands;
