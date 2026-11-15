// Photos (slideshow), videos (built-in AVFoundation player, VLC for other formats) and their menus.

#import "FR.h"
#import <QuartzCore/QuartzCore.h>
#import <AVFoundation/AVFoundation.h>
#import <ApplicationServices/ApplicationServices.h>

@interface FRBlackView : NSView
@end
@implementation FRBlackView
- (void)drawRect:(NSRect)dirty {
    [[NSColor blackColor] set];
    NSRectFill(dirty);
}
@end

#pragma mark - Image loading (ImageIO, scaled to the screen)

// Decodes the image directly at screen size (much faster and lighter than loading a 20 MP photo).
// Small images and unsupported files fall back to a plain NSImage.
static NSImage *FRLoadScaled(NSString *path, CGFloat maxPx) {
    NSImage *result = nil;
    CGImageSourceRef src = CGImageSourceCreateWithURL((CFURLRef)[NSURL fileURLWithPath:path], NULL);
    if (src) {
        double w = 0, h = 0;
        CFDictionaryRef props = CGImageSourceCopyPropertiesAtIndex(src, 0, NULL);
        if (props) {
            CFNumberRef nw = (CFNumberRef)CFDictionaryGetValue(props, kCGImagePropertyPixelWidth);
            CFNumberRef nh = (CFNumberRef)CFDictionaryGetValue(props, kCGImagePropertyPixelHeight);
            if (nw) CFNumberGetValue(nw, kCFNumberDoubleType, &w);
            if (nh) CFNumberGetValue(nh, kCFNumberDoubleType, &h);
            CFRelease(props);
        }
        if (MAX(w, h) > maxPx) {
            NSDictionary *opts = [NSDictionary dictionaryWithObjectsAndKeys:
                (id)kCFBooleanTrue, (id)kCGImageSourceCreateThumbnailFromImageAlways,
                (id)kCFBooleanTrue, (id)kCGImageSourceCreateThumbnailWithTransform,   // applies EXIF orientation
                [NSNumber numberWithDouble:maxPx], (id)kCGImageSourceThumbnailMaxPixelSize, nil];
            CGImageRef cg = CGImageSourceCreateThumbnailAtIndex(src, 0, (CFDictionaryRef)opts);
            if (cg) {
                result = [[[NSImage alloc] initWithCGImage:cg size:NSZeroSize] autorelease];
                CGImageRelease(cg);
            }
        }
        CFRelease(src);
    }
    if (!result) result = [[[NSImage alloc] initWithContentsOfFile:path] autorelease];
    return result;
}

#pragma mark - Slideshow

@implementation FRSlideshowScreen {
    NSString *_folder;
    FRBlackView *_view;
    NSImageView *_imageView;
    NSTextField *_hud;
    NSArray *_files;              // nil until the folder scan (background thread) is finished
    NSInteger _index;
    BOOL _playing;
    BOOL _active;
    NSTimer *_timer;
    NSMutableDictionary *_cache;  // decoded images around the current one
    NSMutableSet *_loading;
    CGFloat _maxPx;
}

- (id)initWithFolder:(NSString *)folder {
    self = [super init];
    if (self) {
        _folder = [folder copy];
        _playing = YES;
        _cache = [[NSMutableDictionary alloc] init];
        _loading = [[NSMutableSet alloc] init];
        NSScreen *scr = [NSScreen mainScreen];
        CGFloat scale = [scr respondsToSelector:@selector(backingScaleFactor)] ? [scr backingScaleFactor] : 1.0;
        _maxPx = MAX([scr frame].size.width, [scr frame].size.height) * scale;

        _view = [[FRBlackView alloc] initWithFrame:NSMakeRect(0, 0, 100, 100)];
        _imageView = [[NSImageView alloc] initWithFrame:[_view bounds]];
        [_imageView setImageScaling:NSImageScaleProportionallyUpOrDown];
        [_imageView setImageFrameStyle:NSImageFrameNone];
        [_imageView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
        [_imageView setWantsLayer:YES];
        [_view addSubview:_imageView];

        _hud = [FRMakeLabel(30) retain];
        [_hud setFrame:NSMakeRect(0, 30, 100, 46)];
        [_hud setAutoresizingMask:NSViewWidthSizable | NSViewMaxYMargin];
        [_hud setHidden:YES];
        [_view addSubview:_hud];
    }
    return self;
}

- (void)dealloc {
    [_timer invalidate];
    [NSObject cancelPreviousPerformRequestsWithTarget:self];
    [_folder release];
    [_files release];
    [_cache release];
    [_loading release];
    [_imageView release];
    [_hud release];
    [_view release];
    [super dealloc];
}

- (NSView *)view { return _view; }

// duration 0 = stays until hideHud
- (void)flash:(NSString *)text duration:(NSTimeInterval)duration {
    [_hud setStringValue:text];
    [_hud setHidden:NO];
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(hideHud) object:nil];
    if (duration > 0) [self performSelector:@selector(hideHud) withObject:nil afterDelay:duration];
}

- (void)hideHud { [_hud setHidden:YES]; }

- (void)prefetch:(NSInteger)i {
    NSNumber *key = [NSNumber numberWithInteger:i];
    if ([_cache objectForKey:key] || [_loading containsObject:key]) return;
    [_loading addObject:key];
    NSString *path = [_files objectAtIndex:(NSUInteger)i];
    CGFloat maxPx = _maxPx;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
        NSImage *img = nil;
        @autoreleasepool { img = [FRLoadScaled(path, maxPx) retain]; }
        dispatch_async(dispatch_get_main_queue(), ^{
            [_loading removeObject:key];
            if (img) [_cache setObject:img forKey:key];
            [img release];
        });
    });
}

- (void)trimCache {
    NSInteger count = (NSInteger)[_files count];
    for (NSNumber *k in [_cache allKeys]) {
        NSInteger d = labs([k integerValue] - _index);
        d = MIN(d, count - d);
        if (d > 2) [_cache removeObjectForKey:k];
    }
}

- (void)showCurrent {
    NSInteger count = (NSInteger)[_files count];
    if (count == 0) { [self flash:FRT(@"No photos in this folder") duration:0]; return; }
    NSImage *img = nil;
    for (NSInteger tries = 0; tries < count && !img; tries++) {
        NSNumber *key = [NSNumber numberWithInteger:_index];
        img = [_cache objectForKey:key];
        if (!img) {
            img = FRLoadScaled([_files objectAtIndex:(NSUInteger)_index], _maxPx);
            if (img) [_cache setObject:img forKey:key];
        }
        if (!img) _index = (_index + 1) % count;   // unreadable file: skip it
    }
    if (!img) return;
    CATransition *t = [CATransition animation];
    [t setType:kCATransitionFade];
    [t setDuration:0.8];
    [[_imageView layer] addAnimation:t forKey:@"fr.fade"];
    [_imageView setImage:img];
    if (count > 1) {
        [self prefetch:(_index + 1) % count];
        [self prefetch:(_index + count - 1) % count];
    }
    [self trimCache];
}

- (void)startTimer {
    [_timer invalidate];
    _timer = nil;
    if (_playing && [_files count] > 1)
        _timer = [NSTimer scheduledTimerWithTimeInterval:6.0 target:self selector:@selector(tick) userInfo:nil repeats:YES];
}

- (void)tick { [self step:1]; }

- (void)step:(NSInteger)delta {
    NSInteger count = (NSInteger)[_files count];
    if (count == 0) return;
    _index = ((_index + delta) % count + count) % count;
    [self showCurrent];
}

- (void)screenWillAppear {
    _active = YES;
    if (_files) { [self showCurrent]; [self startTimer]; return; }
    // First time: scan the folder on a background thread (can be slow for big photo libraries)
    [self flash:FRT(@"Loading…") duration:0];
    NSString *folder = _folder;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSArray *f = nil;
        @autoreleasepool {
            NSSet *exts = [NSSet setWithObjects:@"jpg", @"jpeg", @"png", @"gif", @"tif", @"tiff", @"bmp", nil];
            f = [FRListFiles(folder, exts) retain];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            _files = f;   // keeps the +1 from retain above
            if (_active) {
                [self hideHud];
                [self showCurrent];
                [self startTimer];
            }
        });
    });
}

- (void)screenDidDisappear {
    _active = NO;
    [_timer invalidate];
    _timer = nil;
    [NSObject cancelPreviousPerformRequestsWithTarget:self];
}

- (void)handleCommand:(FRCommand)c {
    if (!_files) {
        if (c == FRCommandMenu) [[FRController shared] back];
        return;
    }
    switch (c) {
        case FRCommandLeft:  [self step:-1]; [self startTimer]; break;
        case FRCommandRight: [self step:1];  [self startTimer]; break;
        case FRCommandSelect:
        case FRCommandPlayPause:
            _playing = !_playing;
            [self startTimer];
            [self flash:_playing ? FRT(@"▶ Playing") : FRT(@"❚❚ Paused") duration:2.0];
            break;
        case FRCommandMenu:  [[FRController shared] back]; break;
        default: break;
    }
}
@end

#pragma mark - Built-in video player (AVFoundation)

static NSString *FRTimeString(Float64 s) {
    if (s < 0 || s != s) s = 0;
    long t = (long)s;
    if (t >= 3600) return [NSString stringWithFormat:@"%ld:%02ld:%02ld", t / 3600, (t / 60) % 60, t % 60];
    return [NSString stringWithFormat:@"%ld:%02ld", t / 60, t % 60];
}

@implementation FRVideoScreen {
    NSString *_path;
    FRBlackView *_view;
    NSTextField *_hud;
    AVPlayer *_player;
    AVPlayerLayer *_layer;
    BOOL _observing;
}

- (id)initWithPath:(NSString *)path {
    self = [super init];
    if (self) {
        _path = [path copy];
        _player = [[AVPlayer alloc] initWithURL:[NSURL fileURLWithPath:path]];
        _layer = [[AVPlayerLayer playerLayerWithPlayer:_player] retain];
        [_layer setVideoGravity:AVLayerVideoGravityResizeAspect];

        _view = [[FRBlackView alloc] initWithFrame:NSMakeRect(0, 0, 100, 100)];
        [_view setWantsLayer:YES];

        _hud = [FRMakeLabel(30) retain];
        [_hud setFrame:NSMakeRect(0, 30, 100, 46)];
        [_hud setAutoresizingMask:NSViewWidthSizable | NSViewMaxYMargin];
        [_hud setHidden:YES];
        [_view addSubview:_hud];
    }
    return self;
}

- (void)dealloc {
    [NSObject cancelPreviousPerformRequestsWithTarget:self];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_player pause];
    [_layer removeFromSuperlayer];
    [_layer release];
    [_player release];
    [_path release];
    [_hud release];
    [_view release];
    [super dealloc];
}

- (NSView *)view { return _view; }

- (void)flash:(NSString *)text {
    [_hud setStringValue:text];
    [_hud setHidden:NO];
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(hideHud) object:nil];
    [self performSelector:@selector(hideHud) withObject:nil afterDelay:2.0];
}

- (void)hideHud { [_hud setHidden:YES]; }

- (BOOL)ownsPlayPause { return YES; }

- (void)screenWillAppear {
    [_layer setFrame:[[_view layer] bounds]];
    [[_view layer] insertSublayer:_layer atIndex:0];
    if (!_observing) {
        _observing = YES;
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(finished:)
            name:AVPlayerItemDidPlayToEndTimeNotification object:[_player currentItem]];
    }
    [_player play];
    [self performSelector:@selector(checkStatus) withObject:nil afterDelay:1.5];
}

- (void)screenDidDisappear {
    [_player pause];
    [NSObject cancelPreviousPerformRequestsWithTarget:self];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    _observing = NO;
}

- (void)finished:(NSNotification *)n {
    [[FRController shared] back];
}

// If AVFoundation cannot decode the file, hand it over to VLC
- (void)checkStatus {
    if ([[_player currentItem] status] == AVPlayerItemStatusFailed) {
        NSString *p = [[_path retain] autorelease];
        [[FRController shared] back];
        if ([[FRVLC shared] isInstalled]) [[FRVLC shared] playPath:p];
        else FRShowMessage([NSArray arrayWithObjects:FRT(@"Unsupported format"), FRT(@"VLC is required to play this format"), nil]);
    }
}

- (void)seekBy:(Float64)secs {
    CMTime target = CMTimeAdd([_player currentTime], CMTimeMakeWithSeconds(secs, 600));
    if (CMTimeCompare(target, kCMTimeZero) < 0) target = kCMTimeZero;
    [_player seekToTime:target];
    [self flash:[NSString stringWithFormat:@"%+.0f s", secs]];
}

- (void)handleCommand:(FRCommand)c {
    switch (c) {
        case FRCommandSelect:
        case FRCommandPlayPause:
            if ([_player rate] > 0) {
                [_player pause];
                [self flash:FRTF(@"❚❚ Paused — %@", FRTimeString(CMTimeGetSeconds([_player currentTime])))];
            } else {
                [_player play];
                [self flash:FRT(@"▶ Playing")];
            }
            break;
        case FRCommandLeft:  [self seekBy:-10]; break;
        case FRCommandRight: [self seekBy:10]; break;
        case FRCommandUp: {
            float v = MIN(1.0f, [_player volume] + 0.05f);
            [_player setVolume:v];
            [self flash:FRTF(@"Volume %.0f%%", v * 100)];
            break;
        }
        case FRCommandDown: {
            float v = MAX(0.0f, [_player volume] - 0.05f);
            [_player setVolume:v];
            [self flash:FRTF(@"Volume %.0f%%", v * 100)];
            break;
        }
        case FRCommandMenu:  [[FRController shared] back]; break;
        default: break;
    }
}
@end

#pragma mark - Choosing the player

static NSSet *FRNativeVideoExts(void) {
    return [NSSet setWithObjects:@"mov", @"mp4", @"m4v", nil];
}

// Formats AVFoundation cannot play: handled by VLC
static NSSet *FRExternalVideoExts(void) {
    return [NSSet setWithObjects:@"avi", @"mkv", @"wmv", @"flv", @"mpg", @"mpeg", @"ts", @"m2ts", @"mts",
                                 @"webm", @"divx", @"vob", @"ogv", @"3gp", @"rmvb", @"asf", nil];
}

// Asks AVFoundation about a file WITHOUT blocking the interface (the properties load in the background)
static void FRProbeVideo(NSString *path, void (^done)(BOOL playable, BOOL hasVideo, BOOL isProtected)) {
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:path] options:nil];
    NSArray *keys = [NSArray arrayWithObjects:@"playable", @"tracks", @"hasProtectedContent", nil];
    [asset loadValuesAsynchronouslyForKeys:keys completionHandler:^{
        dispatch_async(dispatch_get_main_queue(), ^{
            BOOL playable = ([asset statusOfValueForKey:@"playable" error:NULL] == AVKeyValueStatusLoaded) && [asset isPlayable];
            BOOL hasVideo = ([asset statusOfValueForKey:@"tracks" error:NULL] == AVKeyValueStatusLoaded)
                            && [[asset tracksWithMediaType:AVMediaTypeVideo] count] > 0;
            BOOL prot = ([asset statusOfValueForKey:@"hasProtectedContent" error:NULL] == AVKeyValueStatusLoaded)
                        && [asset hasProtectedContent];
            done(playable, hasVideo, prot);
        });
    }];
}

// VLC for what the built-in player cannot decode
static void FRPlayVideoExternal(NSString *path, BOOL native) {
    if ([[FRVLC shared] isInstalled]) {
        [[FRVLC shared] playPath:path];
    } else if (native) {
        [[FRController shared] push:[[[FRVideoScreen alloc] initWithPath:path] autorelease]];   // let it try (and report)
    } else {
        FRShowMessage([NSArray arrayWithObjects:FRT(@"VLC is required to play this format"),
                       FRT(@"Install it from videolan.org"), nil]);
    }
}

void FRPlayVideoEx(NSString *path, void (^onProtected)(void)) {
    BOOL native = [FRNativeVideoExts() containsObject:[[path pathExtension] lowercaseString]];
    if (!native) { FRPlayVideoExternal(path, NO); return; }

    static BOOL probing = NO;          // ignore a second press while the first probe is running
    if (probing) return;
    probing = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ probing = NO; });
    FRProbeVideo(path, ^(BOOL playable, BOOL hasVideo, BOOL isProtected) {
        probing = NO;
        if (isProtected && onProtected) { onProtected(); return; }
        if (playable && hasVideo) [[FRController shared] push:[[[FRVideoScreen alloc] initWithPath:path] autorelease]];
        else FRPlayVideoExternal(path, YES);    // MOV/MP4 with a codec AVFoundation cannot decode: VLC
    });
}

void FRPlayVideo(NSString *path) { FRPlayVideoEx(path, nil); }

#pragma mark - Photos / Videos menus

static FRMenuScreen *FRMessageMenu(NSString *title, NSString *icon, NSString *msg) {
    NSArray *items = @[ [FRMenuItem itemWithTitle:msg action:nil] ];
    FRMenuScreen *m = [[[FRMenuScreen alloc] initWithTitle:title items:items] autorelease];
    m.icon = icon;
    return m;
}

FRMenuScreen *FRBuildPhotosMenu(void) {
    NSString *root = FRPhotosPath();
    if (![[NSFileManager defaultManager] fileExistsAtPath:root])
        return FRMessageMenu(FRT(@"Photos"), @"photos", FRT(@"Folder not found (see Settings)"));

    NSMutableArray *items = [NSMutableArray array];
    [items addObject:[FRMenuItem itemWithTitle:FRT(@"All Photos") action:^{
        [[FRController shared] push:[[[FRSlideshowScreen alloc] initWithFolder:root] autorelease]];
    }]];
    for (NSString *folder in FRListSubfolders(root)) {
        [items addObject:[FRMenuItem itemWithTitle:[folder lastPathComponent] action:^{
            [[FRController shared] push:[[[FRSlideshowScreen alloc] initWithFolder:folder] autorelease]];
        }]];
    }
    FRMenuScreen *m = [[[FRMenuScreen alloc] initWithTitle:FRT(@"Photos") items:items] autorelease];
    m.icon = @"photos";
    return m;
}

// The folder is scanned in the background (it can be big or on the network), with a "Loading…" screen
void FRShowVideosMenu(void) {
    NSString *root = FRVideosPath();
    FRController *c = [FRController shared];
    if (![[NSFileManager defaultManager] fileExistsAtPath:root]) {
        [c push:FRMessageMenu(FRT(@"Videos"), @"videos", FRT(@"Folder not found (see Settings)"))];
        return;
    }
    id<FRScreen> loading = [[[FRInfoScreen alloc] initWithLines:[NSArray arrayWithObject:FRT(@"Loading…")]] autorelease];
    [c push:loading];
    (void)FRLanguage();

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSArray *files = nil;
        @autoreleasepool {
            NSMutableSet *all = [NSMutableSet setWithSet:FRNativeVideoExts()];
            [all unionSet:FRExternalVideoExts()];
            files = [FRListFiles(root, all) retain];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if ([c topScreen] == loading) {       // (otherwise the user went back meanwhile)
                [c pop];
                NSSet *external = FRExternalVideoExts();
                NSMutableArray *items = [NSMutableArray arrayWithCapacity:[files count]];
                for (NSString *f in files) {
                    NSString *title = ([f hasPrefix:root] && [f length] > [root length] + 1)
                        ? [f substringFromIndex:[root length] + 1] : [f lastPathComponent];
                    title = [title stringByDeletingPathExtension];
                    if ([external containsObject:[[f pathExtension] lowercaseString]])
                        title = [title stringByAppendingString:@"  ·  VLC"];
                    [items addObject:[FRMenuItem itemWithTitle:title action:^{ FRPlayVideo(f); }]];
                }
                if ([items count] == 0) {
                    [c push:FRMessageMenu(FRT(@"Videos"), @"videos", FRT(@"No videos found"))];
                } else {
                    FRMenuScreen *m = [[[FRMenuScreen alloc] initWithTitle:FRT(@"Videos") items:items] autorelease];
                    m.icon = @"videos";
                    [c push:m];
                }
            }
            [files release];
        });
    });
}
