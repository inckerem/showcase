"""Regression checks for settings safety and daemon command logging."""
from pathlib import Path
import subprocess
import tempfile

source = (Path(__file__).resolve().parents[1] / 'source/Showcase.m').read_text()

mode = source[source.index('- (void)selectWiFiMode:'):source.index('- (void)buildHotspot:')]
assert 'shared == showcase_use_existing_wifi()) return' in mode
assert 'self.sessionRunning ||' in mode
assert 'self.wifiDrafts[oldKey]' in mode
assert 'draft[0]' in mode and 'draft[1]' in mode

page = source[source.index('- (void)buildHotspot:'):source.index('- (void)buildSound:')]
assert 'self.ssidField.enabled = !self.sessionRunning' in page
assert 'self.passwordField.enabled = !self.sessionRunning' in page
assert 'save.enabled = !self.sessionRunning' in page
assert 'if (self.sessionRunning) return;' in page
assert 'placeholder:(connectedSSID.length ? connectedSSID' in page
assert 'text:ssid' in page and 'self.draftSSID ?: app.cars.apSSID' in page
assert 'Connected to “%@”' in page

header = source[source.index('    /* Header */', source.index('@implementation SettingsViewController')):source.index('    CGFloat top = safe.top + headerH;')]
assert 'MAX(left, right) + 52' in header
assert 'self.wide ? 80 : 44' in header
# Check the compact header geometry for small screens and asymmetric safe areas.
for width, left, right in [(320, 12, 12), (375, 12, 12), (320, 44, 12), (320, 12, 44)]:
    inset = max(left, right) + 52
    title_left, title_right = inset, width - inset
    assert left + 44 <= title_left
    assert title_right <= width - right - 44
    assert title_right > title_left

spawn = source[source.index('static pid_t spawn_daemon('):source.index('static pid_t check_child(')]
loop = spawn[spawn.index('    for (int i = 1;'):spawn.index('    ip_log("spawn_daemon: %s"')]
program = r'''
#import <Foundation/Foundation.h>
#include <string.h>
#include <assert.h>
int main(void) { @autoreleasepool {
    char *argv[] = {"helper", "--ssid", "Router", "--pass", "secret-one", "-p", "secret-two", "--name", "Car", NULL};
    NSMutableString *cmdline = [NSMutableString stringWithString:@"helper"];
''' + loop + r'''
    assert([cmdline isEqualToString:@"helper --ssid Router --pass ****** -p ****** --name Car"]);
    puts("PASS: spawn log redacts both password options without changing other arguments");
} return 0; }
'''
with tempfile.TemporaryDirectory(prefix='showcase-settings-test-') as tmp:
    path = Path(tmp) / 'redact.m'
    path.write_text(program)
    exe = Path(tmp) / 'redact'
    subprocess.run(['clang', '-fobjc-arc', '-framework', 'Foundation', str(path), '-o', str(exe)], check=True)
    subprocess.run([str(exe)], check=True)
print('PASS: settings mode, session lock, and SSID suggestion safeguards')
