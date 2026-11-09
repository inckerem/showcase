#import <Foundation/Foundation.h>
#include <sys/stat.h>
#include <sys/utsname.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>

// Runs as mobile, once every three minutes, then exits. No injected code.
static NSString *const stateDir = @"/var/mobile/Library/ShowcaseRemoteDiagnostics";
static BOOL prepareStateDirectory(NSString *path) {
    // The mobile worker creates and validates its own state directory.
    const char *directory = path.fileSystemRepresentation;
    if (mkdir(directory, 0700) != 0 && errno != EEXIST) return NO;
    struct stat st;
    return lstat(directory, &st) == 0 && S_ISDIR(st.st_mode) &&
           st.st_uid == geteuid() && !(st.st_mode & 0077);
}
static BOOL relevant(NSString *name) {
    for (NSString *prefix in @[@"Showcase-", @"Showcase_", @"carplay_bt-", @"carplay_services-", @"showcase-powerd-"])
        if ([name hasPrefix:prefix]) return YES;
    return NO;
}
static NSArray<NSString *> *recentCrashNames(NSString *directory) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSMutableDictionary<NSString *, NSDate *> *dates = [NSMutableDictionary dictionary];
    for (NSString *name in [fm contentsOfDirectoryAtPath:directory error:nil]) {
        if (!relevant(name) || (![@"ips" isEqual:name.pathExtension] && ![@"crash" isEqual:name.pathExtension])) continue;
        NSDictionary *attrs = [fm attributesOfItemAtPath:[directory stringByAppendingPathComponent:name] error:nil];
        NSDate *date = attrs[NSFileModificationDate];
        if ([attrs[NSFileType] isEqual:NSFileTypeRegular] && date && -date.timeIntervalSinceNow <= 7*86400) dates[name] = date;
    }
    NSArray *names = [dates.allKeys sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        NSComparisonResult order = [dates[b] compare:dates[a]];
        return order == NSOrderedSame ? [a compare:b] : order;
    }];
    // Bound the candidate set to the same size as the acknowledgement cache.
    return names.count > 128 ? [names subarrayWithRange:NSMakeRange(0, 128)] : names;
}
static NSString *technicalExcerpt(NSString *text) {
    NSMutableArray *out = [NSMutableArray array];
    NSUInteger bytes = 0;
    NSRegularExpression *frame = [NSRegularExpression regularExpressionWithPattern:@"^[0-9]+[ \\t]+[A-Za-z0-9_.+-]+[ \\t]+0x[0-9a-fA-F]+" options:0 error:nil];
    NSArray *headers = @[@"Process:", @"Identifier:", @"Version:", @"Code Type:", @"OS Version:", @"Exception Type:", @"Exception Codes:", @"Exception Subtype:", @"Termination Reason:", @"Termination Description:", @"Triggered by Thread:", @"Crashed Thread:", @"Library not loaded:", @"Referenced from:", @"Reason:", @"Dyld Error Message:", @"Application Specific Information:", @"Last Exception Backtrace:"];
    for (NSString *raw in [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        NSString *line = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        BOOL keep = [frame firstMatchInString:line options:0 range:NSMakeRange(0, line.length)] != nil;
        for (NSString *prefix in headers) if ([line hasPrefix:prefix]) keep = YES;
        if ([line hasPrefix:@"Thread "] && [line containsString:@"Crashed:"]) keep = YES;
        if (!keep) continue;
        // No raw logs, user messages, network names, or crash identifiers.
        if (line.length > 512) {
            NSRange boundary = [line rangeOfComposedCharacterSequenceAtIndex:512];
            line = [line substringToIndex:boundary.location];
        }
        NSUInteger lineBytes = [line lengthOfBytesUsingEncoding:NSUTF8StringEncoding] + 1;
        if (bytes + lineBytes > 32768) break;
        bytes += lineBytes;
        [out addObject:line];
        if (out.count >= 240) break;
    }
    return [out componentsJoinedByString:@"\n"];
}
static NSData *boundedRead(NSString *path) {
    int fd = open(path.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_NONBLOCK);
    if (fd < 0) return nil;
    struct stat st;
    if (fstat(fd, &st) || !S_ISREG(st.st_mode) || st.st_size <= 0 || st.st_size > 4*1024*1024) { close(fd); return nil; }
    NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)MIN(st.st_size, 512*1024)];
    ssize_t size = read(fd, data.mutableBytes, data.length);
    close(fd);
    if (size <= 0) return nil;
    data.length = (NSUInteger)size;
    return data;
}
#ifndef AGENT_TEST
int main(void) { @autoreleasepool {
    NSFileManager *fm = NSFileManager.defaultManager;
    if (!prepareStateDirectory(stateDir)) return 2;
    NSString *statePath = [stateDir stringByAppendingPathComponent:@"state.plist"];
    // An optional local disable marker also works when Showcase cannot launch.
    if ([fm fileExistsAtPath:[stateDir stringByAppendingPathComponent:@"disabled"]]) return 0;
    NSMutableDictionary *state = [[NSDictionary dictionaryWithContentsOfFile:statePath] mutableCopy] ?: [NSMutableDictionary dictionary];
    NSString *install = state[@"installation"];
    if (![install isKindOfClass:NSString.class] || ![[NSUUID alloc] initWithUUIDString:install]) install = NSUUID.UUID.UUIDString.lowercaseString;
    state[@"installation"] = install;
    if (![state writeToFile:statePath atomically:YES]) return 2;
    NSDictionary *seen = [state[@"seen"] isKindOfClass:NSDictionary.class] ? state[@"seen"] : @{};
    NSMutableDictionary *nextSeen = [NSMutableDictionary dictionary];
    NSMutableArray *reports = [NSMutableArray array];
    NSString *crashDir = @"/var/mobile/Library/Logs/CrashReporter";
    NSArray *names = recentCrashNames(crashDir);
    for (NSString *name in names) {
        if (!relevant(name) || (![name.pathExtension isEqual:@"ips"] && ![name.pathExtension isEqual:@"crash"])) continue;
        NSString *path = [crashDir stringByAppendingPathComponent:name];
        NSDictionary *attrs = [fm attributesOfItemAtPath:path error:nil];
        NSDate *date = attrs[NSFileModificationDate];
        if (!date || -date.timeIntervalSinceNow > 7*86400) continue;
        NSString *signature = [NSString stringWithFormat:@"%@:%@", attrs[NSFileSize], @((long long)date.timeIntervalSince1970)];
        if ([seen[name] isEqual:signature]) { if (nextSeen.count < 128) nextSeen[name] = signature; continue; }
        if (reports.count >= 2) continue;
        NSData *data = boundedRead(path);
        NSString *raw = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
        if (!raw) continue;
        NSString *excerpt = technicalExcerpt(raw);
        // iOS 12 text-format crash logs supported. Never upload unknown raw formats.
        NSString *process = @"Showcase";
        for (NSString *candidate in @[@"carplay_bt", @"carplay_services", @"showcase-powerd"])
            if ([name hasPrefix:candidate]) process = candidate;
        [reports addObject:@{@"process": process,
                              @"time": @((long long)date.timeIntervalSince1970),
                              @"excerpt": excerpt.length ? excerpt : @"Unsupported crash format; raw content withheld."}];
        nextSeen[name] = signature;
    }
    NSTimeInterval last = [state[@"lastSent"] doubleValue];
    if (!reports.count && NSDate.date.timeIntervalSince1970 - last < 1800) return 0;
    struct utsname machine; uname(&machine);
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:@"/Applications/Showcase.app/Info.plist"] ?: @{};
    NSDictionary *disk = [fm attributesOfFileSystemForPath:@"/var/mobile" error:nil];
    NSDictionary *payload = @{@"schema": @1, @"installation": install,
        @"model": @(machine.machine), @"os": NSProcessInfo.processInfo.operatingSystemVersionString,
        @"version": info[@"ShowcasePackageVersion"] ?: info[@"CFBundleShortVersionString"] ?: @"unknown",
        @"freeMB": @([disk[NSFileSystemFreeSize] unsignedLongLongValue]/1048576), @"reports": reports};
    NSData *body = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
    if (!body || body.length > 262144) return 3;
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://kcs.net.tr/repo/api/diagnostics.php"]];
    req.HTTPMethod = @"POST"; req.HTTPBody = body; req.timeoutInterval = 15;
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    NSURLSessionConfiguration *config = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    config.timeoutIntervalForResource = 20; config.HTTPCookieStorage = nil;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:config];
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block BOOL success = NO;
    NSURLSessionDataTask *task = [session dataTaskWithRequest:req completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        success = !e && [(NSHTTPURLResponse *)r statusCode] == 201;
        dispatch_semaphore_signal(done);
    }];
    [task resume];
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 25*NSEC_PER_SEC))) { [session invalidateAndCancel]; return 4; }
    [session finishTasksAndInvalidate];
    if (!success) return 5;
    state[@"seen"] = nextSeen; state[@"lastSent"] = @(NSDate.date.timeIntervalSince1970);
    return [state writeToFile:statePath atomically:YES] ? 0 : 6;
} }
#endif
