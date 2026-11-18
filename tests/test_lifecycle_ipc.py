"""Run the real IPC decoder against partial reads, signals, oversized frames and allocation failure."""
from pathlib import Path
import re
import subprocess
import tempfile

source = (Path(__file__).resolve().parents[1] / 'source/Showcase.m').read_text()
decoder = source[source.index('static bool read_exact('):source.index('- (void)ipcHandleConnection:', source.index('static bool read_exact('))]
# The decoder flags a resync when it has to skip an oversized video frame; take
# the message type from Showcase.m so the harness cannot drift from it.
msg_video_frame = re.search(r'#define\s+MSG_VIDEO_FRAME\s+(0x[0-9A-Fa-f]+|\d+)', source).group(1)
harness = r'''
#include <assert.h>
#include <errno.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#define MSG_VIDEO_FRAME ''' + msg_video_frame + r'''
static volatile int32_t g_video_needs_resync = 0;
static int resync_requests;
static void send_video_resync_request(void) { resync_requests++; }
/* The stream is input[] with `gap` virtual zero bytes inserted at `gap_at`, so
 * frames past the decoder's bound can be fed without a huge literal. */
static unsigned char input[64];
static size_t available, offset, gap_at, gap;
static int interrupt, alloc_fail, bulk;
static ssize_t fake_read(int fd, void *buf, size_t n) {
    (void)fd;
    if (interrupt) { interrupt = 0; errno = EINTR; return -1; }
    size_t total = available + gap;
    if (offset == total) return 0;
    if (!bulk && n > 1) n = 1;
    if (n > total - offset) n = total - offset;
    for (size_t i = 0; i < n; i++, offset++) {
        unsigned char byte = 0;
        if (offset < gap_at) byte = input[offset];
        else if (offset >= gap_at + gap) byte = input[offset - gap];
        ((unsigned char *)buf)[i] = byte;
    }
    return (ssize_t)n;
}
static void *fake_malloc(size_t n) { return alloc_fail ? NULL : malloc(n); }
#define read fake_read
#define malloc fake_malloc
#define ip_log(...) ((void)0)
''' + decoder + r'''
static void prepare(const unsigned char *p, size_t n) {
    memcpy(input, p, n); available = n; offset = 0; interrupt = 0; alloc_fail = 0;
    gap_at = gap = 0; bulk = 0; g_video_needs_resync = 0; resync_requests = 0;
}
/* One oversized frame of `frame_type` (its body is the virtual gap), then a
 * valid three-byte frame of type 9. */
static void prepare_oversized(uint8_t frame_type, uint32_t len) {
    const uint8_t stream[] = {
        (uint8_t)len, (uint8_t)(len >> 8), (uint8_t)(len >> 16), (uint8_t)(len >> 24), frame_type,
        3, 0, 0, 0, 9, 'x', 'y', 'z'
    };
    prepare(stream, sizeof(stream));
    gap_at = 5; gap = len; bulk = 1;
}
int main(void) {
    uint8_t type = 0, *body = NULL; uint32_t length = 0;
    const uint8_t valid[] = { 3, 0, 0, 0, 9, 'a', 'b', 'c' };
    prepare(valid, sizeof(valid)); interrupt = 1;
    assert(read_ipc_frame(0, &type, &length, &body));
    assert(type == 9 && length == 3 && memcmp(body, "abc", 3) == 0); free(body);
    assert(g_video_needs_resync == 0 && resync_requests == 0);
    prepare(valid, sizeof(valid)); alloc_fail = 1;
    assert(!read_ipc_frame(0, &type, &length, &body) && body == NULL);
    prepare(valid, sizeof(valid)-1);
    assert(!read_ipc_frame(0, &type, &length, &body) && body == NULL);
    const uint8_t badzero[] = { 0, 0, 0, 0, 1 };
    prepare(badzero, sizeof(badzero));
    assert(!read_ipc_frame(0, &type, &length, &body) && body == NULL);

    /* An oversized frame whose body is cut short ends the session. */
    const uint8_t badhigh[] = { 0, 0, 0, 128, 1 };
    prepare(badhigh, sizeof(badhigh));
    assert(!read_ipc_frame(0, &type, &length, &body) && body == NULL);
    assert(resync_requests == 0);

    /* A frame exactly at the bound is accepted. */
    prepare_oversized(9, IPC_MAX_FRAME_BYTES);
    available = 5;
    assert(read_ipc_frame(0, &type, &length, &body));
    assert(type == 9 && length == IPC_MAX_FRAME_BYTES && body != NULL); free(body);
    assert(g_video_needs_resync == 0 && resync_requests == 0);

    /* One byte over the bound: skipped, stream stays framed, next frame read.
     * A non-video frame needs no resync. */
    prepare_oversized(1, IPC_MAX_FRAME_BYTES + 1);
    assert(read_ipc_frame(0, &type, &length, &body));
    assert(type == 9 && length == 3 && memcmp(body, "xyz", 3) == 0); free(body);
    assert(g_video_needs_resync == 0 && resync_requests == 0);

    /* A skipped video frame breaks the reference chain: flag a resync and ask
     * the sender for a key frame exactly once. */
    prepare_oversized(MSG_VIDEO_FRAME, IPC_MAX_FRAME_BYTES + 1);
    assert(read_ipc_frame(0, &type, &length, &body));
    assert(type == 9 && length == 3 && memcmp(body, "xyz", 3) == 0); free(body);
    assert(g_video_needs_resync == 1 && resync_requests == 1);

    /* Truncated oversized video frame: session ends, no frame returned. */
    prepare_oversized(MSG_VIDEO_FRAME, IPC_MAX_FRAME_BYTES + 1);
    available = 5; gap = 100;
    assert(!read_ipc_frame(0, &type, &length, &body) && body == NULL);
    assert(resync_requests == 0);
    puts("PASS: IPC partial reads, EINTR, EOF, bounds, oversized-frame skip/resync and allocation failure");
}
'''
with tempfile.TemporaryDirectory(prefix='showcase-lifecycle-ipc-') as directory:
    path = Path(directory)
    (path / 'test.c').write_text(harness)
    subprocess.run(['clang', '-Wall', '-Wextra', '-Werror', '-fsanitize=undefined,address', str(path / 'test.c'), '-o', str(path / 'test')], check=True)
    subprocess.run([str(path / 'test')], check=True)
