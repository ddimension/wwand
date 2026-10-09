"""Offline tests of startup functions. No router or host sysfs writes."""
import os
import shutil
import tempfile
import pathlib
import subprocess
import unittest

SOURCE = pathlib.Path(__file__).parents[1] / 'files' / 'wwand-startup'


class StartupTests(unittest.TestCase):
    def run_shell(self, commands):
        functions = SOURCE.read_text().split('# Configured explicitly:')[0]
        result = subprocess.run(['sh', '-c', functions + '\n' + commands],
                                text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout

    def test_native_at_helper_success(self):
        out = self.run_shell('''
logger() { :; }
ucode() {
[ "$1" = /usr/libexec/wwand/startup-at ] || return 1
[ "$2" = /dev/ttyUSB2 ] || return 1
[ "$3" = AT+CGMI ] || return 1
printf 'Quectel\\r\\nOK\\r\\n'
}
pcie_at_request /dev/ttyUSB2 AT+CGMI
''')
        self.assertEqual(out.splitlines(), ['Quectel', 'OK'])

    def test_native_at_helper_failure(self):
        out = self.run_shell('''
logger() { :; }
ucode() { printf 'partial\\n'; return 1; }
pcie_at_request /dev/ttyUSB2 AT+CGMI
echo "result $?"
''')
        self.assertEqual(out.strip(), 'result 1')

    def test_mode_unchanged(self):
        out = self.run_shell('''
logger() { :; }
pcie_at_request() {
case "$2" in
AT+CGMI) printf 'Quectel\\nOK\\n';;
*) printf '+QCFG:"data_interface",1,0\\nOK\\n';;
esac
}
pcie_mode_changed=0
set_pcie_mode /dev/null
echo "$pcie_mode_changed"
''')
        self.assertEqual(out.strip(), '0')

    def test_failed_readback(self):
        out = self.run_shell('''
logger() { :; }
pcie_at_request() {
case "$2" in
AT+CGMI) printf 'Quectel\\nOK\\n';;
*) printf '+QCFG:"data_interface",0,0\\nOK\\n';;
esac
}
set_pcie_mode /dev/null
echo "$?"
''')
        self.assertEqual(out.strip(), '1')

    def test_other_manufacturer(self):
        out = self.run_shell('''
pcie_at_request() { printf 'Other\\nOK\\n'; }
set_pcie_mode /dev/null
echo "$?"
''')
        self.assertEqual(out.strip(), '2')

    def test_ready_modem_needs_no_reset(self):
        out = self.run_shell('''
logger() { :; }
configure_pcie_usb_mode() { echo unexpected-at; return 1; }
find_pcie_pci_modem() { echo /fake/endpoint; }
load_mhi() { echo load; }
wait_for_pcie_modem() { return 0; }
start_pcie_modem
''')
        self.assertEqual(out.strip(), 'load')

    def test_missing_endpoint_recovers_with_rescan_without_reset(self):
        out = self.run_shell('''
logger() { :; }
configure_pcie_usb_mode() { echo unexpected-at; return 1; }
rescanned=0
find_pcie_pci_modem() { [ "$rescanned" = 1 ] && echo /fake/endpoint; }
rescan_pcie_modem() { echo rescan; rescanned=1; }
load_mhi() { echo load; }
wait_for_pcie_modem() { return 0; }
start_pcie_modem
''')
        self.assertEqual(out.strip(), 'rescan\nload')

    def test_failed_mhi_retries_after_rescan(self):
        out = self.run_shell('''
logger() { :; }
configure_pcie_usb_mode() { echo unexpected-at; return 1; }
find_pcie_pci_modem() { echo /fake/endpoint; }
rescanned=0
rescan_pcie_modem() { echo rescan; rescanned=1; }
load_mhi() { echo load; }
wait_for_pcie_modem() { [ "$rescanned" = 1 ]; }
start_pcie_modem
''')
        self.assertEqual(out.strip(), 'load\nrescan\nload')

    def test_missing_endpoint_gets_one_scan_without_delay(self):
        out = self.run_shell('''
logger() { :; }
find_pcie_pci_modem() { return 1; }
rescan_pcie_modem() { echo scan; }
sleep() { echo "wait $1"; }
discover_pcie_modem
echo "result $?"
''')
        self.assertEqual(out.splitlines(), ['scan', 'result 1'])

    def test_discovery_returns_when_endpoint_appears(self):
        out = self.run_shell('''
logger() { :; }
scans=0
find_pcie_pci_modem() { [ "$scans" -eq 1 ] && echo /fake/endpoint; }
rescan_pcie_modem() { scans=$((scans + 1)); echo scan; }
sleep() { echo "wait $1"; }
discover_pcie_modem
''')
        self.assertEqual(out.splitlines(), ['scan'])

    def test_usb_at_checks_follow_failed_rescan(self):
        out = self.run_shell('''
logger() { :; }
find_pcie_pci_modem() { return 1; }
rescan_pcie_modem() { echo rescan; }
configure_pcie_usb_mode() { echo at; return 1; }
start_pcie_modem
echo "result $?"
''')
        self.assertEqual(out.splitlines(), ['rescan', 'at', 'result 1'])

    def test_dependency_before_driver(self):
        out = self.run_shell('''
grep() { return 1; }
modprobe() { echo "$1"; }
mhi_module=pcie_mhi
mhi_dependency=rmnet_nss
load_mhi
''')
        self.assertEqual(out.splitlines(), ['rmnet_nss', 'pcie_mhi'])


class NativeHelperTests(unittest.TestCase):
    def test_native_helper_result_and_cleanup(self):
        interpreter = os.environ.get('WWAND_TEST_UCODE') or shutil.which('ucode')
        if not interpreter:
            self.skipTest('set WWAND_TEST_UCODE to a host ucode interpreter')
        helper = SOURCE.with_name('wwand-startup-at')
        for failure in (False, True):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as tmp:
                root = pathlib.Path(tmp)
                (root / 'wwand').mkdir()
                (root / 'uloop.uc').write_text("""
export function init() {};
export function run() {};
export function done() {};
""")
                (root / 'wwand' / 'atcmd.uc').write_text("""
export function open_transport(path, baud) {
    if (path != '/dev/test-at' || baud != 115200) die('bad transport arguments');
    return {};
};
export function create(transport) {
    return {
        send: (cmd, cb, opts) => {
            if (cmd != 'AT+CGMI' || opts.timeout != 5000) die('bad AT arguments');
            cb(""" + ('{ error: "timeout" }' if failure else 'null') + """, ['Quectel']);
        },
        close: () => warn('closed\\n'),
    };
};
""")
                result = subprocess.run([interpreter, '-L', str(root / '*.uc'),
                                         str(helper), '/dev/test-at', 'AT+CGMI'],
                                        text=True, capture_output=True)
                self.assertEqual(result.returncode, 1 if failure else 0, result.stderr)
                self.assertEqual(result.stdout, '' if failure else 'Quectel\nOK\n')
                self.assertIn('closed', result.stderr)


if __name__ == '__main__':
    unittest.main()
