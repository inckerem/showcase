#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <VideoToolbox/VideoToolbox.h>
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
@property (nonatomic) CFTimeInterval lastFrame;
@end

@implementation MirrorController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
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
        if (controller && NSProcessInfo.processInfo.systemUptime - controller.lastSend > 2.0 &&
            !controller.sending) {
            uint32_t zero = 0;
            [controller send:[NSData dataWithBytes:&zero length:sizeof(zero)]];
        }
    }];
    self.awaitingPicker = YES;
    SCContentSharingPicker *picker = SCContentSharingPicker.sharedPicker;
    [picker addObserver:self];
    picker.active = YES;
    self.status.text = @"Sistem ekranında paylaşımı onayla.";
    [picker presentPickerUsingContentStyle:SCShareableContentStyleDisplay];
}

- (void)stop:(NSString *)status {
    [self.timer invalidate];
    self.timer = nil;
    if (self.peer) {
        nw_connection_set_state_changed_handler(self.peer, nil);
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
        CGSize size = filter.contentRect.size;
        if (size.width <= 0 || size.height <= 0) size = self.view.bounds.size;
        double scale = 960.0 / MAX(size.width, size.height);
        SCStreamConfiguration *config = [SCStreamConfiguration new];
        config.width = MAX(2, ((NSInteger)(size.width * scale)) & ~1);
        config.height = MAX(2, ((NSInteger)(size.height * scale)) & ~1);
        SCStream *stream = [[SCStream alloc] initWithFilter:filter configuration:config delegate:self];
        self.stream = stream;
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
                else self.status.text = @"Ekran iPad’e yansıtılıyor.";
            });
        }];
    });
}

- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.stream == stream) [self stop:error.localizedDescription];
    });
}

- (void)closeEncoder {
    if (!self.encoder) return;
    VTCompressionSessionInvalidate(self.encoder);
    CFRelease(self.encoder);
    self.encoder = NULL;
}

- (BOOL)openEncoderWidth:(int)width height:(int)height {
    [self closeEncoder];
    VTCompressionSessionRef encoder = NULL;
    if (VTCompressionSessionCreate(NULL, width, height, kCMVideoCodecType_H264,
                                    NULL, NULL, NULL, NULL, NULL, &encoder)) return NO;
    self.encoder = encoder;
    self.frameWidth = width;
    self.frameHeight = height;
    self.needsKeyframe = YES;
    VTSessionSetProperty(encoder, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);
    VTSessionSetProperty(encoder, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse);
    VTSessionSetProperty(encoder, kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_Baseline_AutoLevel);
    VTSessionSetProperty(encoder, kVTCompressionPropertyKey_AverageBitRate, (__bridge CFNumberRef)@1400000);
    VTSessionSetProperty(encoder, kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, (__bridge CFNumberRef)@1);
    return VTCompressionSessionPrepareToEncodeFrames(encoder) == noErr;
}

- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sample
        ofType:(SCStreamOutputType)type {
    if (stream != self.stream || !self.peer || self.encoding || self.sending) return;
    CFTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    if (now - self.lastFrame < 1.0 / 20.0) return;
    self.lastFrame = now;
    CVImageBufferRef image = CMSampleBufferGetImageBuffer(sample);
    if (!image || !CMSampleBufferDataIsReady(sample)) return;
    int width = (int)CVPixelBufferGetWidth(image), height = (int)CVPixelBufferGetHeight(image);
    if ((!self.encoder || width != self.frameWidth || height != self.frameHeight) &&
        ![self openEncoderWidth:width height:height]) {
        [self stop:@"H.264 kodlayıcı başlatılamadı."];
        return;
    }
    NSDictionary *properties = self.needsKeyframe ? @{(__bridge NSString *)kVTEncodeFrameOptionKey_ForceKeyFrame: @YES} : nil;
    self.encoding = YES;
    __weak typeof(self) weakSelf = self;
    OSStatus result = VTCompressionSessionEncodeFrameWithOutputHandler(self.encoder, image,
        CMSampleBufferGetPresentationTimeStamp(sample), kCMTimeInvalid, (__bridge CFDictionaryRef)properties,
        NULL, ^(OSStatus error, VTEncodeInfoFlags flags, CMSampleBufferRef output) {
            if (output) CFRetain(output);
            dispatch_async(dispatch_get_main_queue(), ^{
                MirrorController *controller = weakSelf;
                if (controller.stream == stream) {
                    controller.encoding = NO;
                    if (!error && output && !controller.sending) [controller sendFrame:output];
                    else controller.needsKeyframe = YES;
                }
                if (output) CFRelease(output);
            });
        });
    if (result) {
        self.encoding = NO;
        self.needsKeyframe = YES;
    }
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
    [self send:packet];
}

- (void)send:(NSData *)packet {
    nw_connection_t peer = self.peer;
    if (!peer) return;
    self.sending = YES;
    self.lastSend = NSProcessInfo.processInfo.systemUptime;
    dispatch_data_t data = dispatch_data_create(packet.bytes, packet.length, NULL,
                                                DISPATCH_DATA_DESTRUCTOR_DEFAULT);
    __weak typeof(self) weakSelf = self;
    nw_connection_send(peer, data, NW_CONNECTION_DEFAULT_MESSAGE_CONTEXT, true, ^(nw_error_t error) {
        MirrorController *controller = weakSelf;
        if (controller.peer != peer) return;
        controller.sending = NO;
        if (error) [controller stop:@"Yansıtma bağlantısı kesildi."];
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
