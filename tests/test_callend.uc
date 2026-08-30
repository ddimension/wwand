// wwand tests — call-end / activation-failure reason text.

'use strict';

import { eq, ok, done } from './lib/check.uc';
import * as callend from 'wwand/callend.uc';

// 3GPP (type 6) SM causes -> the actionable messages
eq(callend.describe(null, { type: 6, reason: 29 }).text, 'user authentication failed', 'auth failed');
eq(callend.describe(null, { type: 6, reason: 27 }).text, 'missing or unknown APN', 'unknown APN');
eq(callend.describe(null, { type: 6, reason: 8 }).text, 'operator determined barring', 'ODB');
eq(callend.describe(null, { type: 6, reason: 33 }).text, 'requested service option not subscribed', 'not subscribed');

let d = callend.describe(2, { type: 6, reason: 29 }, 17);
eq(d.code, 29, 'code carried');
eq(d.type, 6, 'type carried');
eq(d.type_name, '3GPP', 'type name');
eq(d.ext_error, 17, 'ext error carried');

// unknown 3GPP cause -> generic but still typed
eq(callend.describe(null, { type: 6, reason: 200 }).text, '3GPP cause 200', 'unknown 3gpp cause');

// non-3GPP verbose type -> named type + code
eq(callend.describe(null, { type: 3, reason: 5 }).text, 'call manager cause 5', 'CM type generic');
eq(callend.describe(null, { type: 99, reason: 1 }).text, 'type 99 cause 1', 'unknown type generic');

// verbose type 2 (modem-internal, libqmi VERBOSE_CALL_END_REASON_INTERNAL)
eq(callend.describe(null, { type: 2, reason: 204 }).text, 'unknown cause code', 'internal 204 named');
eq(callend.describe(null, { type: 2, reason: 206 }).text, 'network-initiated termination', 'internal 206 named');
// 241 is libqmi's INTERFACE_IN_USE_CONFIG_MATCH. This assertion used to demand
// "PDP context already in use", which is the meaning of 236 — the test froze the
// mislabelling in place, which is why it survived so long.
eq(callend.describe(null, { type: 2, reason: 241 }).text,
	'interface in use, config matches an existing call', 'internal 241 named');
eq(callend.describe(null, { type: 2, reason: 236 }).text,
	'call already present', 'internal 236 is the OTHER one');

// the table used to stop at 220, so everything above it fed the recovery ladder
// a bare number — including the reasons that say retrying cannot help
eq(callend.describe(null, { type: 2, reason: 243 }).text,
	'thermal mitigation', 'internal 243: the modem is hot, not broken');
eq(callend.describe(null, { type: 2, reason: 255 }).text,
	'call disallowed in roaming', 'internal 255 named');

// verbose type 3 (call manager) had no table at all
eq(callend.describe(null, { type: 3, reason: 523 }).text,
	'thermal emergency', 'cm 523 named');
eq(callend.describe(null, { type: 3, reason: 1010 }).text,
	'PLMN not allowed', 'cm 1010 named');
eq(callend.describe(null, { type: 3, reason: 1053 }).text,
	'LTE RRC connection establishment failure access barred', 'cm 1053 named');
eq(callend.describe(null, { type: 3, reason: 99999 }).text,
	'call manager cause 99999', 'cm fallback keeps the type name');

// 0x0C is past libqmi's type enum but is emitted on a handoff teardown
eq(callend.describe(null, { type: 12, reason: 7 }).type_name,
	'handoff', 'type 0x0C is named, not "type 12"');
eq(callend.describe(null, { type: 2, reason: 999 }).text, 'internal cause 999', 'internal fallback keeps type name');

// coarse reason only / ext only / nothing
eq(callend.describe(1, null).text, 'unspecified', 'coarse reason 1 named');
eq(callend.describe(6, null).text, 'access attempt in progress', 'coarse reason 6 named');
eq(callend.describe(503, null).text, 'call ended (reason 503)', 'coarse reason fallback (unmapped)');
eq(callend.describe(null, null, 42).text, 'activation failed (ext error 42)', 'ext-error fallback');
eq(callend.describe(null, null), null, 'nothing -> null');

done('test_callend');
