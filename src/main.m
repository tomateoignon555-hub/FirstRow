#import "FR.h"
#import <Carbon/Carbon.h>

#pragma mark - Remote mode policy

// Exclusive while First Row is in front or controlling VLC; shared (background) otherwise.
void FRUpdateRemoteMode(void) {
    FRRemoteMode m;
    if (FRDVDIsActive()) m = FRRemoteModeOff;                    // DVD Player has the remote
    else if ([[FRVLC shared] active]) m = FRRemoteModeExclusive;
    else if ([[FRController shared] visible] && [NSApp isActive]) m = FRRemoteModeExclusive;
    else if (FRSettingBool(@"RunInBackground", YES)) m = FRRemoteModeShared;
    else m = FRRemoteModeOff;
    [[FRRemote shared] setMode:m];
}

#pragma mark - Application

@implementation FRApplication

// Media keys (Play / Next / Previous): fallback for remotes and receivers that send media keys
// instead of raw IR events.
- (void)sendEvent:(NSEvent *)event {
    if ([event type] == NSSystemDefined && [event subtype] == 8) {
        NSInteger data1 = [event data1];
        int keyCode = (int)((data1 & 0xFFFF0000) >> 16);
        int keyFlags = (int)(data1 & 0x0000FFFF);
        BOOL down = (((keyFlags & 0xFF00) >> 8) == 0xA);
        FRController *c = [FRController shared];
        switch (keyCode) {
            case 16: if (down) [c dispatch:FRCommandPlayPause]; return;           // play/pause
            case 17: case 19: if (down) [c dispatch:FRCommandRight]; return;      // next
            case 18: case 20: if (down) [c dispatch:FRCommandLeft]; return;       // previous
            default: break;
        }
    }
    [super sendEvent:event];
}
@end

#pragma mark - Cmd+Esc (global shortcut)

static EventHotKeyRef gHotKey = NULL;

static OSStatus FRHotKeyHandler(EventHandlerCallRef next, EventRef event, void *userData) {
    dispatch_async(dispatch_get_main_queue(), ^{
        // Escape hatch: while VLC / DVD Player is in charge, Cmd+Esc takes the screen and the remote back
        BOOL external = NO;
        if ([[FRVLC shared] active]) { [[FRVLC shared] sessionEnded]; external = YES; }
        if (FRDVDIsActive()) { FRDVDEnded(); external = YES; }
        if (external) [[FRController shared] showUI];
        else [[FRController shared] toggleUI];
    });
    return noErr;
}

static void FRRegisterHotKey(void) {
    EventTypeSpec spec = { kEventClassKeyboard, kEventHotKeyPressed };
    InstallApplicationEventHandler(&FRHotKeyHandler, 1, &spec, NULL, NULL);
    EventHotKeyID hid = { 'frHK', 1 };
    RegisterEventHotKey(kVK_Escape, cmdKey, hid, GetApplicationEventTarget(), 0, &gHotKey);
}

@implementation FRAppDelegate

- (void)buildMainMenu {
    NSMenu *mainMenu = [[[NSMenu alloc] init] autorelease];
    NSMenuItem *appItem = [[[NSMenuItem alloc] init] autorelease];
    [mainMenu addItem:appItem];
    NSMenu *appMenu = [[[NSMenu alloc] init] autorelease];
    [appMenu addItemWithTitle:FRT(@"Quit First Row") action:@selector(terminate:) keyEquivalent:@"q"];
    [appItem setSubmenu:appMenu];
    [NSApp setMainMenu:mainMenu];
}

- (void)applicationDidFinishLaunching:(NSNotification *)n {
    [self buildMainMenu];
    // When DVD Player or VLC (started by us) quits, First Row comes back
    [[[NSWorkspace sharedWorkspace] notificationCenter] addObserver:self selector:@selector(appTerminated:)
        name:NSWorkspaceDidTerminateApplicationNotification object:nil];
    // DVD Player opened by the system when a disc is inserted: First Row steps aside
    [[[NSWorkspace sharedWorkspace] notificationCenter] addObserver:self selector:@selector(appLaunched:)
        name:NSWorkspaceDidLaunchApplicationNotification object:nil];
    FRStartNowPlayingTracker();
    FRRegisterHotKey();
    [[FRController shared] setup];
    BOOL hidden = FRSettingBool(@"StartHidden", NO) && FRSettingBool(@"RunInBackground", YES);
    FRDVDAdoptRunning();   // DVD Player already open?
    if (!hidden && !FRDVDIsActive()) [[FRController shared] showUI];
    FRUpdateRemoteMode();
}

- (void)appLaunched:(NSNotification *)n {
    FRDVDAdoptApp([[n userInfo] objectForKey:NSWorkspaceApplicationKey]);
}

- (void)appTerminated:(NSNotification *)n {
    NSRunningApplication *app = [[n userInfo] objectForKey:NSWorkspaceApplicationKey];
    NSString *bid = [app bundleIdentifier];
    pid_t pid = (pid_t)[[[n userInfo] objectForKey:@"NSApplicationProcessIdentifier"] intValue];
    if ([[FRVLC shared] ownsProcess:pid]) {
        [[FRVLC shared] sessionEnded];
        [[FRController shared] showUI];
    } else if ([bid isEqualToString:@"org.videolan.vlc"]) {
        [[FRVLC shared] active];   // makes sure a dead VLC session is closed (the watchdog also does it)
    }
    FRDVDIsActive();               // closes a DVD session whose DVD Player is gone and brings First Row back
}

- (BOOL)applicationShouldHandleReopen:(NSApplication *)app hasVisibleWindows:(BOOL)flag {
    [[FRController shared] showUI];
    return NO;
}

- (void)applicationDidBecomeActive:(NSNotification *)n { [[FRController shared] activeChanged]; FRUpdateRemoteMode(); }
- (void)applicationDidResignActive:(NSNotification *)n { [[FRController shared] activeChanged]; FRUpdateRemoteMode(); }

- (void)applicationWillTerminate:(NSNotification *)n {
    if (gHotKey) UnregisterEventHotKey(gHotKey);
    [[FRRemote shared] setMode:FRRemoteModeOff];
    [[FRVLC shared] sessionEnded];
    [NSCursor unhide];
}
@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        FRApplication *app = (FRApplication *)[FRApplication sharedApplication];
        FRAppDelegate *delegate = [[FRAppDelegate alloc] init];
        [app setDelegate:delegate];
        // Background app: no Dock icon; it shows its window when asked (Menu button on the remote)
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        [app run];
    }
    return 0;
}
