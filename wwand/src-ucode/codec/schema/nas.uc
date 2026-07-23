// wwand — QMI NAS service message schema (service 0x03).
// TLV layouts verified against libqmi data/qmi-service-nas.json.

'use strict';

// QmiNasServiceStatus (LTE service status): the "limited service" states mean
// the modem camps on a cell but cannot use it (attach rejected / emergency-only)
export const SVC_STATUS_NONE = 0;
export const SVC_STATUS_LIMITED = 1;
export const SVC_STATUS_AVAILABLE = 2;
export const SVC_STATUS_LIMITED_REGIONAL = 3;

// EMM / MM reject cause text (3GPP TS 24.301 §9.9.3.9 / TS 24.008) — the common
// ones seen in the field; unknown codes are shown numerically by the caller
export const REJECT_CAUSE = {
	'2':  'IMSI unknown in HLR',
	'3':  'illegal MS',
	'6':  'illegal ME',
	'7':  'EPS services not allowed',
	'8':  'EPS and non-EPS services not allowed',
	'9':  'UE identity cannot be derived',
	'10': 'implicitly detached',
	'11': 'PLMN not allowed',
	'12': 'tracking area not allowed',
	'13': 'roaming not allowed in this tracking area',
	'14': 'EPS services not allowed in this PLMN',
	'15': 'no suitable cells in tracking area',
	'22': 'congestion',
	'25': 'not authorized for this CSG',
	'33': 'requested service option not subscribed',
	'34': 'service option temporarily out of order',
	'35': 'requested service option not subscribed (35)',
	'42': 'severe network failure',
};

// QmiNasRegistrationState
export const REG_NOT_REGISTERED = 0;
export const REG_REGISTERED = 1;
export const REG_SEARCHING = 2;
export const REG_DENIED = 3;
export const REG_UNKNOWN = 4;

// QmiNasRadioInterface
export const RADIO_IF_CDMA_1X = 1;
export const RADIO_IF_CDMA_1XEVDO = 2;
export const RADIO_IF_GSM = 4;
export const RADIO_IF_UMTS = 5;
export const RADIO_IF_LTE = 8;
export const RADIO_IF_TD_SCDMA = 9;
export const RADIO_IF_5GNR = 12;

// QmiNasRatModePreference bits — config 'modes' string maps onto these
export const MODE_BITS = {
	cdma:       (1 << 0) | (1 << 1),
	gsm:        (1 << 2),
	umts:       (1 << 3),
	lte:        (1 << 4),
	'td-scdma': (1 << 5),
	nr5g:       (1 << 6),
};

export const MODE_ALL = (1 << 0) | (1 << 1) | (1 << 2) | (1 << 3) |
                        (1 << 4) | (1 << 5) | (1 << 6);

// QmiNasNetworkSelectionPreference
export const NETWORK_SELECTION_AUTOMATIC = 0;
export const NETWORK_SELECTION_MANUAL = 1;

// QmiNasNetworkStatus bitmask (Network Scan → Network Information element).
// Verified against libqmi 1.38 qmi-enums-nas.h.
export const NET_STATUS_CURRENT_SERVING = (1 << 0);
export const NET_STATUS_AVAILABLE       = (1 << 1);
export const NET_STATUS_FORBIDDEN       = (1 << 4);

// field specs shared verbatim across the get/indication message pairs below
// (the messages differ only in id and, for serving system, the lac/cell/tac
// TLV ids, which stay inline)
const SERVING_SYSTEM_F = { t: 0x01, f: {
	registration:     'u8',
	cs_attach:        'u8',
	ps_attach:        'u8',
	selected_network: 'u8',
	radio_ifs:        { n: 'u8', of: 'u8' },
} };
const ROAMING_F = { t: 0x10, f: 'u8' };
// the network description is a u8-length-prefixed string (some modems GSM-7-bit
// pack the name — decoded in modem._update_serving); 'lstring' strips the
// length byte that a plain 'string' would leak in as a leading control char
const CURRENT_PLMN_F = { t: 0x12, f: { mcc: 'u16', mnc: 'u16', description: 'lstring' } };
const SIGNAL_INFO_F = {
	gsm_rssi:  { t: 0x12, f: 'i8' },
	wcdma:     { t: 0x13, f: { rssi: 'i8', ecio: 'i16' } },
	lte:       { t: 0x14, f: { rssi: 'i8', rsrq: 'i8', rsrp: 'i16', snr: 'i16' } },
	nr5g:      { t: 0x17, f: { rsrp: 'i16', snr: 'i16' } },
	nr5g_rsrq: { t: 0x18, f: 'i16' },
};

export default {
	service: 0x03,
	messages: {
		REGISTER_INDICATIONS: {
			id: 0x0003,
			req: {
				system_selection_preference: { t: 0x10, f: 'u8' },
				serving_system_events:       { t: 0x13, f: 'u8' },
				network_time:                { t: 0x17, f: 'u8' },
				system_info:                 { t: 0x18, f: 'u8' },
				signal_info:                 { t: 0x19, f: 'u8' },
			},
			resp: {},
		},

		GET_SERVING_SYSTEM: {
			id: 0x0024,
			req: {},
			resp: {
				serving_system: SERVING_SYSTEM_F,
				roaming:      ROAMING_F,
				current_plmn: CURRENT_PLMN_F,
				lac:          { t: 0x1C, f: 'u16' },
				cell_id:      { t: 0x1D, f: 'u32' },
				lte_tac:      { t: 0x24, f: 'u16' },
			},
		},

		SERVING_SYSTEM_IND: {
			id: 0x0024,
			ind: {
				serving_system: SERVING_SYSTEM_F,
				roaming:      ROAMING_F,
				current_plmn: CURRENT_PLMN_F,
				lac:          { t: 0x1D, f: 'u16' },
				cell_id:      { t: 0x1E, f: 'u32' },
				lte_tac:      { t: 0x25, f: 'u16' },
			},
		},

		// Perform Network Scan — the COPS=? equivalent: the modem sweeps the
		// visible PLMNs and returns the operator list. Slow (seconds); the
		// caller passes a long timeout. Verified against libqmi 1.38
		// qmi-service-nas.json (msg 0x0021):
		//   request  Network Type 0x10 (guint8 QmiNasNetworkScanType) — optional;
		//            an empty request scans every RAT.
		//   response Network Information 0x10 = guint16-count array of
		//            { mcc:u16, mnc:u16, network_status:u8, description }. The
		//            description is u8-length-prefixed on the wire (as the
		//            serving-system Current PLMN name is) → 'lstring'; confirmed
		//            against the libqmi test-generated.c NAS Network Scan buffer.
		//   response Radio Access Technology 0x11 = the RAT per PLMN (gint8).
		NETWORK_SCAN: {
			id: 0x0021,
			req: {
				network_type: { t: 0x10, f: 'u8' },
			},
			resp: {
				network_information: { t: 0x10, f: { n: 'u16', of: {
					mcc: 'u16', mnc: 'u16', network_status: 'u8', description: 'lstring' } } },
				radio_access_technology: { t: 0x11, f: { n: 'u16', of: {
					mcc: 'u16', mnc: 'u16', radio_interface: 'i8' } } },
			},
		},

		// NOTE: request and response TLV ids DIFFER for several fields
		// (usage 0x21/0x1F, ext lte 0x24/0x23, nr5g sa 0x2F/0x2C, nsa
		// 0x30/0x2D) — verified against libqmi 1.38 qmi-service-nas.json
		SET_SYSTEM_SELECTION_PREFERENCE: {
			id: 0x0033,
			req: {
				mode_preference:   { t: 0x11, f: 'u16' },
				band_preference:   { t: 0x12, f: 'u64' },
				roaming_preference:{ t: 0x14, f: 'u16' },
				lte_band_preference:{ t: 0x15, f: 'u64' },
				network_selection: { t: 0x16, f: { mode: 'u8', mcc: 'u16', mnc: 'u16' } },
				// QmiNasChangeDuration: 0 = until power cycle, 1 = permanent
				change_duration:   { t: 0x17, f: 'u8' },
				usage_preference:  { t: 0x21, f: 'u32' },
				ext_lte_band: { t: 0x24, f: {
					mask_low: 'u64', mask_mid_low: 'u64',
					mask_mid_high: 'u64', mask_high: 'u64' } },
				nr5g_sa_band: { t: 0x2F, f: {
					m0: 'u64', m1: 'u64', m2: 'u64', m3: 'u64',
					m4: 'u64', m5: 'u64', m6: 'u64', m7: 'u64' } },
				nr5g_nsa_band: { t: 0x30, f: {
					m0: 'u64', m1: 'u64', m2: 'u64', m3: 'u64',
					m4: 'u64', m5: 'u64', m6: 'u64', m7: 'u64' } },
			},
			resp: {},
		},

		GET_SYSTEM_SELECTION_PREFERENCE: {
			id: 0x0034,
			req: {},
			resp: {
				mode_preference:   { t: 0x11, f: 'u16' },
				band_preference:   { t: 0x12, f: 'u64' },
				roaming_preference:{ t: 0x14, f: 'u16' },
				lte_band_preference:{ t: 0x15, f: 'u64' },
				network_selection: { t: 0x16, f: 'u8' },
				usage_preference:  { t: 0x1F, f: 'u32' },
				disabled_modes:    { t: 0x22, f: 'u16' },
				ext_lte_band: { t: 0x23, f: {
					mask_low: 'u64', mask_mid_low: 'u64',
					mask_mid_high: 'u64', mask_high: 'u64' } },
				nr5g_sa_band: { t: 0x2C, f: {
					m0: 'u64', m1: 'u64', m2: 'u64', m3: 'u64',
					m4: 'u64', m5: 'u64', m6: 'u64', m7: 'u64' } },
				nr5g_nsa_band: { t: 0x2D, f: {
					m0: 'u64', m1: 'u64', m2: 'u64', m3: 'u64',
					m4: 'u64', m5: 'u64', m6: 'u64', m7: 'u64' } },
			},
		},

		GET_CELL_LOCATION_INFO: {
			id: 0x0043,
			req: {},
			// decoded subset: LTE serving + intra-frequency neighbours and
			// NR5G serving cell (rsrp/rsrq/snr values are in 0.1 dB units)
			resp: {
				lte_intra: { t: 0x13, f: {
					ue_idle:           'u8',
					plmn:              'plmn',
					tac:               'u16',
					global_cell_id:    'u32',
					earfcn:            'u16',
					serving_cell_id:   'u16',
					resel_priority:    'u8',
					s_non_intra_search:'u8',
					thresh_serving_low:'u8',
					s_intra_search:    'u8',
					cells: { n: 'u8', of: {
						pci:    'u16',
						rsrq:   'i16',
						rsrp:   'i16',
						rssi:   'i16',
						srxlev: 'i16',
					} },
				} },
				// inter-frequency LTE neighbours: a list of frequencies, each
				// carrying its own neighbour-cell list. These are the extra
				// cells qmicli --nas-get-cell-location-info shows on top of the
				// intra-frequency set above.
				lte_inter: { t: 0x14, f: {
					ue_idle: 'u8',
					freqs: { n: 'u8', of: {
						earfcn:         'u16',
						thresh_low:     'u8',
						thresh_high:    'u8',
						resel_priority: 'u8',
						cells: { n: 'u8', of: {
							pci:    'u16',
							rsrq:   'i16',
							rsrp:   'i16',
							rssi:   'i16',
							srxlev: 'i16',
						} },
					} },
				} },
				lte_timing_advance: { t: 0x1E, f: 'u32' },
				nr5g_arfcn:         { t: 0x2E, f: 'u32' },
				nr5g_cell: { t: 0x2F, f: {
					plmn:           'plmn',
					tac:            'u24be',
					global_cell_id: 'u64',
					pci:            'u16',
					rsrq:           'i16',
					rsrp:           'i16',
					snr:            'i16',
				} },
			},
		},

		// LTE carrier-aggregation info: serving PCell + active SCells with
		// EARFCN, DL bandwidth (QmiNasDLBandwidth: 0=1.4 1=3 2=5 3=10 4=15
		// 5=20 MHz) and band. Preferred bandwidth source; some modems answer
		// INFO_UNAVAILABLE and the caller falls back to AT+QCAINFO. Verified
		// against libqmi 1.38 qmi-service-nas.json (msg 0x00AC).
		GET_LTE_CPHY_CA_INFO: {
			id: 0x00AC,
			req: {},
			resp: {
				pcell: { t: 0x13, f: {
					pci:          'u16',
					earfcn:       'u16',
					dl_bandwidth: 'u32',
					band:         'u16',
				} },
				scells: { t: 0x15, f: { n: 'u8', of: {
					pci:          'u16',
					earfcn:       'u16',
					dl_bandwidth: 'u32',
					band:         'u16',
					state:        'u32',
					cell_index:   'u8',
				} } },
			},
		},

		// System info — used for the EMM registration reject cause and the
		// limited-service flag when a modem camps but the attach is rejected
		// (e.g. cause 33 on an IPv4-only attach). The reject cause lives inside
		// the big "LTE System Info v2" sequence TLV; we model only the fixed
		// leading fields up to reject_cause and ignore the trailing ones.
		GET_SYSTEM_INFO: {
			id: 0x004D,
			req: {},
			resp: {
				// QmiNasServiceStatus: 0 none, 1 limited, 2 available,
				// 3 limited-regional
				lte_service_status: { t: 0x14, f: {
					status: 'u8', true_status: 'u8' } },
				lte_sys_info: { t: 0x19, f: {
					domain_valid: 'u8', domain: 'u8',
					srv_cap_valid: 'u8', srv_cap: 'u8',
					roaming_valid: 'u8', roaming: 'u8',
					forbidden_valid: 'u8', forbidden: 'u8',
					lac_valid: 'u8', lac: 'u16',
					cid_valid: 'u8', cid: 'u32',
					reject_valid: 'u8', reject_domain: 'u8', reject_cause: 'u8',
				} },
			},
		},

		GET_SIGNAL_INFO: {
			id: 0x004F,
			req: {},
			resp: SIGNAL_INFO_F,
		},

		SIGNAL_INFO_IND: {
			id: 0x0051,
			ind: SIGNAL_INFO_F,
		},
	},
};
