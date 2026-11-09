#ifndef SHOWCASE_SCREEN_MIRROR_PAIRING_H
#define SHOWCASE_SCREEN_MIRROR_PAIRING_H

#import "screen_mirror_wire.h"
#import <arpa/inet.h>

static inline NSURL *mirror_pairing_url(NSString *host, uint16_t port, NSData *key) {
    if (!host.length || !port || key.length != MirrorKeyBytes) return nil;
    NSString *code = [key base64EncodedStringWithOptions:0];
    code = [[code stringByReplacingOccurrencesOfString:@"+" withString:@"-"]
                  stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
    NSURLComponents *url = [NSURLComponents new];
    url.scheme = @"showcase-mirror";
    url.host = @"pair";
    url.queryItems = @[[NSURLQueryItem queryItemWithName:@"host" value:host],
                       [NSURLQueryItem queryItemWithName:@"port" value:[NSString stringWithFormat:@"%u", port]],
                       [NSURLQueryItem queryItemWithName:@"code" value:code]];
    return url.URL;
}

static inline BOOL mirror_read_pairing_url(NSURL *url, NSString **host, NSString **port, NSData **key) {
    if (!url || url.absoluteString.length > 256) return NO;
    NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    if (![components.scheme.lowercaseString isEqualToString:@"showcase-mirror"] ||
        ![components.host.lowercaseString isEqualToString:@"pair"] || components.user ||
        components.password || components.port || components.path.length || components.fragment ||
        components.queryItems.count != 3) return NO;
    NSMutableDictionary<NSString *, NSString *> *items = [NSMutableDictionary dictionary];
    for (NSURLQueryItem *item in components.queryItems) {
        if (!item.value.length || items[item.name]) return NO;
        items[item.name] = item.value;
    }
    NSString *address = items[@"host"], *service = items[@"port"], *code = items[@"code"];
    struct in_addr ipv4;
    NSCharacterSet *digits = [NSCharacterSet characterSetWithCharactersInString:@"0123456789"];
    if (!address.length || [address rangeOfCharacterFromSet:
            [NSCharacterSet characterSetWithCharactersInString:@"0123456789."].invertedSet].location != NSNotFound ||
        inet_pton(AF_INET, address.UTF8String, &ipv4) != 1 || !service.length || service.length > 5 ||
        [service rangeOfCharacterFromSet:digits.invertedSet].location != NSNotFound ||
        service.integerValue < 1 || service.integerValue > UINT16_MAX || code.length != 24) return NO;
    code = [[code stringByReplacingOccurrencesOfString:@"-" withString:@"+"]
                  stringByReplacingOccurrencesOfString:@"_" withString:@"/"];
    NSData *secret = [[NSData alloc] initWithBase64EncodedString:code options:0];
    if (secret.length != MirrorKeyBytes) return NO;
    if (host) *host = address;
    if (port) *port = service;
    if (key) *key = secret;
    return YES;
}

#endif
