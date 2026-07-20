// wwand tests — minimal check helpers. Import with:
//   import { eq, ok, done } from './lib/check.uc';

'use strict';

let failures = 0;
let checks = 0;

export function ok(cond, msg)
{
	checks++;

	if (!cond) {
		failures++;
		warn(sprintf("FAIL: %s\n", msg ?? 'condition not true'));
	}
}

export function eq(got, want, msg)
{
	checks++;

	let sg = sprintf('%J', got);
	let sw = sprintf('%J', want);

	if (sg != sw) {
		failures++;
		warn(sprintf("FAIL: %s\n  got:  %s\n  want: %s\n", msg ?? 'values differ', sg, sw));
	}
}

export function done(name)
{
	printf("%s: %d checks, %d failures\n", name, checks, failures);
	exit(failures ? 1 : 0);
}
