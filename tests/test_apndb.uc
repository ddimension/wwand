// wwand tests — internal ICCID/IMSI-prefix APN table (autosetup phase 2).

'use strict';

import { eq, done } from './lib/check.uc';
import * as apndb from 'wwand/apndb.uc';

// ICCID-keyed entry
eq(apndb.lookup('89490200001022832490', '262011234567890')?.apn,
	'internet.v6.telekom', 'apndb: Telekom via ICCID prefix');

// IMSI-keyed entry (Vodafone GDSP — the Cudy deployment SIM)
let g = apndb.lookup('89882390000587072730', '901280078243712');
eq(g?.apn, 'apn.global-m2m.net', 'apndb: GDSP via IMSI prefix');
eq(g?.pdp_type, 'ipv4v6', 'apndb: GDSP pdp type');
eq(g?.auth, 'both', 'apndb: GDSP auth');
eq(g?.username, 'gdsp', 'apndb: GDSP username');
eq(g?.password, 'gdsp', 'apndb: GDSP password');

// no match / null identities
eq(apndb.lookup('8999999999999', '999990000000000'), null, 'apndb: no match -> null');
eq(apndb.lookup(null, null), null, 'apndb: null identities -> null');

// lookup returns a copy — callers must not be able to poison the table
let a = apndb.lookup('8988280111222333', null);
a.apn = 'clobbered';
eq(apndb.lookup('8988280111222333', null)?.apn, 'iot.1nce.net',
	'apndb: table immutable (copy returned)');

done('test_apndb');
