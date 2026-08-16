// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 André Valentin <avalentin@marcant.net>
// wwand — lazy-load shim for the MBIM modules.
//
// daemon.uc pulls MBIM in only when an MBIM modem actually shows up (saves
// ~228 KB RSS on QMI-only systems). ucode's require() compiles plain scripts,
// and in a plain script `export` is a syntax error — but `import` is allowed.
// This wrapper is that plain script: it imports the real ES modules (loading
// them through the proper module path) and hands them back as a value.
'use strict';

import * as modem from 'wwand.modem_mbim';
import * as context from 'wwand.context_mbim';

return { modem: modem, context: context };
