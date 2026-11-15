// DVD playback with the native "DVD Player" app.
//
// While DVD Player is in front, First Row is not the active app: it stops being the exclusive
// owner of the IR receiver, so the Apple Remote drives DVD Player natively (DVD menu, chapters...)
// and First Row ignores every command. When DVD Player quits, First Row comes back.
//
// DVD Player is often opened by the system when a disc is inserted, without First Row asking for it.
// That case is "adopted": as soon as DVD Player launches (or if it is already running), First Row steps
// aside exactly as if it had started it itself: it lets go of the IR receiver, ignores every command
// (so the remote's Menu button does not pop First Row up over the DVD menu) and keeps quiet until
// DVD Player quits.
//
// The end of the session is detected three ways (so First Row can never stay stuck in "DVD mode"):
// the process of DVD Player is tracked and polled every second, every app termination triggers a
// check, and Cmd+Esc brings First Row back at any time.

#import "FR.h"
#include <unistd.h>

static BOOL gDVDActive = NO;
static BOOL gDVDReturnToUI = NO;      // bring First Row back when DVD Player quits (only if it was on screen)
static NSRunningApplication *gDVDApp = nil;
static NSDate *gDVDLaunch = nil;
static NSTimer *gDVDWatchTimer = nil;

// DVD Player is recognised by its bundle id or its file name ("DVD Player.app" is not localised,
// unlike its display name, e.g. "Lecteur DVD")
static BOOL FRIsDVDApp(NSRunningApplication *a) {
    if (!a || [a processIdentifier] == getpid()) return NO;
    if ([[a bundleIdentifier] isEqualToString:@"com.apple.DVDPlayer"]) return YES;
    return [[[a bundleURL] lastPathComponent] isEqualToString:@"DVD Player.app"];
}

static NSRunningApplication *FRFindDVDApp(void) {
    for (NSRunningApplication *a in [[NSWorkspace sharedWorkspace] runningApplications])
        if (FRIsDVDApp(a)) return a;
    return nil;
}

void FRDVDEnded(void) {
    BOOL was = gDVDActive;
    gDVDActive = NO;
    [gDVDWatchTimer invalidate];
    gDVDWatchTimer = nil;
    [gDVDApp release];
    gDVDApp = nil;
    [gDVDLaunch release];
    gDVDLaunch = nil;
    if (was) FRUpdateRemoteMode();   // First Row takes the IR receiver back
}

// End of a DVD session: First Row comes back only if it was on screen when the session started
static void FRDVDFinish(void) {
    BOOL back = gDVDReturnToUI;
    FRDVDEnded();
    if (back) [[FRController shared] showUI];
}

@interface FRDVDWatcher : NSObject
- (void)tick;
@end

@implementation FRDVDWatcher
- (void)tick {
    if (!gDVDActive) { FRDVDEnded(); return; }
    if (!gDVDApp) {
        gDVDApp = [FRFindDVDApp() retain];
        if (!gDVDApp && [[NSDate date] timeIntervalSinceDate:gDVDLaunch] > 20) {   // it never started
            FRDVDFinish();
        }
        return;
    }
    if ([gDVDApp isTerminated]) FRDVDFinish();
}
@end

static void FRDVDStartWatching(void) {
    static FRDVDWatcher *watcher = nil;
    if (!watcher) watcher = [[FRDVDWatcher alloc] init];
    gDVDLaunch = [[NSDate date] retain];
    gDVDWatchTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 target:watcher selector:@selector(tick) userInfo:nil repeats:YES];
}

// First Row itself launched DVD Player
void FRDVDMarkLaunched(void) {
    FRDVDEnded();
    gDVDActive = YES;
    gDVDReturnToUI = YES;
    FRDVDStartWatching();
    FRUpdateRemoteMode();            // let go of the remote right away
}

// DVD Player was launched by something else (disc inserted, Finder, Dock...)
void FRDVDAdoptApp(NSRunningApplication *app) {
    if (!FRIsDVDApp(app)) return;
    if (gDVDActive) {                // already tracked (we launched it)
        if (!gDVDApp) gDVDApp = [app retain];
        return;
    }
    gDVDActive = YES;
    gDVDApp = [app retain];
    gDVDReturnToUI = [[FRController shared] visible];
    FRDVDStartWatching();
    FRUpdateRemoteMode();
}

void FRDVDAdoptRunning(void) {
    NSRunningApplication *a = FRFindDVDApp();
    if (a) FRDVDAdoptApp(a);
}

// Also detects (and cleans up) a DVD Player that quit without us noticing
BOOL FRDVDIsActive(void) {
    if (gDVDActive && gDVDApp && [gDVDApp isTerminated]) FRDVDFinish();
    return gDVDActive;
}

static NSString *FRFindDVDVolume(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *name in [fm contentsOfDirectoryAtPath:@"/Volumes" error:nil]) {
        NSString *p = [@"/Volumes" stringByAppendingPathComponent:name];
        BOOL isDir = NO;
        if ([fm fileExistsAtPath:[p stringByAppendingPathComponent:@"VIDEO_TS"] isDirectory:&isDir] && isDir)
            return p;
    }
    return nil;
}

// DVD Player can take a long time to answer (disc spinning up): its scripts run on their own queue,
// never on the main thread (which would freeze the interface) nor on the iTunes queue.
static void FRRunScript(NSString *src) {
    static dispatch_queue_t q = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ q = dispatch_queue_create("firstrow.dvdplayer", DISPATCH_QUEUE_SERIAL); });
    dispatch_async(q, ^{
        @autoreleasepool {
            NSDictionary *err = nil;
            NSAppleScript *s = [[NSAppleScript alloc] initWithSource:src];
            (void)[s executeAndReturnError:&err];
            [s release];
            if (err) NSLog(@"AppleScript (DVD): %@", err);
        }
    });
}

static void FRLaunchDVDPlayer(BOOL play) {
    FRDVDMarkLaunched();
    [[NSWorkspace sharedWorkspace] launchApplication:@"DVD Player"];
    FRRunScript(@"tell application \"DVD Player\" to activate");
    if (play) {
        // gives the disc time to load; harmless if it starts by itself
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (gDVDActive) FRRunScript(@"tell application \"DVD Player\" to play");
        });
    }
}

FRMenuScreen *FRBuildDVDMenu(void) {
    NSMutableArray *items = [NSMutableArray array];
    NSString *vol = FRFindDVDVolume();

    if (vol) {
        [items addObject:[FRMenuItem itemWithTitle:FRTF(@"Play “%@”", [vol lastPathComponent])
                                            action:^{ FRLaunchDVDPlayer(YES); }]];
        [items addObject:[FRMenuItem itemWithTitle:FRT(@"Eject Disc") action:^{
            [[NSWorkspace sharedWorkspace] unmountAndEjectDeviceAtPath:vol];
            [[FRController shared] pop];
            [[FRController shared] push:FRBuildDVDMenu()];
        }]];
    } else {
        [items addObject:[FRMenuItem itemWithTitle:FRT(@"No DVD detected") action:nil]];
        [items addObject:[FRMenuItem itemWithTitle:FRT(@"Search Again") action:^{
            [[FRController shared] pop];
            [[FRController shared] push:FRBuildDVDMenu()];
        }]];
    }
    [items addObject:[FRMenuItem itemWithTitle:FRT(@"Open DVD Player") action:^{ FRLaunchDVDPlayer(NO); }]];
    FRMenuScreen *m = [[[FRMenuScreen alloc] initWithTitle:@"DVD" items:items] autorelease];
    m.icon = @"dvd";
    return m;
}
