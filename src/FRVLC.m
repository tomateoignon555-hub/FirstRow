// Plays files AVFoundation cannot handle (AVI, MKV, WMV, FLV, ...) with VLC, while First Row keeps
// control: VLC is started fullscreen with its "rc" (remote control) interface listening on a local
// port, and the IR remote / keyboard commands received by First Row are forwarded to it, so the
// remote behaves exactly like with the built-in player. When the file ends or Menu is pressed,
// VLC quits and First Row comes back.

#import "FR.h"
#include <sys/socket.h>
#include <netinet/in.h>
#include <unistd.h>
#include <fcntl.h>

static const int kVLCPort = 61881;
static NSString * const kVLCBundleID = @"org.videolan.vlc";

@implementation FRVLC {
    NSRunningApplication *_app;
    NSTimer *_connectTimer;
    int _fd;
    int _attempts;
    BOOL _active;
    pid_t _pid;
    NSTimer *_watchTimer;
}

+ (FRVLC *)shared {
    static FRVLC *s = nil;
    if (!s) {
        s = [[FRVLC alloc] init];
        s->_fd = -1;
    }
    return s;
}

- (NSURL *)appURL {
    NSURL *u = [[NSWorkspace sharedWorkspace] URLForApplicationWithBundleIdentifier:kVLCBundleID];
    if (!u && [[NSFileManager defaultManager] fileExistsAtPath:@"/Applications/VLC.app"])
        u = [NSURL fileURLWithPath:@"/Applications/VLC.app"];
    return u;
}

- (BOOL)isInstalled { return [self appURL] != nil; }

// The pid comes from the termination notification's userInfo: a terminated NSRunningApplication
// reports -1, so it cannot be compared reliably.
- (BOOL)ownsProcess:(pid_t)pid { return _active && pid > 0 && pid == _pid; }

// Self-healing: if VLC is gone but we never heard about it, end the session so that
// First Row does not keep forwarding every command to a dead VLC.
- (BOOL)active {
    if (_active && (!_app || [_app isTerminated])) {
        NSLog(@"VLC session ended (VLC is gone)");
        [self sessionEnded];
    }
    return _active;
}

- (void)watch {
    if (!_active) return;
    if (![self active]) [[FRController shared] showUI];   // session was closed by the check above
}

- (void)playPath:(NSString *)path {
    NSURL *app = [self appURL];
    if (!app) {
        FRShowMessage([NSArray arrayWithObjects:FRT(@"VLC is required to play this format"),
                       FRT(@"Install it from videolan.org"), nil]);
        return;
    }
    [self sessionEnded];

    NSArray *args = [NSArray arrayWithObjects:
        @"--extraintf", @"rc",
        @"--rc-host", [NSString stringWithFormat:@"127.0.0.1:%d", kVLCPort],
        @"--fullscreen", @"--play-and-exit", path, nil];
    NSDictionary *cfg = [NSDictionary dictionaryWithObject:args forKey:NSWorkspaceLaunchConfigurationArguments];
    NSError *err = nil;
    NSRunningApplication *ra = [[NSWorkspace sharedWorkspace] launchApplicationAtURL:app
        options:NSWorkspaceLaunchNewInstance configuration:cfg error:&err];
    if (!ra) {
        NSLog(@"VLC launch failed: %@", err);
        FRShowMessage([NSArray arrayWithObjects:FRT(@"Could not launch VLC"), nil]);
        return;
    }
    _app = [ra retain];
    _pid = [ra processIdentifier];
    _active = YES;
    _attempts = 0;
    _watchTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self selector:@selector(watch) userInfo:nil repeats:YES];
    _connectTimer = [NSTimer scheduledTimerWithTimeInterval:0.5 target:self selector:@selector(tryConnect) userInfo:nil repeats:YES];
    FRUpdateRemoteMode();   // we keep the IR remote (exclusive) while VLC plays
}

// VLC needs a moment to start its remote-control interface
- (void)tryConnect {
    _attempts++;
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd >= 0) {
        struct sockaddr_in a;
        memset(&a, 0, sizeof a);
        a.sin_family = AF_INET;
        a.sin_port = htons(kVLCPort);
        a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        if (connect(fd, (struct sockaddr *)&a, sizeof a) == 0) {
            int one = 1;
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
            fcntl(fd, F_SETFL, O_NONBLOCK);
            _fd = fd;
            [_connectTimer invalidate];
            _connectTimer = nil;
            return;
        }
        close(fd);
    }
    if (_attempts > 60) {   // 30 s
        [_connectTimer invalidate];
        _connectTimer = nil;
    }
}

- (void)send:(NSString *)cmd {
    if (_fd < 0) return;
    const char *c = [[cmd stringByAppendingString:@"\n"] UTF8String];
    (void)write(_fd, c, strlen(c));
}

- (void)forceQuit {
    if (_active) [_app forceTerminate];
}

- (BOOL)consumeCommand:(FRCommand)c {
    if (![self active]) {                      // also detects a VLC that has already quit
        return NO;
    }
    switch (c) {
        case FRCommandSelect:
        case FRCommandPlayPause:                                            // toggles pause
            if (_fd >= 0) [self send:@"pause"];
            else FRRunVoid(@"tell application \"VLC\" to play");           // rc interface not reachable: VLC's own scripting
        case FRCommandLeft:      [self send:@"key key-jump-short"]; break;  // -10 s
        case FRCommandRight:     [self send:@"key key-jump+short"]; break;  // +10 s
        case FRCommandUp:        [self send:@"volup 2"]; break;
        case FRCommandDown:      [self send:@"voldown 2"]; break;
        case FRCommandMenu:
            [self send:@"quit"];
            [_app terminate];
            [self performSelector:@selector(forceQuit) withObject:nil afterDelay:3.0];
            break;
        default: break;                         // hold-to-seek etc.: swallowed while VLC plays
    }
    return YES;
}

- (void)sessionEnded {
    [NSObject cancelPreviousPerformRequestsWithTarget:self];
    [_connectTimer invalidate];
    _connectTimer = nil;
    [_watchTimer invalidate];
    _watchTimer = nil;
    _pid = 0;
    if (_fd >= 0) { close(_fd); _fd = -1; }
    [_app release];
    _app = nil;
    BOOL was = _active;
    _active = NO;
    if (was) FRUpdateRemoteMode();
}
@end
