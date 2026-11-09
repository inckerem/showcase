#import "screen_mirror_pairing.h"
#import <CoreImage/CoreImage.h>

@interface ShowcaseMirrorReceiver : UIViewController
@property (nonatomic, copy) dispatch_block_t onReturnToCarPlay;
@property (nonatomic, strong) nw_listener_t listener;
@property (nonatomic, strong) nw_connection_t peer;
@property (nonatomic, strong) AVSampleBufferDisplayLayer *display;
@property (nonatomic, strong) UILabel *status;
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

    self.pairingQR = [UIImageView new];
    self.pairingQR.contentMode = UIViewContentModeScaleAspectFit;
    self.pairingQR.layer.magnificationFilter = kCAFilterNearest;
    self.pairingQR.layer.minificationFilter = kCAFilterNearest;
    self.pairingQR.isAccessibilityElement = YES;
    self.pairingQR.accessibilityLabel = @"Showcase eşleştirme QR kodu";
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
    self.status.text = self.pairingQR.hidden ? @"QR kodu oluşturulamadı. Ekranı kapatıp tekrar aç."
        : @"Showcase Mirror’da QR kodunu okut.\nİki cihaz da aynı Wi-Fi ağında olmalı.";
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
        self.status.text = @"iPad’i iPhone ile aynı Wi-Fi ağına bağla.";
        return;
    }

    NSMutableData *key = [NSMutableData dataWithLength:MirrorKeyBytes];
    if (SecRandomCopyBytes(kSecRandomDefault, key.length, key.mutableBytes) != errSecSuccess) {
        self.status.text = @"Eşleştirme kodu oluşturulamadı.";
        return;
    }
    nw_parameters_t params = mirror_parameters(key);
    nw_parameters_set_local_endpoint(params, nw_endpoint_create_host(host.UTF8String, "0"));
    self.listener = nw_listener_create(params);
    if (!self.listener) {
        self.status.text = @"Wi-Fi alıcısı başlatılamadı.";
        return;
    }
    self.status.text = @"Wi-Fi alıcısı açılıyor…";
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
            receiver.status.text = @"Wi-Fi alıcısı başlatılamadı.";
            [receiver.view setNeedsLayout];
        }
    });
    nw_listener_set_new_connection_handler(self.listener, ^(nw_connection_t peer) {
        ShowcaseMirrorReceiver *receiver = weakSelf;
        if (!receiver.listener || receiver.peer) {
            nw_connection_cancel(peer);
            return;
        }
        [receiver acceptPeer:peer];
    });
    nw_listener_start(self.listener);
}

- (void)acceptPeer:(nw_connection_t)peer {
    self.peer = peer;
    self.needsKeyframe = YES;
    self.lastPacket = NSProcessInfo.processInfo.systemUptime;
    self.lastEnqueue = self.lastPacket;
    __weak typeof(self) weakSelf = self;
    self.watchdog = [NSTimer scheduledTimerWithTimeInterval:2.0 repeats:YES block:^(NSTimer *timer) {
        ShowcaseMirrorReceiver *receiver = weakSelf;
        if (receiver && NSProcessInfo.processInfo.systemUptime - receiver.lastPacket > 8.0)
            [receiver disconnectPeer];
    }];
    nw_connection_set_queue(peer, dispatch_get_main_queue());
    nw_connection_set_state_changed_handler(peer, ^(nw_connection_state_t state, nw_error_t error) {
        ShowcaseMirrorReceiver *receiver = weakSelf;
        if (receiver.peer != peer) return;
        if (state == nw_connection_state_ready) [receiver readHeaderFrom:peer];
        if (state == nw_connection_state_failed || state == nw_connection_state_cancelled)
            [receiver disconnectPeer];
    });
    nw_connection_start(peer);
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
    [self disconnectPeer];
    if (self.listener) {
        nw_listener_cancel(self.listener);
        self.listener = nil;
    }
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end
