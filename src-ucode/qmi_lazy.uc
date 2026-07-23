// wwand — lazy-load shim for the QMI modules.
//
// QMI ships as its own package (wwand-qmi) so a pure-MBIM or pure-NCM install
// need not carry it — and so wwand-mbim can depend on it explicitly (the MBIM
// backend reuses qmi_backend over the QMI-over-MBIM passthrough). daemon.uc
// require()s this wrapper only when a QMI modem shows up. ucode's require()
// compiles plain scripts, where `export` is a syntax error but `import` is
// allowed — so this exportless plain script imports the real ES modules and
// hands them back as a value (same trick as mbim_lazy / ncm_lazy).
'use strict';

import * as modem from './modem.uc';
import * as context from './context.uc';

return { modem: modem, context: context };
