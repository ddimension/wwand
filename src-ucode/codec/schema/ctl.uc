// wwand — QMI CTL service message schema (service 0x00).
// Message/TLV ids verified against libqmi 1.38 qmi-service-ctl.json (CTL is
// spec-stable; ids unchanged since libqmi 1.0).

'use strict';

export default {
	service: 0x00,
	messages: {
		GET_VERSION_INFO: {
			id: 0x0021,
			req:  {},
			resp: {
				services: { t: 0x01, f: { n: 'u8', of: {
					service: 'u8',
					major:   'u16',
					minor:   'u16',
				} } },
			},
		},

		ALLOCATE_CID: {
			id: 0x0022,
			req:  { service:    { t: 0x01, f: 'u8' } },
			resp: { allocation: { t: 0x01, f: { service: 'u8', cid: 'u8' } } },
		},

		RELEASE_CID: {
			id: 0x0023,
			req:  { release: { t: 0x01, f: { service: 'u8', cid: 'u8' } } },
			resp: { release: { t: 0x01, f: { service: 'u8', cid: 'u8' } } },
		},

		SYNC: {
			id: 0x0027,
			req:  {},
			resp: {},
			// also sent by the modem as indication after (re)boot
			ind:  {},
		},
	},
};
