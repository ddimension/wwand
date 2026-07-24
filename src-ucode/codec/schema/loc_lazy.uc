// wwand — lazy-load shim for the QMI LOC schema.
//
// loc.uc is a ~100 kB (parsed) schema only needed when a modem enables GPS
// (`option location`). Keeping it out of modem.uc's eager top-level imports and
// require()ing it on demand keeps it off the heap on the common (GPS-off) path.
// Exportless plain script (require()-able); `import` is allowed, `export` isn't.
'use strict';

import * as loc from './loc.uc';

return { s: loc };
