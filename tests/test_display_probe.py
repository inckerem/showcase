"""Exercise the production hardware cache with a deliberately blocked probe."""
from pathlib import Path
import subprocess
import tempfile

source = (Path(__file__).resolve().parents[1] / 'source/Showcase.m').read_text()
begin = source.index('typedef struct {', source.index('/* Screen properties are initialized'))
end = source.index('static CarPlayVideoPriority carplay_video_priority', begin)
harness = r'''
#import <Foundation/Foundation.h>
#include <assert.h>
typedef NSSize CGSize;
#define CGSizeMake NSMakeSize
typedef enum { CarPlayWLANAttachmentUnknown, CarPlayWLANAttachmentHSIC, CarPlayWLANAttachmentPCIe } CarPlayWLANAttachment;
@interface UIScreen : NSObject
+ (instancetype)mainScreen;
@property(readonly) NSRect nativeBounds;
@property(readonly) NSRect bounds;
@property(readonly) double scale;
@property(readonly) NSInteger maximumFramesPerSecond;
@end
@implementation UIScreen
+ (instancetype)mainScreen { assert(NSThread.isMainThread); return [self new]; }
- (NSRect)nativeBounds { return NSMakeRect(0,0,2048,1536); }
- (NSRect)bounds { return self.nativeBounds; }
- (double)scale { return 1; }
- (NSInteger)maximumFramesPerSecond { return 60; }
@end
static dispatch_semaphore_t gate;
static int probes;
static CarPlayWLANAttachment wlan_attachment_class(void) {
    __atomic_add_fetch(&probes, 1, __ATOMIC_RELAXED);
    dispatch_semaphore_wait(gate, DISPATCH_TIME_FOREVER);
    return CarPlayWLANAttachmentPCIe;
}
''' + source[begin:end] + r'''
int main(void) { @autoreleasepool {
    gate = dispatch_semaphore_create(0);
    CarPlayDisplayHardware first = carplay_display_hardware();
    assert(first.nativeLong == 2048 && first.defaultFPS == 30);
    dispatch_group_t readers = dispatch_group_create();
    for (int i = 0; i < 50; i++) dispatch_group_async(readers,
        dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            assert(carplay_display_hardware().defaultFPS == 30);
        });
    // These must finish while the probe is still blocked, not after release.
    assert(dispatch_group_wait(readers, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) == 0);
    dispatch_semaphore_signal(gate);
    for (int i = 0; i < 100 && carplay_display_hardware().defaultFPS != 60; i++)
        [NSThread sleepForTimeInterval:.01];
    assert(carplay_display_hardware().defaultFPS == 60);
    assert(__atomic_load_n(&probes, __ATOMIC_RELAXED) == 1);
    puts("PASS: 50 concurrent readers return while hardware probe is blocked; single probe, main-thread screen access");
} }
'''
with tempfile.TemporaryDirectory() as directory:
    path = Path(directory)
    (path / 'probe.m').write_text(harness)
    subprocess.run(['clang', '-Os', '-fobjc-arc', '-fblocks', '-framework', 'Foundation', str(path / 'probe.m'), '-o', str(path / 'probe')], check=True)
    subprocess.run([str(path / 'probe')], check=True, timeout=5)
