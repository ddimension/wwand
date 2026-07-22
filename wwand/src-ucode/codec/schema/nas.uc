// wwand — QMI NAS service message schema (service 0x03).
// TLV layouts verified against libqmi data/qmi-service-nas.json.

'use strict';

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
				serving_system: { t: 0x01, f: {
					registration:     'u8',
					cs_attach:        'u8',
					ps_attach:        'u8',
					selected_network: 'u8',
					radio_ifs:        { n: 'u8', of: 'u8' },
				} },
				roaming:      { t: 0x10, f: 'u8' },
				current_plmn: { t: 0x12, f: { mcc: 'u16', mnc: 'u16', description: 'string' } },
				lac:          { t: 0x1C, f: 'u16' },
				cell_id:      { t: 0x1D, f: 'u32' },
				lte_tac:      { t: 0x24, f: 'u16' },
			},
		},

		SERVING_SYSTEM_IND: {
			id: 0x0024,
			ind: {
				serving_system: { t: 0x01, f: {
					registration:     'u8',
					cs_attach:        'u8',
					ps_attach:        'u8',
					selected_network: 'u8',
					radio_ifs:        { n: 'u8', of: 'u8' },
				} },
				roaming:      { t: 0x10, f: 'u8' },
				current_plmn: { t: 0x12, f: { mcc: 'u16', mnc: 'u16', description: 'string' } },
				lac:          { t: 0x1D, f: 'u16' },
				cell_id:      { t: 0x1E, f: 'u32' },
				lte_tac:      { t: 0x25, f: 'u16' },
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
				// 0 = permanent, 1 = power-cycle
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

		GET_SIGNAL_INFO: {
			id: 0x004F,
			req: {},
			resp: {
				gsm_rssi:  { t: 0x12, f: 'i8' },
				wcdma:     { t: 0x13, f: { rssi: 'i8', ecio: 'i16' } },
				lte:       { t: 0x14, f: { rssi: 'i8', rsrq: 'i8', rsrp: 'i16', snr: 'i16' } },
				nr5g:      { t: 0x17, f: { rsrp: 'i16', snr: 'i16' } },
				nr5g_rsrq: { t: 0x18, f: 'i16' },
			},
		},

		SIGNAL_INFO_IND: {
			id: 0x0051,
			ind: {
				gsm_rssi:  { t: 0x12, f: 'i8' },
				wcdma:     { t: 0x13, f: { rssi: 'i8', ecio: 'i16' } },
				lte:       { t: 0x14, f: { rssi: 'i8', rsrq: 'i8', rsrp: 'i16', snr: 'i16' } },
				nr5g:      { t: 0x17, f: { rsrp: 'i16', snr: 'i16' } },
				nr5g_rsrq: { t: 0x18, f: 'i16' },
			},
		},
	},
};
