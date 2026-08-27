// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 André Valentin <avalentin@marcant.net>
// wwand — lazy-load shim for the AT-over-MBIM transport.
//
// modem_common reaches for this only when a modem has no AT tty, and it lives
// in the wwand-mbim package (it needs mbim_client + codec/mbim), so the base
// package must not import it at top level. Same plain-script trick as
// mbim_lazy.uc: require() compiles plain scripts, where `export` is a syntax
// error but `import` is fine.
'use strict';

import * as atmbim from 'wwand.atcmd_mbim';

return atmbim;
