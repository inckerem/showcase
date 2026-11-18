"""Run the real bounded-depth bplist validator from carplay_services.m.

Every valid binary plist that CoreFoundation writes must pass unchanged
(a false rejection would break a real iPhone session); deeply nested,
non-binary and truncated bodies must be refused.
"""
from pathlib import Path
import subprocess
import tempfile

source = (Path(__file__).resolve().parents[1] / 'source/carplay_services.m').read_text()
start = source.index('#define NETWORK_PLIST_MAX_DEPTH')
end = source.index('/* Like TLV8_DUMP_MAX_ITEMS')
validator = source[start:end]
assert 'static id network_plist_parse' in validator

code = r'''
#import <Foundation/Foundation.h>
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
''' + validator + r'''
static id roundtrip(id object, unsigned depth) {
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:object
        format:NSPropertyListBinaryFormat_v1_0 options:0 error:NULL];
    assert(data);
    return network_plist_parse(data.bytes, data.length, depth);
}

static id nested(unsigned levels, BOOL arrays) {
    id value = @"leaf";
    for (unsigned i = 0; i < levels; i++)
        value = arrays ? @[value] : @{@"k": value};
    return value;
}

int main(void) { @autoreleasepool {
    uint8_t bytes[300];
    for (unsigned i = 0; i < sizeof(bytes); i++) bytes[i] = (uint8_t)i;
    NSMutableDictionary *wide = [NSMutableDictionary dictionary];
    for (int i = 0; i < 300; i++) wide[[NSString stringWithFormat:@"key%d", i]] = @(i * 1000003LL);
    NSString *shared = @"shared-value";
    NSDictionary *setup = @{
        @"streams": @[@{@"type": @110, @"streamConnectionID": @(0x7fffffffffffffffLL),
                        @"timestampInfo": @[@{@"name": @"SubSu"}, @{@"name": @"BePxT"}]}],
        @"timingProtocol": @"NTP", @"deviceID": @"AA:BB:CC:DD:EE:FF",
        @"eiv": [NSData dataWithBytes:bytes length:16],
        @"ekey": [NSData dataWithBytes:bytes length:72],
        @"isScreenMirroringSession": @NO, @"osBuildVersion": @"16A366",
        @"rate": @(1.0), @"negative": @(-42), @"small": @(7), @"double": @(3.141592653589793),
        @"date": [NSDate dateWithTimeIntervalSinceReferenceDate:600000000.5],
        @"unicode": @"Kerem’in arabası ğüşıöç 🚗",
        @"blob": [NSData dataWithBytes:bytes length:sizeof(bytes)],
        @"emptyDict": @{}, @"emptyArray": @[], @"emptyString": @"", @"emptyData": [NSData data],
        @"a": shared, @"b": shared, @"wide": wide,
    };
    NSArray *valid = @[setup, @{@"pk": [NSData dataWithBytes:bytes length:32]}, @[@1, @"x", @YES],
                       nested(15, NO), nested(15, YES), @"top-level string", @(123)];
    for (id object in valid) {
        id parsed = roundtrip(object, NETWORK_PLIST_MAX_DEPTH);
        assert(parsed && [parsed isEqual:object]);
    }
    /* auth-setup's flat dictionary passes its stricter limit. */
    assert([roundtrip(@{@"pk": [NSData dataWithBytes:bytes length:32]}, AUTH_SETUP_PLIST_MAX_DEPTH) isKindOfClass:[NSDictionary class]]);
    /* Too deep: refused before CoreFoundation recurses. */
    assert(!roundtrip(nested(300, NO), NETWORK_PLIST_MAX_DEPTH));
    assert(!roundtrip(nested(300, YES), NETWORK_PLIST_MAX_DEPTH));
    assert(!roundtrip(nested(17, NO), NETWORK_PLIST_MAX_DEPTH));
    assert(!roundtrip(nested(6, NO), AUTH_SETUP_PLIST_MAX_DEPTH));
    /* Not binary, empty or truncated: refused. */
    NSData *xml = [NSPropertyListSerialization dataWithPropertyList:setup
        format:NSPropertyListXMLFormat_v1_0 options:0 error:NULL];
    assert(!network_plist_parse(xml.bytes, xml.length, NETWORK_PLIST_MAX_DEPTH));
    assert(!network_plist_parse(NULL, 0, NETWORK_PLIST_MAX_DEPTH));
    NSData *bin = [NSPropertyListSerialization dataWithPropertyList:setup
        format:NSPropertyListBinaryFormat_v1_0 options:0 error:NULL];
    for (size_t cut = 1; cut < bin.length; cut += 7)
        assert(!network_plist_parse(bin.bytes, bin.length - cut, NETWORK_PLIST_MAX_DEPTH));
    /* Random corruption never crashes (ASan/UBSan watch the walk). */
    NSMutableData *bad = [bin mutableCopy];
    uint32_t seed = 1;
    for (int round = 0; round < 2000; round++) {
        [bad setData:bin];
        for (int k = 0; k < 4; k++) {
            seed = seed * 1103515245u + 12345u;
            ((uint8_t *)bad.mutableBytes)[seed % bad.length] = (uint8_t)(seed >> 16);
        }
        (void)network_plist_parse(bad.bytes, bad.length, NETWORK_PLIST_MAX_DEPTH);
    }
    puts("PASS: valid binary plists round-trip; deep, XML, truncated and corrupted bodies refused");
} }
'''

with tempfile.TemporaryDirectory(prefix='showcase-plist-') as directory:
    path = Path(directory)
    (path / 'test.m').write_text(code)
    subprocess.run(['clang', '-fobjc-arc', '-g', '-fsanitize=address,undefined',
                    '-Wno-unused-function', '-framework', 'Foundation',
                    str(path / 'test.m'), '-o', str(path / 'test')], check=True)
    subprocess.run([str(path / 'test')], check=True)
