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
    NSMutableString *large = [NSMutableString string];
    for (int i = 0; i < 240; i++) [large appendFormat:@"Reason: %@\n", [@"界" stringByPaddingToLength:500 withString:@"界" startingAtIndex:0]];
    assert([technicalExcerpt(large) lengthOfBytesUsingEncoding:NSUTF8StringEncoding] <= 32768);
    NSString *prefix = [@"Reason: " stringByPaddingToLength:511 withString:@"x" startingAtIndex:0];
    NSString *truncated = technicalExcerpt([prefix stringByAppendingString:@"🚗"]);
    assert([truncated isEqual:prefix]);
    assert([NSJSONSerialization dataWithJSONObject:@{@"excerpt": truncated} options:0 error:NULL]);
    NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    assert(prepareStateDirectory(dir));
    struct stat info;
    assert(lstat(dir.fileSystemRepresentation, &info) == 0 && (info.st_mode & 0777) == 0700);
    assert(prepareStateDirectory(dir));
    NSString *dirLink = [dir stringByAppendingPathComponent:@"dir-link"];
    assert(symlink(dir.fileSystemRepresentation, dirLink.fileSystemRepresentation) == 0);
    assert(!prepareStateDirectory(dirLink));
    for (int i = 0; i < 130; i++) {
        NSString *name = [NSString stringWithFormat:@"%@-%03d.crash", i == 129 ? @"Showcase" : @"showcase-powerd", i];
        NSString *path = [dir stringByAppendingPathComponent:name];
        [@"test" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        [NSFileManager.defaultManager setAttributes:@{NSFileModificationDate:[NSDate dateWithTimeIntervalSinceNow:i-130]} ofItemAtPath:path error:nil];
    }
    NSArray *recent = recentCrashNames(dir);
    assert(recent.count == 128);
    assert([recent.firstObject isEqual:@"Showcase-129.crash"]);
    assert(![recent containsObject:@"showcase-powerd-000.crash"]);
    [NSFileManager.defaultManager removeItemAtPath:dir error:nil];
    NSString *temp = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    [sample writeToFile:temp atomically:YES encoding:NSUTF8StringEncoding error:nil];
    assert(boundedRead(temp).length > 0);
    NSString *link = [temp stringByAppendingString:@"-link"];
    assert(symlink(temp.fileSystemRepresentation, link.fileSystemRepresentation) == 0);
    assert(boundedRead(link) == nil);
    unlink(link.fileSystemRepresentation); unlink(temp.fileSystemRepresentation);
    puts("PASS: crash priority, bounded cache, Unicode truncation, private state and symlink rejection");
} }
