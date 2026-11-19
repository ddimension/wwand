// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 André Valentin <avalentin@marcant.net>
// wwand — lazy-load shim for the QMI Voice (USSD) schema, like wms_lazy.uc:
// required by modem._ensure_voice only, which runs at the first registration
// (ussd.arm, to hear network-initiated USSD) and only on a modem that lists
// the Voice service — so a modem without it never loads the schema.
// Exportless plain script (require()-able); `import` is allowed, `export` isn't.
'use strict';

import * as voice from 'wwand.codec.schema.voice';

return { s: voice };
