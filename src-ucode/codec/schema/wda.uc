// wwand — QMI WDA service message schema (service 0x1A).
// TLV layouts verified against libqmi data/qmi-service-wda.json.

'use strict';

// QmiWdaLinkLayerProtocol
export const LLP_802_3 = 1;
export const LLP_RAW_IP = 2;

// QmiWdaDataAggregationProtocol
export const DAP_DISABLED = 0;
export const DAP_QMAP = 5;
export const DAP_QMAPV5 = 8;

// QmiDataEndpointType
export const ENDPOINT_TYPE_HSUSB = 2;
export const ENDPOINT_TYPE_PCIE = 3;
export const ENDPOINT_TYPE_EMBEDDED = 4;

const FORMAT_FIELDS_RESP = {
	qos:              { t: 0x10, f: 'u8' },
	llp:              { t: 0x11, f: 'u32' },
	ul_protocol:      { t: 0x12, f: 'u32' },
	dl_protocol:      { t: 0x13, f: 'u32' },
	ndp_signature:    { t: 0x14, f: 'u32' },
	dl_max_datagrams: { t: 0x15, f: 'u32' },
	dl_max_size:      { t: 0x16, f: 'u32' },
	ul_max_datagrams: { t: 0x17, f: 'u32' },
	ul_max_size:      { t: 0x18, f: 'u32' },
};

export default {
	service: 0x1A,
	messages: {
		SET_DATA_FORMAT: {
			id: 0x0020,
			req: {
				qos:              { t: 0x10, f: 'u8' },
				llp:              { t: 0x11, f: 'u32' },
				ul_protocol:      { t: 0x12, f: 'u32' },
				dl_protocol:      { t: 0x13, f: 'u32' },
				dl_max_datagrams: { t: 0x15, f: 'u32' },
				dl_max_size:      { t: 0x16, f: 'u32' },
				endpoint:         { t: 0x17, f: { type: 'u32', iface: 'u32' } },
			},
			resp: FORMAT_FIELDS_RESP,
		},

		GET_DATA_FORMAT: {
			id: 0x0021,
			req: {
				endpoint: { t: 0x10, f: { type: 'u32', iface: 'u32' } },
			},
			resp: FORMAT_FIELDS_RESP,
		},
	},
};
