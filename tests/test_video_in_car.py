"""Exercise the bench receiver with real encrypted control and data records."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]

harness = r'''
#define main showcase_services_main
#include "carplay_services.m"
#undef main
#include <assert.h>

static void make_pair(int fds[2]) {
    assert(socketpair(AF_UNIX, SOCK_STREAM, 0, fds) == 0);
    struct timeval timeout = { .tv_sec = 3 };
    for (unsigned i = 0; i < 2; ++i)
        assert(setsockopt(fds[i], SOL_SOCKET, SO_RCVTIMEO,
                          &timeout, sizeof(timeout)) == 0);
}

static NSData *wire_request(NSString *line, uint32_t streamID, NSDictionary *message) {
    NSData *body = message ? car_video_encode(message) : [NSData data];
    NSMutableString *header = [NSMutableString stringWithFormat:
        @"%@\r\nCSeq: 1\r\nContent-Length: %lu\r\n", line, (unsigned long)body.length];
    if (streamID) [header appendFormat:@"X-Apple-StreamID: %u\r\n", streamID];
    [header appendString:@"\r\n"];
    NSMutableData *wire = [[header dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
    [wire appendData:body];
    return wire;
}

static void request(int fd, NSString *line, uint32_t streamID, NSDictionary *message) {
    NSData *wire = wire_request(line, streamID, message);
    HTTPReq parsed;
    assert(parse_http(wire.bytes, wire.length, &parsed));
    assert(parsed.appleStreamID == streamID);
    route_request(fd, &parsed);
}

static NSDictionary *read_message(int fd, encrypted_ctx_t *keys, uint32_t expectedStream) {
    NSMutableData *wire = [NSMutableData data];
    HTTPReq parsed;
    do {
        uint8_t buf[ENCRYPTED_MAX_READ_SIZE];
        int n = keys ? enc_recv_frame(fd, keys, buf, sizeof(buf)) :
                       (int)read(fd, buf, sizeof(buf));
        assert(n > 0);
        [wire appendBytes:buf length:n];
    } while (!parse_http(wire.bytes, wire.length, &parsed) && !parsed.invalid);
    assert(!parsed.invalid && parsed.appleStreamID == expectedStream);
    assert(!strcmp(parsed.path, "200") || !strcmp(parsed.path, "/command"));
    return car_video_decode([NSData dataWithBytes:parsed.body length:parsed.bodyLen]);
}

static NSDictionary *read_app(int fd) {
    uint8_t header[5];
    assert(tcp_read_exact(fd, header, sizeof(header)));
    assert(header[4] == MSG_CAR_VIDEO_COMMAND);
    uint32_t length;
    memcpy(&length, header, sizeof(length));
    assert(length > 0 && length <= CAR_VIDEO_MAX_MESSAGE);
    NSMutableData *body = [NSMutableData dataWithLength:length];
    assert(tcp_read_exact(fd, body.mutableBytes, length));
    return car_video_decode(body);
}

static void expect_app_status(int fd, uint8_t code) {
    const uint8_t expected[] = {1, 0, 0, 0, MSG_STATUS, code};
    uint8_t actual[sizeof(expected)];
    assert(tcp_read_exact(fd, actual, sizeof(actual)));
    assert(memcmp(actual, expected, sizeof(actual)) == 0);
}

static void expect_no_app_message(int fd) {
    uint8_t byte;
    assert(recv(fd, &byte, 1, MSG_DONTWAIT) == -1);
    assert(errno == EAGAIN || errno == EWOULDBLOCK);
}

static void settings_roundtrip(void) {
    int sockets[2];
    make_pair(sockets);
    int receiver = sockets[0], peer = sockets[1];
    encrypted_ctx_t client = {0};
    memset(client.writeKey, 0x17, sizeof(client.writeKey));
    memset(client.readKey, 0x81, sizeof(client.readKey));
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        encrypted_ctx_t keys = {0};
        memset(keys.readKey, 0x17, sizeof(keys.readKey));
        memset(keys.writeKey, 0x81, sizeof(keys.writeKey));
        car_video_read_settings(receiver, &keys);
        close(receiver);
        dispatch_semaphore_signal(done);
    });
    uint8_t packet[68] = {0, 0, 0, 36, 's', 'y', 'n', 'c'};
    packet[27] = 0x25;
    packet[39] = 32;
    memcpy(packet + 40, "sync", 4);
    packet[63] = 0x48;
    assert(enc_send_frame(peer, &client, packet, 19) == 0);
    assert(enc_send_frame(peer, &client, packet + 19, sizeof(packet) - 19) == 0);
    uint8_t reply[32];
    assert(enc_recv_frame(peer, &client, reply, sizeof(reply)) == sizeof(reply));
    assert(reply[3] == 32 && !memcmp(reply + 4, "rply", 4) && reply[27] == 0x25);
    assert(enc_recv_frame(peer, &client, reply, sizeof(reply)) == sizeof(reply));
    assert(reply[27] == 0x48);
    close(peer);
    assert(dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) == 0);
}

int main(void) {
    @autoreleasepool {
        int control[2], event[2], app[2];
        make_pair(control);
        make_pair(event);
        make_pair(app);
        g_app_sock = app[0];
        g_session_active = true;  /* Port listeners are outside this socket-pair test. */
        g_useHK = true;
        request(control[0], @"GET /info RTSP/1.0", 0, nil);
        NSDictionary *info = read_message(control[1], NULL, 0);
        NSDictionary *video = info[@"videoPlaybackInfo"];
        assert((video != nil) == SHOWCASE_VIDEO_IN_CAR_BENCH);
        NSDictionary *proposal = @{@"features": @[@"videoPlayback", @"mainBuffered", @"unknown"]};
        request(control[0], @"SETUP /stream RTSP/1.0", 0, proposal);
        assert(![read_message(control[1], NULL, 0)[@"enabledFeatures"] containsObject:@"videoPlayback"]);
        expect_app_status(app[1], STATUS_SESSION_SETUP);
        NSDictionary *hostUI = @{@"type": @"requestUI"};
        request(control[0], @"POST /command RTSP/1.0", 0, hostUI);
        assert(read_message(control[1], NULL, 0) == nil);
        expect_no_app_message(app[1]);
        g_control_owner = control[0];
        g_enc.active = true;
        g_event_enc.active = true;
        g_event_client_fd = event[0];
        g_receiver_audio = true;
        encrypted_ctx_t controlPeer = {0}, eventPeer = {0};
        request(control[0], @"SETUP /stream RTSP/1.0", 0, proposal);
        NSArray *enabled = read_message(control[1], &controlPeer, 0)[@"enabledFeatures"];
        expect_app_status(app[1], STATUS_SESSION_SETUP);
        request(control[0], @"POST /command RTSP/1.0", 0, hostUI);
        assert(read_message(control[1], &controlPeer, 0) == nil);
        if (SHOWCASE_MIRROR_BENCH) expect_app_status(app[1], STATUS_HOST_UI_REQUESTED);
        else expect_no_app_message(app[1]);
        if (!SHOWCASE_VIDEO_IN_CAR_BENCH) {
            assert([enabled isEqual:@[@"mainBuffered"]]);
            assert(!atomic_load(&g_car_video_negotiated));
            return 0;
        }
        assert([video[@"videoPlaybackAllowed"] boolValue]);
        NSData *bits = [[NSData alloc] initWithBase64EncodedString:video[@"featuresEx"] options:0];
        const uint8_t expected[] = {0x81, 0x02, 0x04, 0x04, 0x61, 0, 0, 0, 1};
        assert(bits.length == sizeof(expected) && memcmp(bits.bytes, expected, sizeof(expected)) == 0);
        assert(([enabled isEqual:@[@"mainBuffered", @"videoPlayback"]]));
        NSDictionary *availability = read_message(event[1], &eventPeer, 0);
        assert([availability[@"type"] isEqual:@"setVideoPlaybackAllowed"]);
        assert([availability[@"params"][@"videoPlaybackAllowed"] boolValue]);
        NSData *hostEvent = wire_request(@"POST /command RTSP/1.0", 0, hostUI);
        assert(process_event_command_frame(hostEvent.bytes, hostEvent.length));
        assert(read_message(event[1], &eventPeer, 0) == nil);
        expect_app_status(app[1], STATUS_HOST_UI_REQUESTED);

        NSDictionary *videoUI = @{@"type": @"requestUI", @"params": @{@"url": @"videoplayback:"}};
        request(control[0], @"POST /command RTSP/1.0", 0, videoUI);
        assert(read_message(control[1], &controlPeer, 0) == nil);
        expect_no_app_message(app[1]);

        NSArray *remote = @[
            @{@"type": @130, @"clientTypeUUID": @"A6B27562-B43A-4F2D-B75F-82391E250194", @"controlType": @1},
            @{@"type": @130, @"clientTypeUUID": @"E3DC3EA6-E6C3-4B30-847C-B7ACFEBEA654", @"controlType": @1}
        ];
        request(control[0], @"SETUP /stream RTSP/1.0", 0, @{@"streams": remote});
        NSArray *streams = read_message(control[1], &controlPeer, 0)[@"streams"];
        assert(streams.count == 2);
        assert([streams[0][@"streamID"] isEqual:@3] && !streams[0][@"dataPort"]);
        assert([streams[1][@"streamID"] isEqual:@4] && !streams[1][@"dataPort"]);

        NSDictionary *seek = @{@"type": @"seek", @"kind": @"request", @"messageID": @7};
        NSDictionary *envelope = @{@"params": @{@"data": car_video_encode(seek)}};
        request(control[0], @"POST /command RTSP/1.0", 3, envelope);
        assert(read_message(control[1], &controlPeer, 0) == nil);
        NSDictionary *command = read_app(app[1]);
        assert([command[@"streamID"] isEqual:@3] && [command[@"message"] isEqual:seek]);
        NSData *wire = wire_request(@"POST /command RTSP/1.0", 4, envelope);
        assert(process_event_command_frame(wire.bytes, wire.length));
        assert(read_message(event[1], &eventPeer, 0) == nil);
        assert([read_app(app[1])[@"streamID"] isEqual:@4]);
        NSDictionary *reply = @{@"type": @"seek", @"kind": @"response", @"messageID": @7};
        car_video_send_reply(car_video_encode(@{@"streamID": @4, @"message": reply}));
        NSDictionary *outgoing = read_message(event[1], &eventPeer, 4);
        assert([car_video_decode(outgoing[@"params"][@"data"]) isEqual:reply]);

        request(control[0], @"TEARDOWN /stream RTSP/1.0", 0,
                @{@"streams": @[@{@"type": @130, @"streamID": @4}]});
        assert(read_message(control[1], &controlPeer, 0) == nil);
        NSDictionary *stop = read_app(app[1]);
        assert([stop[@"streamID"] isEqual:@4] && !stop[@"message"]);
        assert(car_video_stream_active_locked(3) && !car_video_stream_active_locked(4));
        assert(atomic_load(&g_car_video_negotiated));
        request(control[0], @"TEARDOWN /stream RTSP/1.0", 0, nil);
        assert(read_message(control[1], &controlPeer, 0) == nil);
        assert([read_app(app[1])[@"streamID"] isEqual:@0]);
        assert(!atomic_load(&g_car_video_negotiated));
        settings_roundtrip();
    }
    return 0;
}
'''

with tempfile.TemporaryDirectory(prefix="showcase-video-test-") as folder:
    path = Path(folder)
    source = path / "test.m"
    source.write_text(harness)
    for bench in (0, 1):
        binary = path / f"test-{bench}"
        subprocess.run([
            "clang", "-O1", "-fobjc-arc", f"-DSHOWCASE_VIDEO_IN_CAR_BENCH={bench}",
            f"-DSHOWCASE_MIRROR_BENCH={bench}",
            "-I", str(root / "source"), str(source), "source/carplay_pair.c",
            "source/vendor/monocypher/monocypher.c",
            "source/vendor/monocypher/monocypher-ed25519.c",
            "source/vendor/libtommath/tommath.c",
            "-framework", "Foundation", "-framework", "Security", "-o", str(binary),
        ], check=True, cwd=root)
        subprocess.run([str(binary)], check=True, timeout=20)

print("PASS: bench-only negotiation, encrypted settings, OEM command IPC and stream teardown")
