#import "screen_mirror_pairing.h"
#import <CoreImage/CoreImage.h>

// Connections that have not finished the TLS-PSK handshake are untrusted: they are held in a
// small bounded set with a short deadline and never evict each other or the live peer.
static const NSUInteger MirrorMaxPendingHandshakes = 8;
static const int64_t MirrorHandshakeTimeoutSeconds = 8;
// Per remote host, so one LAN host cannot fill the whole set and lock the real iPhone out.
// Two leaves room for an iPhone reconnect while its previous half-open attempt still waits.
static const NSUInteger MirrorMaxPendingHandshakesPerHost = 2;

static NSString *mirror_remote_host(nw_connection_t connection) {
    nw_endpoint_t endpoint = nw_connection_copy_endpoint(connection);
    if (!endpoint) return @"";
    if (nw_endpoint_get_type(endpoint) == nw_endpoint_type_host) {
        const char *name = nw_endpoint_get_hostname(endpoint);
        return name ? @(name) : @"";
    }
    char *address = nw_endpoint_copy_address_string(endpoint);
    NSString *host = address ? @(address) : @"";
    free(address);
    return host ?: @"";
}

@interface ShowcaseMirrorReceiver : UIViewController
@property (nonatomic, copy) dispatch_block_t onReturnToCarPlay;
@property (nonatomic, strong) nw_listener_t listener;
@property (nonatomic, strong) nw_connection_t peer;
@property (nonatomic, strong) NSMutableArray<nw_connection_t> *candidates;
@property (nonatomic, strong) AVSampleBufferDisplayLayer *display;
@property (nonatomic, strong) UILabel *status;
@property (nonatomic, strong) UILabel *staleStatus;
@property (nonatomic, strong) UIImageView *pairingQR;
@property (nonatomic, strong) NSTimer *watchdog;
@property (nonatomic) CFTimeInterval lastPacket;
@property (nonatomic) CFTimeInterval lastEnqueue;
@property (nonatomic) CMVideoFormatDescriptionRef format;
@property (nonatomic) BOOL needsKeyframe;
- (void)finish;
@end

@implementation ShowcaseMirrorReceiver

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.blackColor;
    self.display = [AVSampleBufferDisplayLayer layer];
    self.display.videoGravity = AVLayerVideoGravityResizeAspect;
    [self.view.layer addSublayer:self.display];

    self.status = [UILabel new];
    self.status.textAlignment = NSTextAlignmentCenter;
    self.status.numberOfLines = 0;
    self.status.textColor = UIColor.whiteColor;
    self.status.font = [UIFont systemFontOfSize:21];
    [self.view addSubview:self.status];

    self.staleStatus = [UILabel new];
    self.staleStatus.text = L(@"Waiting for a new frame…\nShowing the last frame received.");
    self.staleStatus.textAlignment = NSTextAlignmentCenter;
    self.staleStatus.numberOfLines = 0;
    self.staleStatus.textColor = UIColor.whiteColor;
    self.staleStatus.font = self.status.font;
    self.staleStatus.hidden = YES;
    [self.view addSubview:self.staleStatus];

    self.pairingQR = [UIImageView new];
    self.pairingQR.contentMode = UIViewContentModeScaleAspectFit;
    self.pairingQR.layer.magnificationFilter = kCAFilterNearest;
    self.pairingQR.layer.minificationFilter = kCAFilterNearest;
    self.pairingQR.isAccessibilityElement = YES;
    self.pairingQR.accessibilityLabel = L(@"Showcase pairing QR code");
    self.pairingQR.hidden = YES;
    [self.view addSubview:self.pairingQR];

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    [close setTitle:@"‹ CarPlay" forState:UIControlStateNormal];
    close.titleLabel.font = [UIFont systemFontOfSize:19 weight:UIFontWeightSemibold];
    close.tintColor = UIColor.whiteColor;
    close.backgroundColor = [UIColor colorWithWhite:0 alpha:0.75];
    close.layer.cornerRadius = 10;
    close.translatesAutoresizingMaskIntoConstraints = NO;
    [close addTarget:self action:@selector(returnToCarPlay) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:close];
    [NSLayoutConstraint activateConstraints:@[
        [close.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:12],
        [close.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:10],
        [close.widthAnchor constraintEqualToConstant:110],
        [close.heightAnchor constraintEqualToConstant:44]
    ]];
    [self startListening];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    self.display.frame = self.view.bounds;
    CGRect area = UIEdgeInsetsInsetRect(self.view.bounds, self.view.safeAreaInsets);
    self.staleStatus.frame = CGRectInset(area, 20, 60);
    if (self.pairingQR.hidden) {
        self.status.frame = CGRectInset(area, 20, 60);
        return;
    }
    CGFloat side = MAX(0, MIN(360, MIN(CGRectGetWidth(area) - 32, CGRectGetHeight(area) - 136)));
    CGFloat top = CGRectGetMidY(area) - side / 2 - 6;
    self.pairingQR.frame = CGRectMake(CGRectGetMidX(area) - side / 2, top, side, side);
    self.status.frame = CGRectMake(CGRectGetMinX(area) + 16, top + side + 6,
                                   MAX(0, CGRectGetWidth(area) - 32), 60);
}

- (void)showPairingURL:(NSURL *)url {
    CIFilter *filter = [CIFilter filterWithName:@"CIQRCodeGenerator"];
    [filter setValue:[url.absoluteString dataUsingEncoding:NSUTF8StringEncoding] forKey:@"inputMessage"];
    [filter setValue:@"M" forKey:@"inputCorrectionLevel"];
    CIImage *modules = filter.outputImage;
    if (modules) {
        CGRect quietZone = CGRectInset(modules.extent, -4, -4);
        CIImage *white = [CIImage imageWithColor:[CIColor colorWithRed:1 green:1 blue:1]];
        CIImage *padded = [[modules imageByCompositingOverImage:white] imageByCroppingToRect:quietZone];
        CGImageRef rendered = [[CIContext contextWithOptions:nil] createCGImage:padded fromRect:quietZone];
        if (rendered) {
            self.pairingQR.image = [UIImage imageWithCGImage:rendered];
            CGImageRelease(rendered);
        }
    }
    self.pairingQR.hidden = self.pairingQR.image == nil;
    self.status.text = self.pairingQR.hidden ? L(@"Could not create the QR code. Close this screen and open it again.")
        : L(@"Scan the QR code in Showcase Mirror.\nBoth devices must be on the same Wi-Fi network.");
    [self.view setNeedsLayout];
}

- (void)startListening {
    NSString *iface = shared_wifi_interface();
    struct ifaddrs *addresses = NULL;
    NSString *host = nil;
    if (iface && getifaddrs(&addresses) == 0) {
        for (struct ifaddrs *entry = addresses; entry; entry = entry->ifa_next) {
            if (!entry->ifa_addr || entry->ifa_addr->sa_family != AF_INET ||
                strcmp(entry->ifa_name, iface.UTF8String) != 0) continue;
            char ip[INET_ADDRSTRLEN];
            struct sockaddr_in *address = (struct sockaddr_in *)entry->ifa_addr;
            if (inet_ntop(AF_INET, &address->sin_addr, ip, sizeof(ip))) {
                host = @(ip);
                break;
            }
        }
        freeifaddrs(addresses);
    }
    if (!host) {
        self.status.text = L(@"Connect the iPad to the same Wi-Fi network as the iPhone.");
        return;
    }

    NSMutableData *key = [NSMutableData dataWithLength:MirrorKeyBytes];
    if (SecRandomCopyBytes(kSecRandomDefault, key.length, key.mutableBytes) != errSecSuccess) {
        self.status.text = L(@"Could not create the pairing code.");
        return;
    }
    nw_parameters_t params = mirror_parameters(key);
    nw_parameters_set_local_endpoint(params, nw_endpoint_create_host(host.UTF8String, "0"));
    self.listener = nw_listener_create(params);
    if (!self.listener) {
        self.status.text = L(@"Could not start the Wi-Fi receiver.");
        return;
    }
    self.status.text = L(@"Starting the Wi-Fi receiver…");
    __weak typeof(self) weakSelf = self;
    nw_listener_set_queue(self.listener, dispatch_get_main_queue());
    nw_listener_set_state_changed_handler(self.listener, ^(nw_listener_state_t state, nw_error_t error) {
        ShowcaseMirrorReceiver *receiver = weakSelf;
        if (!receiver.listener) return;
        if (state == nw_listener_state_ready) {
            [receiver showPairingURL:mirror_pairing_url(host, nw_listener_get_port(receiver.listener), key)];
        } else if (state == nw_listener_state_failed) {
            receiver.pairingQR.image = nil;
            receiver.pairingQR.hidden = YES;
            receiver.status.text = L(@"Could not start the Wi-Fi receiver.");
            [receiver.view setNeedsLayout];
        }
    });
    nw_listener_set_new_connection_handler(self.listener, ^(nw_connection_t peer) {
        ShowcaseMirrorReceiver *receiver = weakSelf;
        if (!receiver.listener) {
            nw_connection_cancel(peer);
            return;
        }
        [receiver stageCandidate:peer];
    });
    nw_listener_start(self.listener);
}

- (void)setVideoStale:(BOOL)stale {
    if (self.staleStatus.hidden == !stale) return;
    self.staleStatus.hidden = !stale;
    self.display.opacity = stale ? 0.25f : 1.0f;
}

// Every new connection (first connect or a reconnect after a Wi-Fi blip / force-quit) waits in
// the pending set until it finishes the TLS-PSK handshake, which proves it holds this session's
// key. Only then may it become (or replace) the peer, so an unauthenticated connection can
// neither cancel a handshaking iPhone nor occupy the peer slot. When the set is full the
// newcomer is refused instead of evicting a pending one; each remote host is also capped so a
// single LAN host cannot hold every slot.
- (void)stageCandidate:(nw_connection_t)peer {
    if (!self.candidates) self.candidates = [NSMutableArray array];
    if (self.candidates.count >= MirrorMaxPendingHandshakes) {
        ip_log("mirror: too many pending handshakes; refusing connection");
        nw_connection_cancel(peer);
        return;
    }
    NSString *host = mirror_remote_host(peer);
    NSUInteger fromHost = 0;
    for (nw_connection_t pending in self.candidates)
        if ([mirror_remote_host(pending) isEqualToString:host]) fromHost++;
    if (fromHost >= MirrorMaxPendingHandshakesPerHost) {
        ip_log("mirror: too many pending handshakes from one host; refusing connection");
        nw_connection_cancel(peer);
        return;
    }
    [self.candidates addObject:peer];
    __weak typeof(self) weakSelf = self;
    nw_connection_set_queue(peer, dispatch_get_main_queue());
    nw_connection_set_state_changed_handler(peer, ^(nw_connection_state_t state, nw_error_t error) {
        ShowcaseMirrorReceiver *receiver = weakSelf;
        if (![receiver isCandidate:peer]) return;
        if (state == nw_connection_state_ready) {
            [receiver.candidates removeObjectIdenticalTo:peer];
            if (!receiver.listener) {
                nw_connection_set_state_changed_handler(peer, nil);
                nw_connection_cancel(peer);
                return;
            }
            if (receiver.peer) {
                ip_log("mirror peer reconnected; replacing previous connection");
                [receiver disconnectPeer];
            }
            [receiver acceptPeer:peer];
        } else if (state == nw_connection_state_failed || state == nw_connection_state_cancelled) {
            [receiver dropCandidate:peer];
        }
    });
    nw_connection_start(peer);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, MirrorHandshakeTimeoutSeconds * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        [weakSelf dropCandidate:peer];
    });
}

- (BOOL)isCandidate:(nw_connection_t)peer {
    return self.candidates && [self.candidates indexOfObjectIdenticalTo:peer] != NSNotFound;
}

- (void)dropCandidate:(nw_connection_t)peer {
    if (![self isCandidate:peer]) return;
    [self.candidates removeObjectIdenticalTo:peer];
    nw_connection_set_state_changed_handler(peer, nil);
    nw_connection_cancel(peer);
}

- (void)dropCandidates {
    NSArray<nw_connection_t> *pending = [self.candidates copy];
    [self.candidates removeAllObjects];
    for (nw_connection_t peer in pending) {
        nw_connection_set_state_changed_handler(peer, nil);
        nw_connection_cancel(peer);
    }
}

- (void)acceptPeer:(nw_connection_t)peer {
    self.peer = peer;
    self.needsKeyframe = YES;
    self.lastPacket = NSProcessInfo.processInfo.systemUptime;
    self.lastEnqueue = self.lastPacket;
    __weak typeof(self) weakSelf = self;
    self.watchdog = [NSTimer scheduledTimerWithTimeInterval:2.0 repeats:YES block:^(NSTimer *timer) {
        ShowcaseMirrorReceiver *receiver = weakSelf;
        if (!receiver.peer) return;
        CFTimeInterval now = NSProcessInfo.processInfo.systemUptime;
        if (now - receiver.lastPacket > 8.0) {
            [receiver disconnectPeer];
        } else if (receiver.status.hidden && now - receiver.lastEnqueue > 8.0) {
            // Once video has started, heartbeats keep the peer alive but do not refresh the image.
            [receiver setVideoStale:YES];
        }
    }];
    // The peer already passed the handshake as a candidate and runs on the main queue.
    nw_connection_set_state_changed_handler(peer, ^(nw_connection_state_t state, nw_error_t error) {
        ShowcaseMirrorReceiver *receiver = weakSelf;
        if (receiver.peer != peer) return;
        if (state == nw_connection_state_failed || state == nw_connection_state_cancelled)
            [receiver disconnectPeer];
    });
    [self readHeaderFrom:peer];
}

- (void)disconnectPeer {
    [self.watchdog invalidate];
    self.watchdog = nil;
    if (self.peer) {
        nw_connection_set_state_changed_handler(self.peer, nil);
        nw_connection_cancel(self.peer);
        self.peer = nil;
    }
    if (self.format) {
        CFRelease(self.format);
        self.format = NULL;
    }
    [self.display flushAndRemoveImage];
    [self setVideoStale:NO];
    self.status.hidden = NO;
    self.pairingQR.hidden = self.pairingQR.image == nil;
    [self.view setNeedsLayout];
}

- (void)readHeaderFrom:(nw_connection_t)peer {
    __weak typeof(self) weakSelf = self;
    nw_connection_receive(peer, 4, 4, ^(dispatch_data_t content, nw_content_context_t context,
                                        bool complete, nw_error_t error) {
        ShowcaseMirrorReceiver *receiver = weakSelf;
        if (receiver.peer != peer) return;
        NSData *data = mirror_received_data(content);
        if (error || complete || data.length != 4) {
            [receiver disconnectPeer];
            return;
        }
        uint32_t length;
        [data getBytes:&length length:sizeof(length)];
        length = ntohl(length);
        receiver.lastPacket = NSProcessInfo.processInfo.systemUptime;
        if (length == 0) [receiver readHeaderFrom:peer];
        else if (length < 5 || length > MirrorMaxFrame) [receiver disconnectPeer];
        else [receiver readFrameFrom:peer length:length];
    });
}

- (void)readFrameFrom:(nw_connection_t)peer length:(uint32_t)length {
    __weak typeof(self) weakSelf = self;
    nw_connection_receive(peer, length, length,
        ^(dispatch_data_t content, nw_content_context_t context, bool complete, nw_error_t error) {
        ShowcaseMirrorReceiver *receiver = weakSelf;
        if (receiver.peer != peer) return;
        NSData *data = mirror_received_data(content);
        if (error || complete || data.length != length || ![receiver displayFrame:data]) {
            [receiver disconnectPeer];
            return;
        }
        receiver.lastPacket = NSProcessInfo.processInfo.systemUptime;
        [receiver readHeaderFrom:peer];
    });
}

- (BOOL)displayFrame:(NSData *)data {
    const uint8_t *bytes = data.bytes;
    size_t sizes[] = { (bytes[0] << 8) | bytes[1], (bytes[2] << 8) | bytes[3] };
    size_t offset = 4 + sizes[0] + sizes[1];
    if (offset >= data.length || (sizes[0] == 0) != (sizes[1] == 0)) return NO;
    BOOL keyframe = sizes[0] > 0;
    if (self.display.status == AVQueuedSampleBufferRenderingStatusFailed) {
        ip_log("mirror decoder failed: %@", self.display.error.localizedDescription ?: @"unknown");
        [self.display flushAndRemoveImage];
        self.needsKeyframe = YES;
    }
    if (keyframe) {
        const uint8_t *sets[] = { bytes + 4, bytes + 4 + sizes[0] };
        CMVideoFormatDescriptionRef format = NULL;
        if (CMVideoFormatDescriptionCreateFromH264ParameterSets(NULL, 2, sets, sizes, 4, &format))
            return NO;
        if (!self.format || !CMFormatDescriptionEqual(format, self.format)) {
            if (self.format) CFRelease(self.format);
            [self.display flushAndRemoveImage];
            self.format = format;
        } else {
            CFRelease(format);
        }
    }
    CFTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    if (!self.display.readyForMoreMediaData && keyframe && now - self.lastEnqueue > 0.5) {
        ip_log("mirror decoder stalled; resetting on keyframe");
        [self.display flush];
    }
    if (!self.display.readyForMoreMediaData) {
        self.needsKeyframe = YES;
        return YES;
    }
    if (!self.format || (self.needsKeyframe && !keyframe)) return YES;
    size_t size = data.length - offset;
    if (size < 5) return NO;
    CMBlockBufferRef block = NULL;
    if (CMBlockBufferCreateWithMemoryBlock(NULL, NULL, size, NULL, NULL, 0, size,
                                          kCMBlockBufferAssureMemoryNowFlag, &block)) return NO;
    OSStatus result = CMBlockBufferReplaceDataBytes(bytes + offset, block, 0, size);
    CMSampleBufferRef sample = NULL;
    CMSampleTimingInfo timing = { CMTimeMake(1, 20), kCMTimeInvalid, kCMTimeInvalid };
    if (!result) result = CMSampleBufferCreateReady(NULL, block, self.format, 1, 1, &timing, 1, &size, &sample);
    CFRelease(block);
    if (result) return NO;
    CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sample, true);
    CFMutableDictionaryRef flags = (CFMutableDictionaryRef)CFArrayGetValueAtIndex(attachments, 0);
    CFDictionarySetValue(flags, kCMSampleAttachmentKey_DisplayImmediately, kCFBooleanTrue);
    if (!keyframe) CFDictionarySetValue(flags, kCMSampleAttachmentKey_NotSync, kCFBooleanTrue);
    [self.display enqueueSampleBuffer:sample];
    self.lastEnqueue = now;
    CFRelease(sample);
    [self setVideoStale:NO];
    self.status.hidden = YES;
    self.pairingQR.hidden = YES;
    self.needsKeyframe = NO;
    return YES;
}

- (void)returnToCarPlay {
    dispatch_block_t resume = self.onReturnToCarPlay;
    self.onReturnToCarPlay = nil;
    [self finish];
    if (resume) resume();
}

- (void)finish {
    [self dropCandidates];
    [self disconnectPeer];
    if (self.listener) {
        nw_listener_cancel(self.listener);
        self.listener = nil;
    }
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end
