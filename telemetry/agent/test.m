#define AGENT_TEST 1
#import "Agent.m"
#include <assert.h>
int main(void) { @autoreleasepool {
    assert(relevant(@"Showcase-2026-11-09.crash"));
    assert(relevant(@"showcase-powerd-2026.crash"));
    assert(!relevant(@"WhatsApp-2026.crash"));
    NSString *sample = @"Incident Identifier: private-id\nCrashReporter Key: private-key\nProcess: Showcase [23]\nException Type: EXC_CRASH\nSSID: private-wifi\nLibrary not loaded: /usr/lib/example.dylib\nReason: image not found\nThread 0 Crashed:\n0 Showcase 0x0000000100041234 main + 40\n";
    NSString *clean = technicalExcerpt(sample);
    assert(![clean containsString:@"private"]);
    assert([clean containsString:@"image not found"]);
    assert([clean containsString:@"main + 40"]);
    NSString *temp = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    [sample writeToFile:temp atomically:YES encoding:NSUTF8StringEncoding error:nil];
    assert(boundedRead(temp).length > 0);
    NSString *link = [temp stringByAppendingString:@"-link"];
    assert(symlink(temp.fileSystemRepresentation, link.fileSystemRepresentation) == 0);
    assert(boundedRead(link) == nil);
    unlink(link.fileSystemRepresentation); unlink(temp.fileSystemRepresentation);
    puts("PASS: crash selection, technical-only filtering, bounded reads, symlink rejection");
} }
