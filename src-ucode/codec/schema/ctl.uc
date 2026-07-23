// wwand — QMI CTL service message schema (service 0x00).

'use strict';

export default {
	service: 0x00,
	messages: {
		SET_INSTANCE_ID: {
			id: 0x0020,
			req:  { instance: { t: 0x01, f: 'u8' } },
			resp: { link:     { t: 0x01, f: 'u16' } },
		},

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
