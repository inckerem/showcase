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
CLIENT_START = 'static bool request_allowed_before_pair_verify'
CLIENT_END = 'static bool start_airplay_server'
assert CLIENT_START in source and CLIENT_END in source
client = source[source.index(CLIENT_START):source.index(CLIENT_END)]

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
#include <stdatomic.h>
#include <time.h>
#include <poll.h>
#include <netdb.h>
static char g_iphone_ip[64];
static __thread bool t_quiet_request_log = false;
static bool sockaddr_to_numeric(const struct sockaddr *sa, socklen_t len, char *host, size_t hl, char *serv, size_t sl) { (void)sa; (void)len; snprintf(host, hl, "local"); snprintf(serv, sl, "0"); return true; }
#define STATUS_IPHONE_CONNECTED 1
static atomic_int g_status_count;
static void app_send_status(int s) { if (s == STATUS_IPHONE_CONNECTED) atomic_fetch_add(&g_status_count, 1); }
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
    (void)proto; (void)message; (void)type; (void)body; (void)len; (void)seq;
    /* U = 470 (RTSP, not pair-verified), F = 403 (HTTP, not pair-verified),
     * B = 503 (another connection owns pairing). */
    const char *code = status == 470 ? "U" : status == 403 ? "F" : status == 503 ? "B" : "?";
    assert(write(fd, code, 1) == 1);
}
static void route_request(int fd, const HTTPReq *r) {
    if (!strcmp(r->path, "/pair-verify")) {
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
    /* Before pair-verify: a split, pipelined stream. Mutating requests are
     * rejected (470 for RTSP, 403 for HTTP), GET /info is served, and
     * nothing claims the session. */
    const char *part1 = "POST /body RTSP/1.0\r\nContent-Len";
    const char *part2 = "gth: 5\r\n\r\nhelloGET /info RTSP/1.0\r\n\r\nSETUP /x RTSP/1.0\r\n\r\n"
                        "POST /body HTTP/1.1\r\nContent-Length: 5\r\n\r\nhello";
    assert(write(a[1], part1, strlen(part1)) == (ssize_t)strlen(part1));
    assert(write(a[1], part2, strlen(part2)) == (ssize_t)strlen(part2)); expect(a[1], "URUF");
    assert(atomic_load(&g_status_count) == 0);
    /* The first client to start pairing claims the session. */
    const char *ps = "POST /pair-setup RTSP/1.0\r\n\r\n";
    assert(write(a[1], ps, strlen(ps)) == (ssize_t)strlen(ps)); expect(a[1], "R");
    assert(atomic_load(&g_status_count) == 1);
    /* A second client may probe /info but cannot take over pairing. */
    assert(!socketpair(AF_UNIX, SOCK_STREAM, 0, b)); start(b[0], &tb);
    const char *get = "GET /info RTSP/1.0\r\n\r\n";
    assert(write(b[1], get, strlen(get)) == (ssize_t)strlen(get)); expect(b[1], "R");
    assert(write(b[1], ps, strlen(ps)) == (ssize_t)strlen(ps)); expect(b[1], "B");
    const char *setup = "SETUP /x RTSP/1.0\r\n\r\n";
    assert(write(b[1], setup, strlen(setup)) == (ssize_t)strlen(setup)); expect(b[1], "U");
    close(b[1]); pthread_join(tb, NULL);
    assert(atomic_load(&g_status_count) == 1);
    /* pair-verify switches the owner to encrypted framing; requests split
     * across records and pipelined within one record are all served. */
    const char *pv = "POST /pair-verify RTSP/1.0\r\n\r\n";
    assert(write(a[1], pv, strlen(pv)) == (ssize_t)strlen(pv)); expect(a[1], "R");
    frame(a[1], "POST /body RTSP/1.0\r\nContent-");
    frame(a[1], "Length: 5\r\n\r\nhelloGET /info RTSP/1.0\r\n\r\n");
    frame(a[1], setup);
    expect(a[1], "RRR");
    /* Discovery probes from another client still work during the session. */
    assert(!socketpair(AF_UNIX, SOCK_STREAM, 0, b)); start(b[0], &tb);
    assert(write(b[1], get, strlen(get)) == (ssize_t)strlen(get)); expect(b[1], "R");
    close(b[1]); pthread_join(tb, NULL);
    frame(a[1], get); expect(a[1], "R");
    assert(atomic_load(&g_status_count) == 1);
    close(a[1]); pthread_join(ta, NULL);
    puts("HTTP parser, pre-verify gating, claim ownership, encrypted framing and multiple clients: PASS");
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
assert 'handle_command_dictionary(obj, control_is_encrypted(sock))' in generic
assert '[[obj description]' not in generic and 'printf("[AP] hex' not in generic
