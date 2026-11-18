#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <VideoToolbox/VideoToolbox.h>
#import <ImageIO/CGImageProperties.h>
#import "screen_mirror_pairing.h"

@interface MirrorScanner : UIViewController <AVCaptureMetadataOutputObjectsDelegate>
@property (nonatomic, copy) void (^onPair)(NSURL *);
@property (nonatomic, strong) AVCaptureSession *capture;
@property (nonatomic, strong) AVCaptureVideoPreviewLayer *preview;
@property (nonatomic, strong) dispatch_queue_t captureQueue;
@property (nonatomic, strong) UILabel *hint;
@property (nonatomic) BOOL scanning;
@end

@implementation MirrorScanner
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.blackColor;
    self.capture = [AVCaptureSession new];
    self.captureQueue = dispatch_queue_create("tr.net.kcs.showcase.qr", DISPATCH_QUEUE_SERIAL);
    self.preview = [AVCaptureVideoPreviewLayer layerWithSession:self.capture];
    self.preview.videoGravity = AVLayerVideoGravityResizeAspectFill;
    [self.view.layer addSublayer:self.preview];
    self.hint = [UILabel new];
    self.hint.text = @"iPad’deki Showcase QR kodunu kameraya göster.";
    self.hint.numberOfLines = 0;
    self.hint.textAlignment = NSTextAlignmentCenter;
    self.hint.textColor = UIColor.whiteColor;
    self.hint.backgroundColor = [UIColor colorWithWhite:0 alpha:0.75];
    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    [close setTitle:@"Vazgeç" forState:UIControlStateNormal];
    close.tintColor = UIColor.whiteColor;
    close.backgroundColor = [UIColor colorWithWhite:0 alpha:0.75];
    [close addTarget:self action:@selector(cancel) forControlEvents:UIControlEventTouchUpInside];
    self.hint.translatesAutoresizingMaskIntoConstraints = close.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.hint];
    [self.view addSubview:close];
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [close.topAnchor constraintEqualToAnchor:safe.topAnchor constant:12],
        [close.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:12],
        [close.widthAnchor constraintEqualToConstant:100],
        [close.heightAnchor constraintEqualToConstant:44],
        [self.hint.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-20],
        [self.hint.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:20],
        [self.hint.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-20]
    ]];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    self.preview.frame = self.view.bounds;
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    self.scanning = YES;
    AVAuthorizationStatus access = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
    if (access == AVAuthorizationStatusAuthorized) {
        [self startCamera];
    } else if (access == AVAuthorizationStatusNotDetermined) {
        [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo completionHandler:^(BOOL granted) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!self.scanning) return;
                if (granted) [self startCamera];
                else [self showCameraPermission];
            });
        }];
    } else {
        [self showCameraPermission];
    }
}

- (void)showCameraPermission {
    self.hint.text = @"Ayarlar → Showcase Mirror bölümünden kamera iznini aç.";
}

- (void)startCamera {
    dispatch_async(self.captureQueue, ^{
        AVCaptureDevice *camera = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
        AVCaptureDeviceInput *input = camera ? [AVCaptureDeviceInput deviceInputWithDevice:camera error:NULL] : nil;
        AVCaptureMetadataOutput *output = [AVCaptureMetadataOutput new];
        if (!input || ![self.capture canAddInput:input] || ![self.capture canAddOutput:output]) {
            dispatch_async(dispatch_get_main_queue(), ^{ self.hint.text = @"Kamera açılamadı."; });
            return;
        }
        [self.capture beginConfiguration];
        [self.capture addInput:input];
        [self.capture addOutput:output];
        BOOL supportsQR = [output.availableMetadataObjectTypes containsObject:AVMetadataObjectTypeQRCode];
        if (supportsQR) {
            [output setMetadataObjectsDelegate:self queue:dispatch_get_main_queue()];
            output.metadataObjectTypes = @[AVMetadataObjectTypeQRCode];
        }
        [self.capture commitConfiguration];
        if (supportsQR) [self.capture startRunning];
        else dispatch_async(dispatch_get_main_queue(), ^{ self.hint.text = @"QR tarama bu kamerada kullanılamıyor."; });
    });
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    self.scanning = NO;
    dispatch_async(self.captureQueue, ^{ [self.capture stopRunning]; });
}

- (void)cancel {
    self.scanning = NO;
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)captureOutput:(AVCaptureOutput *)output didOutputMetadataObjects:(NSArray<__kindof AVMetadataObject *> *)objects
       fromConnection:(AVCaptureConnection *)connection {
    if (!self.scanning) return;
    for (AVMetadataMachineReadableCodeObject *code in objects) {
        if (![code isKindOfClass:AVMetadataMachineReadableCodeObject.class] || !code.stringValue.length) continue;
        NSURL *url = [NSURL URLWithString:code.stringValue];
        if (!mirror_read_pairing_url(url, NULL, NULL, NULL)) {
            self.hint.text = @"iPad’deki Showcase QR kodunu okut.";
            continue;
        }
        self.scanning = NO;
        void (^onPair)(NSURL *) = self.onPair;
        [self dismissViewControllerAnimated:YES completion:^{ if (onPair) onPair(url); }];
        return;
    }
}
@end

@interface MirrorController : UIViewController <SCContentSharingPickerObserver, SCStreamDelegate, SCStreamOutput>
@property (nonatomic, strong) UIButton *action;
@property (nonatomic, strong) UIButton *scan;
@property (nonatomic, strong) UILabel *status;
@property (nonatomic, strong) nw_connection_t peer;
@property (nonatomic, strong) SCStream *stream;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic) VTCompressionSessionRef encoder;
@property (nonatomic) int frameWidth;
@property (nonatomic) int frameHeight;
@property (nonatomic) BOOL awaitingPicker;
@property (nonatomic) BOOL encoding;
@property (nonatomic) BOOL sending;
@property (nonatomic) BOOL needsKeyframe;
@property (nonatomic) CFTimeInterval lastSend;
// When the in-flight write started; a write that never completes means the iPad is gone.
@property (nonatomic) CFTimeInterval sendStarted;
// When the connection path became non-viable (0 while viable).
@property (nonatomic) CFTimeInterval nonViableSince;
@property (nonatomic) CFTimeInterval nextFrameTime;
@property (nonatomic, strong) NSData *pendingVideo;
@property (nonatomic) VTPixelRotationSessionRef rotationSession;
@property (nonatomic) CVPixelBufferPoolRef rotationPool;
@property (nonatomic) size_t rotationWidth;
@property (nonatomic) size_t rotationHeight;
@property (nonatomic) OSType rotationFormat;
@property (nonatomic) CGImagePropertyOrientation frameOrientation;
// Last sample whose status proves capture is alive (Complete/Started/Idle). Suspended and Blank samples
// are recorded separately so a dead capture is not mistaken for a static screen.
@property (nonatomic) CFTimeInterval lastCapturedFrame;
@property (nonatomic) CFTimeInterval lastUnavailableFrame;
@property (nonatomic) CFTimeInterval lastVideoSent;
// When the last keyframe was handed to the connection. The low-latency hardware encoder may produce an
// infinite GOP, so periodic IDR frames are forced explicitly (see encodeHeldImageAt:).
@property (nonatomic) CFTimeInterval lastKeyframeSent;
@property (nonatomic) CFTimeInterval encoderRetryAfter;
@property (nonatomic) BOOL softwareEncoder;
@property (nonatomic) CFTimeInterval softwareEncoderSince;
// Consecutive encoder resets without a successfully encoded frame; drives the retry backoff.
@property (nonatomic) NSUInteger encoderFailures;
@property (nonatomic) BOOL videoStalled;
@property (nonatomic) CFTimeInterval lastStallRecovery;
@property (nonatomic) CFTimeInterval encodeStarted;
@property (nonatomic) NSUInteger encoderGeneration;
// Latest captured frame (retained). Kept after encoding so a frame skipped by the rate limiter is
// sent once the encoder frees up, and so a static screen is periodically re-sent as a keyframe.
@property (nonatomic) CVPixelBufferRef heldImage;
@property (nonatomic) CGImagePropertyOrientation heldOrientation;
@property (nonatomic) BOOL heldFresh;
@property (nonatomic) BOOL pumpScheduled;
@end

static const CFTimeInterval MirrorFrameInterval = 1.0 / 30.0;
static const CFTimeInterval MirrorStaticResendInterval = 1.0;
// A static screen is re-sent only while ScreenCaptureKit keeps reporting a live capture this recently;
// otherwise the stall warnings on both devices must be allowed to appear instead of a frozen frame.
static const CFTimeInterval MirrorCaptureLiveWindow = 2.0;
// The iPad drops every P frame after it loses one and has no way to ask for a keyframe, so a keyframe is
// forced at least this often even while the screen keeps changing.
static const CFTimeInterval MirrorKeyframeInterval = 1.0;
static const CFTimeInterval MirrorVideoStallTimeout = 5.0;
static const CFTimeInterval MirrorSoftwareEncoderRetryHardware = 30.0;
static const CFTimeInterval MirrorRotationRetryDelay = 0.25;
// Encoder retry delays for consecutive failures (the last one repeats). Indexed by the failure count, so
// a persistently failing encoder is not rebuilt several times a second.
static const CFTimeInterval MirrorEncoderRetryDelays[] = {0.25, 1.0, 2.0};
static const NSUInteger MirrorEncoderRetryDelayCount =
    sizeof(MirrorEncoderRetryDelays) / sizeof(MirrorEncoderRetryDelays[0]);
// Matches the iPad receiver's idle cutoff: a write or path stuck longer than this is a dead peer.
static const CFTimeInterval MirrorPeerTimeout = 8.0;

@implementation MirrorController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    NSNotificationCenter *notifications = NSNotificationCenter.defaultCenter;
    [notifications addObserver:self selector:@selector(captureApplicationStateChanged:)
        name:UIApplicationDidEnterBackgroundNotification object:nil];
    [notifications addObserver:self selector:@selector(captureApplicationStateChanged:)
        name:UIApplicationWillEnterForegroundNotification object:nil];
    UILabel *title = [UILabel new];
    title.font = [UIFont preferredFontForTextStyle:UIFontTextStyleLargeTitle];
    title.text = @"Showcase Mirror";
    UILabel *instructions = [UILabel new];
    instructions.numberOfLines = 0;
    instructions.text = @"iPad’de CarPlay içinden Araç’a dokun. Sonra buradan QR kodunu okut.";
    self.action = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.action setTitle:@"Yansıtmayı durdur" forState:UIControlStateNormal];
    [self.action addTarget:self action:@selector(stopSharing) forControlEvents:UIControlEventTouchUpInside];
    self.action.hidden = YES;
    self.scan = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.scan setTitle:@"QR kodunu okut" forState:UIControlStateNormal];
    [self.scan addTarget:self action:@selector(scanPairing) forControlEvents:UIControlEventTouchUpInside];
    self.status = [UILabel new];
    self.status.numberOfLines = 0;
    self.status.textColor = UIColor.secondaryLabelColor;
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:
        @[title, instructions, self.scan, self.action, self.status]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 16;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:stack];
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:safe.topAnchor constant:24],
        [stack.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:24],
        [stack.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-24]
    ]];
}

- (void)captureApplicationStateChanged:(NSNotification *)notification {
    if (!self.stream) return;
    // A suspended hardware session can keep returning errors after the app changes state.
    [self closeEncoder];
    // The pixel rotation session is a VideoToolbox session too; rebuild it with the encoder.
    [self closeRotation];
    self.encoding = NO;
    self.needsKeyframe = YES;
    self.softwareEncoder = NO;
    self.encoderFailures = 0;
    self.encoderRetryAfter = 0;
    self.nextFrameTime = 0;
    self.pendingVideo = nil;
    // Screen lock also lands here: re-send the held frame only while capture is still live.
    [self rearmHeldImage];
    NSLog(@"[Showcase Mirror] Capture app transition: %@", notification.name);
    [self pumpVideo];
}

- (void)recoverEncoderFromError:(OSStatus)error {
    NSLog(@"[Showcase Mirror] Encoder reset (%d, software=%d)", (int)error, self.softwareEncoder);
    CFTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    [self closeEncoder];
    self.encoding = NO;
    self.needsKeyframe = YES;
    // Back off across consecutive failures: openEncoderWidth may silently drop a software request back to
    // hardware, so the software/hardware flag alone cannot tell a first failure from a repeated one.
    CFTimeInterval delay = MirrorEncoderRetryDelays[MIN(self.encoderFailures, MirrorEncoderRetryDelayCount - 1)];
    if (self.softwareEncoder) delay = MAX(delay, 1.0);
    self.encoderFailures++;
    self.encoderRetryAfter = now + delay;
    // Alternate instead of latching software: if the software encoder also fails, go back to hardware.
    self.softwareEncoder = !self.softwareEncoder;
    if (self.softwareEncoder) self.softwareEncoderSince = now;
    // The frame that was being encoded is lost; re-encode the held one once the retry delay passes.
    [self rearmHeldImage];
    [self pumpVideo];
}

// Marks the held frame for (re-)encoding only while ScreenCaptureKit still reports a live capture;
// the last frame of a suspended or blank capture must surface as a stall, never as a live frame.
- (void)rearmHeldImage {
    CFTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    self.heldFresh = self.heldImage != NULL && now - self.lastCapturedFrame < MirrorCaptureLiveWindow;
}

- (void)setHeldImage:(CVPixelBufferRef)image {
    if (image == _heldImage) return;
    if (image) CVPixelBufferRetain(image);
    if (_heldImage) CVPixelBufferRelease(_heldImage);
    _heldImage = image;
}

- (void)scanPairing {
    if (self.peer || self.presentedViewController) return;
    MirrorScanner *scanner = [MirrorScanner new];
    scanner.modalPresentationStyle = UIModalPresentationFullScreen;
    __weak typeof(self) weakSelf = self;
    scanner.onPair = ^(NSURL *url) { [weakSelf pairUsingURL:url]; };
    [self presentViewController:scanner animated:YES completion:nil];
}

- (void)stopSharing {
    [self stop:@"Yansıtma durduruldu."];
}

- (void)pairUsingURL:(NSURL *)url {
    [self loadViewIfNeeded];
    NSString *host, *port;
    NSData *key;
    if (!mirror_read_pairing_url(url, &host, &port, &key)) {
        if (!self.peer) self.status.text = @"Bu QR kodu geçersiz. iPad’deki Showcase kodunu tekrar okut.";
        return;
    }
    if (self.peer) return;
    SCContentSharingPicker *picker = SCContentSharingPicker.sharedPicker;
    if (!picker.available) {
        self.status.text = @"Bu cihazda ekran paylaşımı kullanılamıyor.";
        return;
    }
    self.status.text = @"iPad’e bağlanılıyor…";
    self.action.hidden = NO;
    self.scan.hidden = YES;
    nw_endpoint_t endpoint = nw_endpoint_create_host(host.UTF8String, port.UTF8String);
    nw_connection_t peer = nw_connection_create(endpoint, mirror_parameters(key));
    self.peer = peer;
    __weak typeof(self) weakSelf = self;
    nw_connection_set_queue(peer, dispatch_get_main_queue());
    nw_connection_set_state_changed_handler(peer, ^(nw_connection_state_t state, nw_error_t error) {
        MirrorController *controller = weakSelf;
        if (controller.peer != peer) return;
        if (state == nw_connection_state_ready) {
            [controller connected:peer];
        } else if (state == nw_connection_state_failed || state == nw_connection_state_cancelled) {
            [controller stop:@"Bağlantı kapandı. Wi-Fi’yi kontrol edip QR kodunu tekrar okut."];
        }
    });
    nw_connection_set_viability_changed_handler(peer, ^(bool viable) {
        MirrorController *controller = weakSelf;
        if (controller.peer != peer) return;
        controller.nonViableSince = viable ? 0 : NSProcessInfo.processInfo.systemUptime;
    });
    nw_connection_start(peer);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 12 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        MirrorController *controller = weakSelf;
        if (controller.peer == peer && !controller.timer)
            [controller stop:@"Bağlantı kurulamadı. Wi-Fi’yi ve yerel ağ iznini kontrol et."];
    });
}

- (void)connected:(nw_connection_t)peer {
    __weak typeof(self) weakSelf = self;
    nw_connection_receive(peer, 1, 1, ^(dispatch_data_t content, nw_content_context_t context,
                                        bool complete, nw_error_t error) {
        MirrorController *controller = weakSelf;
        if (controller.peer == peer) [controller stop:@"iPad yansıtmayı kapattı."];
    });
    self.lastSend = NSProcessInfo.processInfo.systemUptime;
    self.timer = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *timer) {
        MirrorController *controller = weakSelf;
        if (!controller) return;
        CFTimeInterval now = NSProcessInfo.processInfo.systemUptime;
        // A peer that vanished without RST/FIN never completes the write (or keeps the path
        // non-viable) until the TCP retransmission timeout, minutes later; end the session instead.
        if ((controller.sending && now - controller.sendStarted > MirrorPeerTimeout) ||
            (controller.nonViableSince && now - controller.nonViableSince > MirrorPeerTimeout)) {
            NSLog(@"[Showcase Mirror] Peer unresponsive (write pending=%d for %.1fs, non-viable for %.1fs)",
                  controller.sending, controller.sending ? now - controller.sendStarted : 0.0,
                  controller.nonViableSince ? now - controller.nonViableSince : 0.0);
            [controller stop:@"Yansıtma bağlantısı kesildi. Wi-Fi’yi kontrol edip QR kodunu tekrar okut."];
            return;
        }
        if (controller.encoding && now - controller.encodeStarted > 1.0) {
            [controller recoverEncoderFromError:kVTVideoEncoderNotAvailableNowErr];
        }
        if (controller.stream && controller.softwareEncoder && !controller.encoding &&
            now - controller.softwareEncoderSince > MirrorSoftwareEncoderRetryHardware &&
            UIApplication.sharedApplication.applicationState == UIApplicationStateActive) {
            // Software was a fallback for a transient hardware failure; try hardware again.
            [controller closeEncoder];
            controller.softwareEncoder = NO;
            controller.needsKeyframe = YES;
            [controller rearmHeldImage];
        }
        if (controller.stream && now - controller.lastVideoSent > MirrorVideoStallTimeout &&
            now - controller.lastStallRecovery > MirrorVideoStallTimeout) {
            BOOL receiving = now - controller.lastCapturedFrame < MirrorCaptureLiveWindow;
            NSLog(@"[Showcase Mirror] Video stalled (capture age %.1fs, suspended/blank age %.1fs, "
                  "write pending=%d, software=%d)",
                  now - controller.lastCapturedFrame,
                  controller.lastUnavailableFrame ? now - controller.lastUnavailableFrame : -1.0,
                  controller.sending, controller.softwareEncoder);
            if (!controller.videoStalled) {
                controller.videoStalled = YES;
                controller.status.text = receiving
                    ? @"Ekran yakalanıyor. Görüntü aktarımı yeniden başlatılıyor…"
                    : @"iOS’tan yeni ekran karesi bekleniyor…";
            }
            // Actually restart the video path from a fresh hardware session and a keyframe.
            controller.lastStallRecovery = now;
            [controller closeEncoder];
            [controller closeRotation];
            controller.encoding = NO;
            controller.needsKeyframe = YES;
            controller.softwareEncoder = NO;
            controller.encoderRetryAfter = 0;
            controller.nextFrameTime = 0;
            // Re-encoding a held frame from a dead capture would only refresh the iPad with a frozen image.
            [controller rearmHeldImage];
        }
        if (controller.heldImage && !controller.heldFresh && !controller.encoding && !controller.pendingVideo &&
            now - controller.lastVideoSent > MirrorStaticResendInterval &&
            now - controller.lastCapturedFrame < MirrorCaptureLiveWindow) {
            // Static screen: ScreenCaptureKit sends no new image, so re-send the last one as a keyframe
            // to keep the receiver fresh and let it recover from a lost frame. Only while capture is
            // still alive: a suspended or blank capture must surface as a stall, not as a live frame.
            controller.needsKeyframe = YES;
            controller.heldFresh = YES;
        }
        [controller pumpVideo];
        if (!controller.sending && !controller.encoding && now - controller.lastSend > 2.0) {
            uint32_t zero = 0;
            [controller send:[NSData dataWithBytes:&zero length:sizeof(zero)]];
        }
    }];
    self.awaitingPicker = YES;
    SCContentSharingPicker *picker = SCContentSharingPicker.sharedPicker;
    SCContentSharingPickerConfiguration *configuration = [SCContentSharingPickerConfiguration new];
    configuration.showsMicrophoneControl = NO;
    picker.defaultConfiguration = configuration;
    [picker addObserver:self];
    picker.active = YES;
    self.status.text = @"Sistem ekranında tam ekran paylaşımını onayla.";
    [picker present];
}

- (void)stop:(NSString *)status {
    [self.timer invalidate];
    self.timer = nil;
    if (self.peer) {
        nw_connection_set_state_changed_handler(self.peer, nil);
        nw_connection_set_viability_changed_handler(self.peer, nil);
        nw_connection_cancel(self.peer);
        self.peer = nil;
    }
    self.awaitingPicker = NO;
    SCContentSharingPicker *picker = SCContentSharingPicker.sharedPicker;
    [picker removeObserver:self];
    picker.active = NO;
    SCStream *stream = self.stream;
    self.stream = nil;
    [stream stopCaptureWithCompletionHandler:^(NSError *error) {}];
    [self closeEncoder];
    self.encoding = NO;
    self.sending = NO;
    self.nonViableSince = 0;
    self.softwareEncoder = NO;
    self.encoderFailures = 0;
    self.videoStalled = NO;
    self.lastStallRecovery = 0;
    self.encoderRetryAfter = 0;
    self.nextFrameTime = 0;
    self.pendingVideo = nil;
    self.heldImage = NULL;
    self.heldFresh = NO;
    self.frameOrientation = kCGImagePropertyOrientationUp;
    [self closeRotation];
    self.action.hidden = YES;
    self.scan.hidden = NO;
    self.status.text = status;
}

- (void)contentSharingPicker:(SCContentSharingPicker *)picker didCancelForStream:(SCStream *)stream {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.awaitingPicker) [self stop:@"Ekran paylaşımı iptal edildi."];
    });
}

- (void)contentSharingPickerStartDidFailWithError:(NSError *)error {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.awaitingPicker) [self stop:error.localizedDescription];
    });
}

- (void)contentSharingPicker:(SCContentSharingPicker *)picker
         didUpdateWithFilter:(SCContentFilter *)filter forStream:(SCStream *)oldStream {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self.peer || !self.awaitingPicker) return;
        self.awaitingPicker = NO;
        NSLog(@"[Showcase Mirror] Capture filter style: %ld", (long)filter.style);
        if (filter.style != SCShareableContentStyleDisplay) {
            [self stop:@"Diğer uygulamaları yansıtmak için tam ekran paylaşımını seç."];
            return;
        }
        CGSize size = filter.contentRect.size;
        if (size.width <= 0 || size.height <= 0) size = self.view.bounds.size;
        double scale = 960.0 / MAX(size.width, size.height);
        SCStreamConfiguration *config = [SCStreamConfiguration new];
        config.width = MAX(2, ((NSInteger)(size.width * scale)) & ~1);
        config.height = MAX(2, ((NSInteger)(size.height * scale)) & ~1);
        SCStream *stream = [[SCStream alloc] initWithFilter:filter configuration:config delegate:self];
        self.stream = stream;
        self.lastVideoSent = NSProcessInfo.processInfo.systemUptime;
        self.lastCapturedFrame = self.lastVideoSent;
        self.lastUnavailableFrame = 0;
        NSError *error;
        if (![stream addStreamOutput:self type:SCStreamOutputTypeScreen
                 sampleHandlerQueue:dispatch_get_main_queue() error:&error]) {
            [self stop:error.localizedDescription];
            return;
        }
        [stream startCaptureWithCompletionHandler:^(NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (self.stream != stream) return;
                if (error) [self stop:error.localizedDescription];
                else self.status.text = @"Ekran iPad’e yansıtılıyor. Ana ekrana veya başka bir uygulamaya geçebilirsin.";
            });
        }];
    });
}

- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.stream == stream) {
            NSLog(@"[Showcase Mirror] Capture ended (%@:%ld, app state=%ld)",
                  error.domain, (long)error.code, (long)UIApplication.sharedApplication.applicationState);
            [self stop:error.localizedDescription ?: @"iOS ekran paylaşımını bitirdi."];
        }
    });
}

- (void)closeEncoder {
    self.encoderGeneration++;
    if (!self.encoder) return;
    VTCompressionSessionInvalidate(self.encoder);
    CFRelease(self.encoder);
    self.encoder = NULL;
}

- (void)closeRotation {
    if (self.rotationPool) {
        CVPixelBufferPoolRelease(self.rotationPool);
        self.rotationPool = NULL;
    }
    if (self.rotationSession) {
        VTPixelRotationSessionInvalidate(self.rotationSession);
        CFRelease(self.rotationSession);
        self.rotationSession = NULL;
    }
}

- (BOOL)openEncoderWidth:(int)width height:(int)height {
    [self closeEncoder];
    VTCompressionSessionRef encoder = NULL;
    NSDictionary *specification = self.softwareEncoder ? @{
        (__bridge NSString *)kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: @NO
    } : @{
        (__bridge NSString *)kVTVideoEncoderSpecification_EnableLowLatencyRateControl: @YES
    };
    OSStatus status = VTCompressionSessionCreate(NULL, width, height, kCMVideoCodecType_H264,
        (__bridge CFDictionaryRef)specification, NULL, NULL, NULL, NULL, &encoder);
    if (status) {
        // Let VideoToolbox pick any encoder (hardware included) when the requested one is unavailable.
        encoder = NULL;
        status = VTCompressionSessionCreate(NULL, width, height, kCMVideoCodecType_H264,
            NULL, NULL, NULL, NULL, NULL, &encoder);
        if (!status && self.softwareEncoder) {
            NSLog(@"[Showcase Mirror] Software encoder unavailable; using default encoder");
            self.softwareEncoder = NO;
        }
    }
    if (status) return NO;
    self.encoder = encoder;
    self.frameWidth = width;
    self.frameHeight = height;
    self.needsKeyframe = YES;
    VTSessionSetProperty(encoder, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);
    VTSessionSetProperty(encoder, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse);
    VTSessionSetProperty(encoder, kVTCompressionPropertyKey_MaxFrameDelayCount, (__bridge CFNumberRef)@0);
    VTSessionSetProperty(encoder, kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_Baseline_AutoLevel);
    VTSessionSetProperty(encoder, kVTCompressionPropertyKey_AverageBitRate, (__bridge CFNumberRef)@1400000);
    VTSessionSetProperty(encoder, kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, (__bridge CFNumberRef)@1);
    VTSessionSetProperty(encoder, kVTCompressionPropertyKey_ExpectedFrameRate, (__bridge CFNumberRef)@30);
    VTSessionSetProperty(encoder, kVTCompressionPropertyKey_MaxKeyFrameInterval, (__bridge CFNumberRef)@30);
    return VTCompressionSessionPrepareToEncodeFrames(encoder) == noErr;
}

static NSNumber *mirrorFrameInfo(CMSampleBufferRef sample, SCStreamFrameInfo key) {
    NSArray *attachments = (__bridge NSArray *)CMSampleBufferGetSampleAttachmentsArray(sample, false);
    NSNumber *value = attachments.firstObject[key];
    if (!value) value = (__bridge NSNumber *)CMGetAttachment(sample, (__bridge CFStringRef)key, NULL);
    return [value isKindOfClass:NSNumber.class] ? value : nil;
}

static CGImagePropertyOrientation mirrorFrameOrientation(CMSampleBufferRef sample) {
    NSInteger orientation = mirrorFrameInfo(sample, SCStreamFrameInfoVideoOrientation).integerValue;
    return orientation >= 1 && orientation <= 8 ? (CGImagePropertyOrientation)orientation
                                                : kCGImagePropertyOrientationUp;
}

- (CVPixelBufferRef)copyOrientedImage:(CVPixelBufferRef)image
                          orientation:(CGImagePropertyOrientation)orientation CF_RETURNS_RETAINED {
    if (orientation == kCGImagePropertyOrientationUp) return CVPixelBufferRetain(image);

    CFStringRef rotation = kVTRotation_0;
    BOOL flip = NO;
    switch (orientation) {
        case kCGImagePropertyOrientationUpMirrored: flip = YES; break;
        case kCGImagePropertyOrientationDown: rotation = kVTRotation_180; break;
        case kCGImagePropertyOrientationDownMirrored: rotation = kVTRotation_180; flip = YES; break;
        case kCGImagePropertyOrientationLeftMirrored: rotation = kVTRotation_CW90; flip = YES; break;
        case kCGImagePropertyOrientationRight: rotation = kVTRotation_CW90; break;
        case kCGImagePropertyOrientationRightMirrored: rotation = kVTRotation_CCW90; flip = YES; break;
        case kCGImagePropertyOrientationLeft: rotation = kVTRotation_CCW90; break;
        default: return CVPixelBufferRetain(image);
    }
    BOOL swap = orientation >= kCGImagePropertyOrientationLeftMirrored;
    size_t width = swap ? CVPixelBufferGetHeight(image) : CVPixelBufferGetWidth(image);
    size_t height = swap ? CVPixelBufferGetWidth(image) : CVPixelBufferGetHeight(image);
    OSType format = CVPixelBufferGetPixelFormatType(image);
    OSStatus status = noErr;
    if (!self.rotationSession && (status = VTPixelRotationSessionCreate(NULL, &_rotationSession)) != noErr) {
        NSLog(@"[Showcase Mirror] Rotation session create failed (%d)", (int)status);
        return NULL;
    }
    if (!self.rotationPool || self.rotationWidth != width || self.rotationHeight != height ||
        self.rotationFormat != format) {
        if (self.rotationPool) CVPixelBufferPoolRelease(self.rotationPool);
        self.rotationPool = NULL;
        NSDictionary *attributes = @{
            (__bridge NSString *)kCVPixelBufferWidthKey: @(width),
            (__bridge NSString *)kCVPixelBufferHeightKey: @(height),
            (__bridge NSString *)kCVPixelBufferPixelFormatTypeKey: @(format),
            (__bridge NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{}
        };
        CVReturn poolStatus = CVPixelBufferPoolCreate(NULL, NULL, (__bridge CFDictionaryRef)attributes, &_rotationPool);
        if (poolStatus != kCVReturnSuccess) {
            NSLog(@"[Showcase Mirror] Rotation pool create failed (%d, %zux%zu)", (int)poolStatus, width, height);
            return NULL;
        }
        self.rotationWidth = width;
        self.rotationHeight = height;
        self.rotationFormat = format;
    }
    if ((status = VTSessionSetProperty(self.rotationSession, kVTPixelRotationPropertyKey_Rotation, rotation)) != noErr ||
        (status = VTSessionSetProperty(self.rotationSession, kVTPixelRotationPropertyKey_FlipHorizontalOrientation,
                                       flip ? kCFBooleanTrue : kCFBooleanFalse)) != noErr) {
        NSLog(@"[Showcase Mirror] Rotation configure failed (%d)", (int)status);
        return NULL;
    }

    CVPixelBufferRef output = NULL;
    CVReturn bufferStatus = CVPixelBufferPoolCreatePixelBuffer(NULL, self.rotationPool, &output);
    if (bufferStatus != kCVReturnSuccess) {
        NSLog(@"[Showcase Mirror] Rotation buffer allocation failed (%d)", (int)bufferStatus);
        return NULL;
    }
    if ((status = VTPixelRotationSessionRotateImage(self.rotationSession, image, output)) != noErr) {
        NSLog(@"[Showcase Mirror] Rotation failed (%d, orientation=%d)", (int)status, (int)orientation);
        CVPixelBufferRelease(output);
        return NULL;
    }
    return output;
}

- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sample
        ofType:(SCStreamOutputType)type {
    if (type != SCStreamOutputTypeScreen || stream != self.stream || !self.peer) return;
    CFTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    NSNumber *statusValue = mirrorFrameInfo(sample, SCStreamFrameInfoStatus);
    SCFrameStatus status = statusValue ? (SCFrameStatus)statusValue.integerValue : SCFrameStatusComplete;
    if (status != SCFrameStatusComplete && status != SCFrameStatusStarted && status != SCFrameStatusIdle) {
        // Suspended (screen locked, capture paused) or Blank: not proof of a live capture, and any
        // image it carries is not real screen content.
        self.lastUnavailableFrame = now;
        return;
    }
    // Idle samples carry no image but still prove that capture is alive.
    self.lastCapturedFrame = now;
    if (status == SCFrameStatusIdle) return;
    CVImageBufferRef image = CMSampleBufferGetImageBuffer(sample);
    if (!image || !CMSampleBufferDataIsReady(sample)) return;
    // Keep the newest frame instead of dropping it when the encoder or rate limiter is busy,
    // so the last frame of a motion is always delivered.
    self.heldImage = image;
    self.heldOrientation = mirrorFrameOrientation(sample);
    self.heldFresh = YES;
    [self pumpVideo];
}

- (void)pumpVideo {
    if (!self.stream || !self.peer || !self.heldImage || !self.heldFresh) return;
    // Encoder and send completions call back here once they finish.
    if (self.encoding || self.pendingVideo) return;
    CFTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    CFTimeInterval readyAt = MAX(self.encoderRetryAfter, self.nextFrameTime - 0.002);
    if (now < readyAt) {
        if (self.pumpScheduled) return;
        self.pumpScheduled = YES;
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((readyAt - now) * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            MirrorController *controller = weakSelf;
            controller.pumpScheduled = NO;
            [controller pumpVideo];
        });
        return;
    }
    [self encodeHeldImageAt:now];
}

- (void)encodeHeldImageAt:(CFTimeInterval)now {
    SCStream *stream = self.stream;
    if (!self.nextFrameTime || now - self.nextFrameTime > MirrorFrameInterval) self.nextFrameTime = now;
    self.nextFrameTime += MirrorFrameInterval;

    CGImagePropertyOrientation orientation = self.heldOrientation;
    CVPixelBufferRef oriented = [self copyOrientedImage:self.heldImage orientation:orientation];
    self.heldFresh = NO;
    if (!oriented) {
        // Rebuild the rotation session/pool (it can stay broken after an app transition, like the
        // encoder) and retry the held frame after a short delay instead of silently dropping it.
        [self closeRotation];
        self.needsKeyframe = YES;
        self.encoderRetryAfter = now + MirrorRotationRetryDelay;
        [self rearmHeldImage];
        [self pumpVideo];
        return;
    }
    if (orientation != self.frameOrientation) self.needsKeyframe = YES;
    self.frameOrientation = orientation;
    int width = (int)CVPixelBufferGetWidth(oriented), height = (int)CVPixelBufferGetHeight(oriented);
    if ((!self.encoder || width != self.frameWidth || height != self.frameHeight) &&
        ![self openEncoderWidth:width height:height]) {
        CVPixelBufferRelease(oriented);
        [self recoverEncoderFromError:kVTVideoEncoderNotAvailableNowErr];
        return;
    }
    BOOL forceKeyframe = self.needsKeyframe || now - self.lastKeyframeSent >= MirrorKeyframeInterval;
    NSDictionary *properties = forceKeyframe ? @{(__bridge NSString *)kVTEncodeFrameOptionKey_ForceKeyFrame: @YES} : nil;
    self.encoding = YES;
    self.encodeStarted = now;
    NSUInteger generation = self.encoderGeneration;
    __weak typeof(self) weakSelf = self;
    OSStatus result = VTCompressionSessionEncodeFrameWithOutputHandler(self.encoder, oriented,
        CMTimeMakeWithSeconds(now, 1000000), CMTimeMake(1, 30), (__bridge CFDictionaryRef)properties,
        NULL, ^(OSStatus error, VTEncodeInfoFlags flags, CMSampleBufferRef output) {
            if (output) CFRetain(output);
            dispatch_async(dispatch_get_main_queue(), ^{
                MirrorController *controller = weakSelf;
                if (controller && controller.stream == stream && controller.encoderGeneration == generation) {
                    controller.encoding = NO;
                    if (error) {
                        [controller recoverEncoderFromError:error];
                    } else {
                        if (output) controller.encoderFailures = 0;
                        if (output) [controller sendFrame:output];
                        else controller.needsKeyframe = YES;
                        // A dropped or unsendable frame is re-encoded from the held image as a keyframe.
                        if (controller.needsKeyframe) [controller rearmHeldImage];
                        [controller pumpVideo];
                    }
                }
                if (output) CFRelease(output);
            });
        });
    CVPixelBufferRelease(oriented);
    if (result) [self recoverEncoderFromError:result];
}

- (void)sendFrame:(CMSampleBufferRef)sample {
    CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sample, false);
    CFDictionaryRef attachment = attachments && CFArrayGetCount(attachments)
        ? CFArrayGetValueAtIndex(attachments, 0) : NULL;
    BOOL keyframe = !attachment || !CFDictionaryContainsKey(attachment, kCMSampleAttachmentKey_NotSync);
    if (!keyframe && self.needsKeyframe) return;
    const uint8_t *sets[2] = {0};
    size_t sizes[2] = {0};
    CMFormatDescriptionRef format = CMSampleBufferGetFormatDescription(sample);
    if (keyframe) {
        for (size_t i = 0; i < 2; i++) {
            int nalHeader = 0;
            if (CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, i, &sets[i], &sizes[i], NULL, &nalHeader) ||
                nalHeader != 4 || sizes[i] > UINT16_MAX) {
                self.needsKeyframe = YES;
                return;
            }
        }
    }
    CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sample);
    size_t size = block ? CMBlockBufferGetDataLength(block) : 0;
    size_t payload = 4 + sizes[0] + sizes[1] + size;
    if (!size || payload > MirrorMaxFrame) {
        self.needsKeyframe = YES;
        return;
    }
    uint32_t length = htonl((uint32_t)payload);
    uint16_t setLengths[] = { htons((uint16_t)sizes[0]), htons((uint16_t)sizes[1]) };
    NSMutableData *packet = [NSMutableData dataWithCapacity:sizeof(length) + payload];
    [packet appendBytes:&length length:sizeof(length)];
    [packet appendBytes:setLengths length:sizeof(setLengths)];
    if (keyframe) {
        [packet appendBytes:sets[0] length:sizes[0]];
        [packet appendBytes:sets[1] length:sizes[1]];
    }
    size_t offset = packet.length;
    [packet increaseLengthBy:size];
    if (CMBlockBufferCopyDataBytes(block, 0, size, (uint8_t *)packet.mutableBytes + offset)) {
        self.needsKeyframe = YES;
        return;
    }
    self.needsKeyframe = NO;
    if (keyframe) self.lastKeyframeSent = NSProcessInfo.processInfo.systemUptime;
    if (self.sending) self.pendingVideo = packet;
    else [self send:packet];
}

- (void)send:(NSData *)packet {
    nw_connection_t peer = self.peer;
    if (!peer) return;
    BOOL video = packet.length > sizeof(uint32_t);
    self.sending = YES;
    self.lastSend = NSProcessInfo.processInfo.systemUptime;
    self.sendStarted = self.lastSend;
    dispatch_data_t data = dispatch_data_create(packet.bytes, packet.length, NULL,
                                                DISPATCH_DATA_DESTRUCTOR_DEFAULT);
    __weak typeof(self) weakSelf = self;
    nw_connection_send(peer, data, NW_CONNECTION_DEFAULT_MESSAGE_CONTEXT, true, ^(nw_error_t error) {
        MirrorController *controller = weakSelf;
        if (controller.peer != peer) return;
        controller.sending = NO;
        if (error) {
            [controller stop:@"Yansıtma bağlantısı kesildi."];
            return;
        }
        if (video) {
            controller.lastVideoSent = NSProcessInfo.processInfo.systemUptime;
            if (controller.videoStalled) {
                controller.videoStalled = NO;
                controller.status.text = @"Ekran iPad’e yansıtılıyor.";
            }
        }
        NSData *pending = controller.pendingVideo;
        controller.pendingVideo = nil;
        if (pending) [controller send:pending];
        [controller pumpVideo];
    });
}

@end

@interface MirrorScene : UIResponder <UIWindowSceneDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation MirrorScene
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session
      options:(UISceneConnectionOptions *)options {
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    self.window.rootViewController = [MirrorController new];
    [self.window makeKeyAndVisible];
}
@end

@interface MirrorApp : UIResponder <UIApplicationDelegate>
@end
@implementation MirrorApp
@end

int main(int argc, char **argv) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(MirrorApp.class));
    }
}
