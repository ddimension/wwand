// wwand — MBIM Quectel vendor service schema (FCC RF unlock).
//
// Laptop-SKU Quectel modems in MBIM mode (e.g. EM120R-GL / EM160R-GL in
// Lenovo machines) ship RF-locked; the host releases them by setting the
// vendor Radio State to on. This mirrors ModemManager's fcc-unlock helper
// (`mbimcli --quectel-set-radio-state=on`).
//
// Verified against libmbim 1.32.0:
//   UUID  src/libmbim-glib/mbim-uuid.c uuid_quectel =
//         { 11 22 33 44 } { 55 66 } { 77 88 } { 99 aa } { bb cc dd ee ff 11 }
//         -> "11223344-5566-7788-99aa-bbccddeeff11"
//   CID   src/libmbim-glib/mbim-cid.h MBIM_CID_QUECTEL_RADIO_STATE = 1
//   Body  data/mbim-service-quectel.json "Radio State": set = RadioState u32,
//         response = RadioState u32 (MbimQuectelRadioSwitchState).

'use strict';

export const SERVICE_UUID = '11223344-5566-7788-99aa-bbccddeeff11';
export const service = SERVICE_UUID;

// MbimQuectelRadioSwitchState
export const RADIO_OFF = 0;
export const RADIO_ON = 1;
export const RADIO_FCC_LOCKED = 2;

export const commands = {
	RADIO_STATE: {
		cid: 1,
		set: { radio_state: 'u32' },
		query: {},
		response: { radio_state: 'u32' },
	},
};

export default commands;
