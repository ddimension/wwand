// wwand — lazy-load shim for the MBIM modules.
//
// daemon.uc pulls MBIM in only when an MBIM modem actually shows up (saves
// ~228 KB RSS on QMI-only systems). ucode's require() compiles plain scripts,
// and in a plain script `export` is a syntax error — but `import` is allowed.
// This wrapper is that plain script: it imports the real ES modules (loading
// them through the proper module path) and hands them back as a value.
'use strict';

import * as modem from './modem_mbim.uc';
import * as context from './context_mbim.uc';

return { modem: modem, context: context };
