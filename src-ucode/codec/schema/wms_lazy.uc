// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 André Valentin <avalentin@marcant.net>
// wwand — lazy-load shim for the QMI WMS (SMS) schema.
//
// wms.uc is only needed when SMS is actually used (modem_sms_*), so the WMS
// client is allocated on demand (modem._ensure_wms) rather than eagerly at
// modem init — keeping the schema off the heap until the first SMS operation.
// Exportless plain script (require()-able); `import` is allowed, `export` isn't.
'use strict';

import * as wms from './wms.uc';

return { s: wms };
