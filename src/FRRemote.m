// Apple IR remote through IOKit HID (AppleIRController).
// Buttons are identified by the sequence of HID "cookies" received; the table below covers the
// white and aluminium remotes, and Settings > Set Up Remote lets you learn your own codes.
//
// Modes: Exclusive (First Row in front, or controlling VLC) seizes the receiver so no other app
// reacts; Shared (background) just listens, so other apps keep working and First Row can still
// notice the Menu button.

#import "FR.h"
#import <IOKit/IOKitLib.h>
#import <IOKit/hid/IOHIDLib.h>
#import <IOKit/IOCFPlugIn.h>

static void FRQueueCallback(void *target, IOReturn result, void *refcon, void *sender);

@implementation FRRemote {
    IOHIDDeviceInterface122 **_hid;
    IOHIDQueueInterface **_queue;
    CFRunLoopSourceRef _source;
    NSMutableDictionary *_map;
    FRRemoteMode _mode;
    BOOL _running;
    // hold-to-repeat (+ / - buttons)
    NSInteger _held;            // command currently held, -1 = none
    NSTimer *_holdTimer;
    CFAbsoluteTime _holdStart, _lastEvent;
    BOOL _sawRepeat;            // the remote itself repeats events while a button is held
    NSInteger _seekHeld;        // hold-left / hold-right command currently held, -1 = none
    BOOL _seized;               // the receiver is really open exclusively
    CFAbsoluteTime _lastStart;
}

+ (FRRemote *)shared {
    static FRRemote *s = nil;
    if (!s) {
        s = [[FRRemote alloc] init];
        s->_held = -1;
        s->_seekHeld = -1;
        [s reloadMap];
    }
    return s;
}

- (BOOL)isRunning { return _running; }

- (void)reloadMap {
    NSMutableDictionary *m = [NSMutableDictionary dictionary];
#define M(code, cmd) [m setObject:[NSNumber numberWithInteger:(cmd)] forKey:(code)]
    // White remote (older Macs)
    M(@"14_12_11_6_", FRCommandUp);   M(@"14_13_11_6_", FRCommandDown);
    M(@"14_7_6_14_7_6_", FRCommandMenu);   M(@"14_8_6_14_8_6_", FRCommandSelect);
    M(@"14_9_6_14_9_6_", FRCommandRight);  M(@"14_10_6_14_10_6_", FRCommandLeft);
    // OS X 10.5 / 10.6
    M(@"31_29_28_18_", FRCommandUp);  M(@"31_30_28_18_", FRCommandDown);
    M(@"31_20_18_31_20_18_", FRCommandMenu);   M(@"31_21_18_31_21_18_", FRCommandSelect);
    M(@"31_22_18_31_22_18_", FRCommandRight);  M(@"31_23_18_31_23_18_", FRCommandLeft);
    // Aluminium remote (OS X 10.6.2 and later)
    M(@"31_29_28_19_18_", FRCommandUp);  M(@"31_30_28_19_18_", FRCommandDown);
    M(@"31_20_19_18_31_20_19_18_", FRCommandMenu);   M(@"31_21_19_18_31_21_19_18_", FRCommandSelect);
    M(@"31_22_19_18_31_22_19_18_", FRCommandRight);  M(@"31_23_19_18_31_23_19_18_", FRCommandLeft);
    // Hold ▶ / ◀ (best effort; Settings > Set Up Remote can learn them)
    M(@"14_6_4_2_", FRCommandSeekForward);  M(@"14_6_3_2_", FRCommandSeekBackward);
    M(@"31_18_4_2_", FRCommandSeekForward); M(@"31_18_3_2_", FRCommandSeekBackward);
    M(@"31_19_18_4_2_", FRCommandSeekForward); M(@"31_19_18_3_2_", FRCommandSeekBackward);
#undef M
    NSDictionary *custom = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"RemoteMap"];
    if (custom) [m addEntriesFromDictionary:custom];
    [_map release];
    _map = [m retain];
}

- (void)setMode:(FRRemoteMode)mode {
    if (mode == _mode && _running && (mode != FRRemoteModeExclusive || _seized)) return;
    if (mode == _mode && mode == FRRemoteModeOff) return;
    // exclusive access was refused earlier (another app held the receiver): try again, but not in a loop
    if (mode == _mode && _running && CFAbsoluteTimeGetCurrent() - _lastStart < 2.0) return;
    [self stopInternal];
    _mode = mode;
    if (mode != FRRemoteModeOff) [self startInternal:(mode == FRRemoteModeExclusive)];
}

- (BOOL)startInternal:(BOOL)exclusive {
    _lastStart = CFAbsoluteTimeGetCurrent();
    io_iterator_t iter = 0;
    if (IOServiceGetMatchingServices(kIOMasterPortDefault, IOServiceMatching("AppleIRController"), &iter) != KERN_SUCCESS)
        return NO;
    io_object_t dev = IOIteratorNext(iter);
    IOObjectRelease(iter);
    if (!dev) { NSLog(@"Apple IR receiver not found"); return NO; }

    IOCFPlugInInterface **plug = NULL;
    SInt32 score = 0;
    IOReturn kr = IOCreatePlugInInterfaceForService(dev, kIOHIDDeviceUserClientTypeID, kIOCFPlugInInterfaceID, &plug, &score);
    IOObjectRelease(dev);
    if (kr != kIOReturnSuccess || !plug) return NO;

    HRESULT hr = (*plug)->QueryInterface(plug, CFUUIDGetUUIDBytes(kIOHIDDeviceInterfaceID122), (LPVOID *)&_hid);
    (*plug)->Release(plug);
    if (hr != 0 || !_hid) { _hid = NULL; return NO; }

    // Cookies of all the HID elements
    CFArrayRef elements = NULL;
    if ((*_hid)->copyMatchingElements(_hid, NULL, &elements) != kIOReturnSuccess || !elements) {
        [self stopInternal];
        return NO;
    }
    NSMutableArray *cookies = [NSMutableArray array];
    for (CFIndex i = 0; i < CFArrayGetCount(elements); i++) {
        CFDictionaryRef el = (CFDictionaryRef)CFArrayGetValueAtIndex(elements, i);
        CFNumberRef c = (CFNumberRef)CFDictionaryGetValue(el, CFSTR(kIOHIDElementCookieKey));
        SInt32 v = 0;
        if (c && CFNumberGetValue(c, kCFNumberSInt32Type, &v)) [cookies addObject:[NSNumber numberWithInt:v]];
    }
    CFRelease(elements);

    // Exclusive access (nobody else reacts) when asked, otherwise (or if refused) shared
    IOReturn r = kIOReturnError;
    _seized = NO;
    if (exclusive) {
        r = (*_hid)->open(_hid, kIOHIDOptionsTypeSeizeDevice);
        _seized = (r == kIOReturnSuccess);
    }
    if (r != kIOReturnSuccess) r = (*_hid)->open(_hid, 0);
    if (r != kIOReturnSuccess) { [self stopInternal]; return NO; }

    _queue = (*_hid)->allocQueue(_hid);
    if (!_queue) { [self stopInternal]; return NO; }
    (*_queue)->create(_queue, 0, 32);
    for (NSNumber *c in cookies)
        (*_queue)->addElement(_queue, (IOHIDElementCookie)(uintptr_t)[c intValue], 0);

    if ((*_queue)->createAsyncEventSource(_queue, &_source) != kIOReturnSuccess || !_source) {
        [self stopInternal];
        return NO;
    }
    (*_queue)->setEventCallout(_queue, FRQueueCallback, self, NULL);
    CFRunLoopAddSource(CFRunLoopGetMain(), _source, kCFRunLoopCommonModes);
    (*_queue)->start(_queue);

    _running = YES;
    return YES;
}

- (void)stopInternal {
    [self stopHold];
    if (_queue) {
        (*_queue)->stop(_queue);
        if (_source) {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), _source, kCFRunLoopCommonModes);
            CFRelease(_source);
            _source = NULL;
        }
        (*_queue)->dispose(_queue);
        (*_queue)->Release(_queue);
        _queue = NULL;
    }
    if (_hid) {
        (*_hid)->close(_hid);
        (*_hid)->Release(_hid);
        _hid = NULL;
    }
    _running = NO;
    _seized = NO;
}

- (void)drain {
    if (!_queue) return;
    IOHIDEventStruct ev;
    AbsoluteTime zero = {0, 0};
    NSMutableString *code = [NSMutableString string];
    BOOL any = NO;
    int sum = 0;
    while ((*_queue)->getNextEvent(_queue, &ev, zero, 0) == kIOReturnSuccess) {
        any = YES;
        [code appendFormat:@"%d_", (int)(uintptr_t)ev.elementCookie];
        sum += ev.value;
    }
    if (!any) return;
    // Handled on the next run-loop turn, never from inside the queue's own callback: handling a button can
    // change the remote mode (hide/show First Row, DVD Player, VLC...), i.e. dispose this very queue.
    NSString *c = [NSString stringWithString:code];
    BOOL pressed = (sum > 0);
    dispatch_async(dispatch_get_main_queue(), ^{ [self handleCode:c pressed:pressed]; });
}

- (void)stopHold {
    [_holdTimer invalidate];
    _holdTimer = nil;
    _held = -1;
    _sawRepeat = NO;
    if (_seekHeld >= 0) {            // never leave the song scrubbing (asynchronously: we may be inside a mode change)
        _seekHeld = -1;
        dispatch_async(dispatch_get_main_queue(), ^{ [[FRController shared] dispatch:FRCommandSeekEnd]; });
    }
}

// Fires while a +/- button is held: first after 0.4 s, then every 0.12 s
- (void)holdFire:(NSTimer *)t {
    _holdTimer = nil;
    if (_held < 0) return;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    // safety: stop if the release was missed (the remote stopped repeating, or 8 s elapsed)
    if (now - _holdStart > 8.0 || (_sawRepeat && now - _lastEvent > 0.6)) { [self stopHold]; return; }
    [[FRController shared] dispatch:(FRCommand)_held];
    _holdTimer = [NSTimer scheduledTimerWithTimeInterval:0.12 target:self selector:@selector(holdFire:) userInfo:nil repeats:NO];
}

- (void)handleCode:(NSString *)code pressed:(BOOL)pressed {
    if (_rawHandler) { if (pressed) _rawHandler(code); return; }
    NSNumber *n = [_map objectForKey:code];
    if (!n) { if (pressed) NSLog(@"Unknown remote code: %@", code); return; }
    FRCommand cmd = (FRCommand)[n integerValue];
    BOOL repeatable = (cmd == FRCommandUp || cmd == FRCommandDown);
    BOOL holdSeek = (cmd == FRCommandSeekForward || cmd == FRCommandSeekBackward);

    if (!pressed) {                                   // release
        if (repeatable && _held == (NSInteger)cmd) [self stopHold];
        if (holdSeek && _seekHeld == (NSInteger)cmd) {
            _seekHeld = -1;
            [[FRController shared] dispatch:FRCommandSeekEnd];
        }
        return;
    }
    if (holdSeek) {                                   // hold ▶ / ◀: scrub until released
        if (_seekHeld == (NSInteger)cmd) return;      // the remote's own repeat
        _seekHeld = (NSInteger)cmd;
        [[FRController shared] dispatch:cmd];
        return;
    }
    if (repeatable) {
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        if (_held == (NSInteger)cmd) {                // the remote's own auto-repeat of a held button
            _sawRepeat = YES;
            _lastEvent = now;
            return;                                   // our timer already repeats
        }
        [self stopHold];
        [[FRController shared] dispatch:cmd];
        if ([[FRController shared] visible]) {
            _held = (NSInteger)cmd;
            _holdStart = _lastEvent = now;
            _holdTimer = [NSTimer scheduledTimerWithTimeInterval:0.4 target:self selector:@selector(holdFire:) userInfo:nil repeats:NO];
        }
        return;
    }
    [[FRController shared] dispatch:cmd];
}

- (void)dealloc {
    [self stopInternal];
    [_map release];
    [_rawHandler release];
    [super dealloc];
}
@end

static void FRQueueCallback(void *target, IOReturn result, void *refcon, void *sender) {
    [(FRRemote *)target drain];
}
