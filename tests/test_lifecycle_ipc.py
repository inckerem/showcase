"""Run the real IPC decoder against partial reads, signals and allocation failure."""
from pathlib import Path
import subprocess
import tempfile

source = (Path(__file__).resolve().parents[1] / 'source/Showcase.m').read_text()
decoder = source[source.index('static bool read_exact('):source.index('- (void)ipcHandleConnection:', source.index('static bool read_exact('))]
harness = r'''
#include <assert.h>
#include <errno.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
static unsigned char input[16];
static size_t available, offset;
static int interrupt, alloc_fail;
static ssize_t fake_read(int fd, void *buf, size_t n) {
    (void)fd;
    if (interrupt) { interrupt = 0; errno = EINTR; return -1; }
    if (offset == available) return 0;
    if (n > 1) n = 1;
    memcpy(buf, input + offset, n); offset += n; return (ssize_t)n;
}
static void *fake_malloc(size_t n) { return alloc_fail ? NULL : malloc(n); }
#define read fake_read
#define malloc fake_malloc
#define ip_log(...) ((void)0)
''' + decoder + r'''
static void prepare(const unsigned char *p, size_t n) {
    memcpy(input, p, n); available = n; offset = 0; interrupt = 0; alloc_fail = 0;
}
int main(void) {
    uint8_t type = 0, *body = NULL; uint32_t length = 0;
    const uint8_t valid[] = { 3, 0, 0, 0, 9, 'a', 'b', 'c' };
    prepare(valid, sizeof(valid)); interrupt = 1;
    assert(read_ipc_frame(0, &type, &length, &body));
    assert(type == 9 && length == 3 && memcmp(body, "abc", 3) == 0); free(body);
    prepare(valid, sizeof(valid)); alloc_fail = 1;
    assert(!read_ipc_frame(0, &type, &length, &body) && body == NULL);
    prepare(valid, sizeof(valid)-1);
    assert(!read_ipc_frame(0, &type, &length, &body) && body == NULL);
    const uint8_t badhigh[] = { 0, 0, 0, 128, 1 };
    prepare(badhigh, sizeof(badhigh));
    assert(!read_ipc_frame(0, &type, &length, &body));
    const uint8_t badzero[] = { 0, 0, 0, 0, 1 };
    prepare(badzero, sizeof(badzero));
    assert(!read_ipc_frame(0, &type, &length, &body));
    const uint8_t badlarge[] = { 1, 0, 64, 0, 1 };
    prepare(badlarge, sizeof(badlarge));
    assert(!read_ipc_frame(0, &type, &length, &body));
    puts("PASS: IPC partial reads, EINTR, EOF, bounds and allocation failure");
}
'''
with tempfile.TemporaryDirectory(prefix='showcase-lifecycle-ipc-') as directory:
    path = Path(directory)
    (path / 'test.c').write_text(harness)
    subprocess.run(['clang', '-Wall', '-Wextra', '-Werror', '-fsanitize=undefined,address', str(path / 'test.c'), '-o', str(path / 'test')], check=True)
    subprocess.run([str(path / 'test')], check=True)
