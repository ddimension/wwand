// wwand — lazy-load shim for the NCM modules.
//
// daemon.uc pulls NCM in only when an NCM modem actually shows up. ucode's
// require() compiles plain scripts, and in a plain script `export` is a syntax
// error — but `import` is allowed. This wrapper is that plain script: it imports
// the real ES modules (loading them through the proper module path) and hands
// them back as a value. Mirrors mbim_lazy.uc.
'use strict';

import * as modem from './modem_ncm.uc';
import * as context from './context_ncm.uc';

return { modem: modem, context: context };
