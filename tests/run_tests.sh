#!/bin/sh
# wwand host-side test runner.
# Needs a ucode interpreter with the struct module; on the dev host that is
# ~/.local (built from source), on OpenWrt the system ucode works as-is.

set -e

TESTDIR="$(cd "$(dirname "$0")" && pwd)"
SRCDIR="$(dirname "$TESTDIR")/src-ucode"

if [ -x "$HOME/.local/bin/ucode" ]; then
	UCODE="$HOME/.local/bin/ucode"
	export LD_LIBRARY_PATH="$HOME/.local/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
	MODPATH="$HOME/.local/lib/ucode/*.so"
else
	UCODE=ucode
	MODPATH="/usr/lib/ucode/*.so"
fi

# 'wwand...' imports resolve via the tests/wwand -> ../src-ucode symlink
NATIVE="$TESTDIR/../io/build-host/*.so"

# spawn a private ubusd for the daemon integration test if available
UBUSD=""
for cand in "$HOME/.local/sbin/ubusd" /sbin/ubusd /usr/sbin/ubusd; do
	[ -x "$cand" ] && { UBUSD="$cand"; break; }
done

if [ -n "$UBUSD" ]; then
	export WWAND_TEST_UBUS_SOCK="${TMPDIR:-/tmp}/wwand-test-ubus-$$.sock"
	"$UBUSD" -s "$WWAND_TEST_UBUS_SOCK" &
	UBUSD_PID=$!
	trap '[ -n "$UBUSD_PID" ] && kill $UBUSD_PID 2>/dev/null; rm -f "$WWAND_TEST_UBUS_SOCK"' EXIT
	sleep 0.2
fi

# A suite's verdict comes from the summary line it prints ("<name>: N checks, 0
# failures"), not from the exit code. Rationale: the host ucode ubus.so has a
# use-after-free of a published object's per-call args at VM *teardown* (proven
# with valgrind: uc_ubus_object_call_cb -> ucv_gc_common, present on a clean tree
# too — it is a host-interpreter bug, not a wwand or product bug). Whether glibc
# turns that latent double-free into a SIGABRT at process exit depends on heap
# layout, so an integration suite like test_daemon can abort *after* every check
# has passed. We line-buffer stdout so the summary survives such an abort, then:
#   - summary present with 0 failures            -> pass (note a teardown abort)
#   - summary missing (crash before it) / >0 fail -> fail
STDBUF=""
command -v stdbuf >/dev/null 2>&1 && STDBUF="stdbuf -oL -eL"

# the loop handles per-suite failures itself (a suite may exit non-zero from a
# host-interpreter teardown abort even when all its checks passed), so drop the
# fail-fast that would otherwise abort the whole run on that exit
set +e

rc=0
for t in "$TESTDIR"/test_*.uc; do
	name=$(basename "$t" .uc)
	out=$(cd "$TESTDIR" && $STDBUF "$UCODE" -L "$MODPATH" -L "$NATIVE" -L "$TESTDIR/*.uc" "$t" 2>&1)
	code=$?
	printf '%s\n' "$out"

	if printf '%s\n' "$out" | grep -q "^$name: [0-9]\{1,\} checks, 0 failures$"; then
		[ "$code" -ne 0 ] && echo "  ($name: all checks passed; ignoring exit $code from a host-ucode teardown abort)"
	elif printf '%s\n' "$out" | grep -q "^$name: SKIPPED"; then
		: # environment-gated suite (e.g. no ubusd) — skip is not a failure
	else
		echo "FAIL: $name (no clean summary; exit $code)"
		rc=1
	fi
done

# THE DOC CHECKERS RUN HERE, not only from the release checklist. A checker that
# is run by hand is a checker that stops being run — check-export-terminators
# existed and v1.6.4 shipped the defect it catches anyway. These are the cheap,
# deterministic ones; they need nothing but python3.
if command -v python3 >/dev/null 2>&1; then
	for chk in check-map check-anchors check-export-terminators; do
		# --since HEAD: an uncommitted edit that MOVES an anchored line fails the
		# run before the commit, when fixing it is one `--fix` away
		args=""
		[ "$chk" = check-anchors ] && git -C "$TESTDIR" rev-parse HEAD >/dev/null 2>&1 && args="--since HEAD"
		out=$(python3 "$TESTDIR/../tools/$chk.py" $args 2>&1)
		code=$?
		printf '%s\n' "$out" | tail -1
		[ "$code" -ne 0 ] && { printf '%s\n' "$out"; echo "FAIL: $chk"; rc=1; }
	done
else
	# said out loud: a silent skip here reads as "all checkers passed"
	echo "WARNING: python3 not found — check-map, check-anchors and check-export-terminators DID NOT RUN"
fi

exit $rc
