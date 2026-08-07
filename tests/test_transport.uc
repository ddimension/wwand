// wwand tests — transport.uc hub over a fake native handle (the io_open
// injection seam): tx queueing on EAGAIN, the 64-frame congestion cap, the
// flush retry timer, dispatch routing (targeted / broadcast 0xff / unhandled)
// and close() semantics. No real device involved; the fake's fileno() hands
// uloop an idle pipe read end so the handle registration is real.
'use strict';

import { eq, ok, done } from './lib/check.uc';
import * as uloop from 'uloop';
import * as fs from 'fs';
import * as transport from 'wwand/transport.uc';

uloop.init();

// idle fd for uloop.handle: the read end of a fresh pipe never becomes readable
let pipe_r, pipe_w;
let pp = fs.pipe();
pipe_r = pp[0]; pipe_w = pp[1];

// --- fake native handle ------------------------------------------------------

let written = [];
let congested = false;
let closed = 0;

let fake = {
	write:  (frame) => congested ? 0 : (push(written, frame), length(frame)),
	read:   () => null,
	fileno: () => pipe_r.fileno(),
	close:  () => closed++,
};

// open failure passthrough
eq(transport.open('/dev/null', { io_open: () => null }), null, 'open: io_open failure -> null');

let hub = transport.open('/dev/fake0', { io_open: () => fake });

ok(hub != null, 'open: hub created over the fake handle');

// --- direct send (uncongested) ----------------------------------------------

ok(hub.send('frameA'), 'send: accepted');
eq(written, [ 'frameA' ], 'send: written straight through');

// --- congestion: queue + cap -------------------------------------------------

congested = true;

ok(hub.send('q0'), 'send: EAGAIN frame queued, still reported ok');

for (let i = 1; i <= 64; i++)
	hub.send(sprintf('q%d', i));

eq(hub.send('overflow'), false, 'send: >64 queued frames -> reported congested');
eq(length(written), 1, 'send: nothing written while congested');

// --- flush retry: congestion clears, timer drains the queue in order ---------

congested = false;

let guard = uloop.timer(2000, () => uloop.end());
let poll;
poll = () => {
	if (length(written) >= 66)
		return uloop.end();
	uloop.timer(10, poll);
};
poll();
uloop.run();
guard.cancel();

eq(length(written), 66, 'flush: full queue drained after congestion clears');
eq(written[1], 'q0', 'flush: FIFO order kept (first queued first)');
eq(written[65], 'q64', 'flush: last queued frame written last');

// --- dispatch routing --------------------------------------------------------

let got_a = [], got_b = [], unhandled = [];

// second hub needs its own idle fd — one fd cannot be uloop-registered twice
let pp2 = fs.pipe();
let fake2 = { ...fake, fileno: () => pp2[0].fileno() };

let hub2 = transport.open('/dev/fake1', {
	io_open: () => fake2,
	on_unhandled: (h, dec) => push(unhandled, dec),
});

hub2.register({ service: 3, cid: 1, dispatch: (dec) => push(got_a, dec.id) });
hub2.register({ service: 3, cid: 2, dispatch: (dec) => push(got_b, dec.id) });

hub2._dispatch({ service: 3, cid: 1, kind: 'response', id: 'r1' });
eq(got_a, [ 'r1' ], 'dispatch: targeted response reaches its client');
eq(got_b, [], 'dispatch: other cid untouched');

hub2._dispatch({ service: 3, cid: 0xff, kind: 'indication', id: 'bcast' });
eq(got_a, [ 'r1', 'bcast' ], 'dispatch: 0xff indication broadcast (client 1)');
eq(got_b, [ 'bcast' ], 'dispatch: 0xff indication broadcast (client 2)');

hub2._dispatch({ service: 9, cid: 5, kind: 'response', id: 'stray' });
eq(length(unhandled), 1, 'dispatch: unmatched message -> on_unhandled');

hub2.unregister({ service: 3, cid: 1 });
hub2._dispatch({ service: 3, cid: 1, kind: 'response', id: 'r2' });
eq(got_a, [ 'r1', 'bcast' ], 'unregister: client no longer dispatched');
eq(length(unhandled), 2, 'unregister: message now lands in on_unhandled');

// --- close -------------------------------------------------------------------

hub.close();
eq(hub.send('after-close'), false, 'close: send refused');
hub.close();
eq(closed >= 1, true, 'close: native handle closed');

hub2.close();
uloop.done();
pipe_r.close();
pipe_w.close();
pp2[0].close();
pp2[1].close();

done('test_transport');
