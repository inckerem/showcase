"""Exercise the real HTTP parser and client loop with socket pairs on macOS.

Encrypted records are stubbed as length-prefixed plaintext: this tests stream
framing and ownership, not ChaCha20 or interaction with a real iPhone.
"""
from pathlib import Path
import subprocess
import tempfile

source = (Path(__file__).resolve().parents[1] / 'source/carplay_services.m').read_text()
owner = source[source.index('typedef struct {\n    uint8_t readKey[32]'):source.index('static dispatch_semaphore_t g_event_send_lock')]
parser = source[source.index('typedef struct {\n    char method[32]'):source.index('/* ═══════════════════════════════════════════════════════════════\n * HTTP Response Helper')]
client = source[source.index('static void handle_client(int c)'):source.index('static bool start_airplay_server')]

harness = r'''
#include <assert.h>
#include <errno.h>
#include <limits.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>
#define ENCRYPTED_MAX_READ_SIZE (16 * 1024)
''' + owner + parser + r'''
static int read_exact(int fd, void *p, size_t n) {
    size_t done = 0;
    while (done < n) { ssize_t k = recv(fd, (char *)p + done, n - done, 0); if (k <= 0) return -1; done += k; }
    return 0;
}
static int enc_recv_frame(int fd, encrypted_ctx_t *ctx, uint8_t *p, size_t cap) {
    (void)ctx; unsigned char hdr[2];
    if (read_exact(fd, hdr, 2)) return -1;
    size_t n = hdr[0] | ((size_t)hdr[1] << 8);
    if (!n || n > cap || read_exact(fd, p, n)) return -1;
    return (int)n;
}
static void send_response(int fd, const char *proto, int status, const char *message,
                          const char *type, const uint8_t *body, size_t len, int seq) {
    (void)proto; (void)status; (void)message; (void)type; (void)body; (void)len; (void)seq;
    assert(write(fd, "B", 1) == 1);
}
static void route_request(int fd, const HTTPReq *r) {
    if (!strcmp(r->path, "/switch")) {
        pthread_mutex_lock(&g_control_owner_lock); g_enc.active = true; pthread_mutex_unlock(&g_control_owner_lock);
    }
    if (!strcmp(r->path, "/body")) assert(r->bodyLen == 5 && !memcmp(r->body, "hello", 5));
    assert(write(fd, "R", 1) == 1);
}
static void mock_exit(int code) { (void)code; pthread_exit(NULL); }
#define exit mock_exit
''' + client + r'''
#undef exit
static void *serve(void *p) { handle_client((int)(intptr_t)p); return NULL; }
static void start(int fd, pthread_t *t) { assert(!pthread_create(t, NULL, serve, (void *)(intptr_t)fd)); }
static void expect(int fd, const char *expected) {
    char b[32] = {0}; size_t n = strlen(expected); assert(n < sizeof(b));
    assert(read_exact(fd, b, n) == 0); assert(!memcmp(b, expected, n));
}
static void frame(int fd, const char *p) {
    size_t n = strlen(p); unsigned char h[2] = {n & 255, n >> 8};
    assert(write(fd, h, 2) == 2); assert(write(fd, p, n) == (ssize_t)n);
}
int main(void) {
    HTTPReq r;
    const char *partial = "POST /body RTSP/1.0\r\nContent-Len";
    assert(!parse_http((const uint8_t *)partial, strlen(partial), &r) && !r.invalid);
    const char *bad[] = {"POST / RTSP/1.0\r\nContent-Length: -1\r\n\r\n",
      "POST / RTSP/1.0\r\nContent-Length: 99999999999999999999999\r\n\r\n",
      "POST / RTSP/1.0\r\nContent-Length: 1\r\nContent-Length: 1\r\n\r\n"};
    for (size_t i = 0; i < sizeof(bad)/sizeof(bad[0]); i++)
        assert(!parse_http((const uint8_t *)bad[i], strlen(bad[i]), &r) && r.invalid);
    int a[2], b[2]; pthread_t ta, tb;
    assert(!socketpair(AF_UNIX, SOCK_STREAM, 0, a)); start(a[0], &ta);
    const char *part1 = "POST /body RTSP/1.0\r\nContent-Len";
    const char *part2 = "gth: 5\r\n\r\nhelloGET /info RTSP/1.0\r\n\r\n";
    assert(write(a[1], part1, strlen(part1)) == (ssize_t)strlen(part1));
    assert(write(a[1], part2, strlen(part2)) == (ssize_t)strlen(part2)); expect(a[1], "RR");
    assert(!socketpair(AF_UNIX, SOCK_STREAM, 0, b)); start(b[0], &tb);
    const char *other = "POST /setup RTSP/1.0\r\n\r\n";
    assert(write(b[1], other, strlen(other)) == (ssize_t)strlen(other)); expect(b[1], "B");
    close(b[1]); pthread_join(tb, NULL);
    const char *sw = "POST /switch RTSP/1.0\r\n\r\n";
    assert(write(a[1], sw, strlen(sw)) == (ssize_t)strlen(sw));
    frame(a[1], "POST /body RTSP/1.0\r\nContent-");
    frame(a[1], "Length: 5\r\n\r\nhelloGET /info RTSP/1.0\r\n\r\n");
    expect(a[1], "RRR");
    assert(!socketpair(AF_UNIX, SOCK_STREAM, 0, b)); start(b[0], &tb);
    const char *get = "GET /info RTSP/1.0\r\n\r\n";
    assert(write(b[1], get, strlen(get)) == (ssize_t)strlen(get)); expect(b[1], "R");
    close(b[1]); pthread_join(tb, NULL);
    frame(a[1], get); expect(a[1], "R");
    close(a[1]); pthread_join(ta, NULL);
    puts("HTTP parser, plaintext/encrypted framing and multiple clients: PASS");
    return 0;
}
'''

with tempfile.TemporaryDirectory(prefix='showcase-http-') as tmp:
    cfile = Path(tmp) / 'harness.c'
    binary = Path(tmp) / 'harness'
    cfile.write_text(harness)
    subprocess.run(['clang', '-g', '-fsanitize=address,undefined', '-pthread',
                    str(cfile), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True, timeout=30)

assert '[ENC] Plaintext hex' not in source
assert '[ENC] ASCII:' not in source
assert '[EVENT] ASCII:' not in source
assert '[SCREEN] Decrypted hex:' not in source
auth = source[source.index('static void handle_auth_setup'):source.index('static void handle_rtsp_setup')]
assert 'if (dv.length == 32 && !pkData) pkData = dv;' in auth
assert 'auth-setup: not a plist, hex' not in auth
assert '[val UTF8String]' not in auth and '[[val description]' not in auth
generic = source[source.index('static void handle_post_generic'):source.index('/* ═══════════════════════════════════════════════════════════════\n * Request Router')]
assert 'handle_command_dictionary(obj)' in generic
assert '[[obj description]' not in generic and 'printf("[AP] hex' not in generic
