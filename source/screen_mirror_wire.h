#ifndef SHOWCASE_SCREEN_MIRROR_WIRE_H
#define SHOWCASE_SCREEN_MIRROR_WIRE_H

#import <Foundation/Foundation.h>
#import <Network/Network.h>
#import <Security/Security.h>
#import <Security/CipherSuite.h>

/* Length-prefixed TLS records. A zero length is a heartbeat. A video record
 * starts with the two big-endian SPS and PPS lengths, then their bytes, then
 * an H.264 sample with four-byte NAL lengths. Parameter sets mark keyframes. */
enum { MirrorKeyBytes = 16, MirrorMaxFrame = 1024 * 1024 };

static inline nw_parameters_t mirror_parameters(NSData *key) {
    return nw_parameters_create_secure_tcp(^(nw_protocol_options_t tls) {
        sec_protocol_options_t options = nw_tls_copy_sec_protocol_options(tls);
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        sec_protocol_options_set_tls_min_version(options, kTLSProtocol12);
        sec_protocol_options_set_tls_max_version(options, kTLSProtocol12);
        sec_protocol_options_add_tls_ciphersuite(options, TLS_PSK_WITH_AES_128_GCM_SHA256);
#pragma clang diagnostic pop
        dispatch_data_t psk = dispatch_data_create(key.bytes, key.length, NULL,
                                                   DISPATCH_DATA_DESTRUCTOR_DEFAULT);
        const char identity[] = "Showcase Mirror 1";
        dispatch_data_t name = dispatch_data_create(identity, sizeof(identity) - 1, NULL,
                                                    DISPATCH_DATA_DESTRUCTOR_DEFAULT);
        sec_protocol_options_add_pre_shared_key(options, psk, name);
    }, ^(nw_protocol_options_t tcp) {
        nw_tcp_options_set_no_delay(tcp, true);
    });
}

static inline NSData *mirror_received_data(dispatch_data_t content) {
    if (!content) return nil;
    const void *bytes;
    size_t size;
    __attribute__((objc_precise_lifetime))
    dispatch_data_t mapped = dispatch_data_create_map(content, &bytes, &size);
    NSData *data = [NSData dataWithBytes:bytes length:size];
    (void)mapped;
    return data;
}

#endif
