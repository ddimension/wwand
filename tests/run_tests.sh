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

rc=0
for t in "$TESTDIR"/test_*.uc; do
	if ! (cd "$TESTDIR" && "$UCODE" -L "$MODPATH" -L "$NATIVE" -L "$TESTDIR/*.uc" "$t"); then
		rc=1
	fi
done

exit $rc
