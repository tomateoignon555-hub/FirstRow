#import "FR.h"

#define FR_ROOT_SETTINGS_INDEX 6   // position of "Settings" in the main menu

static BOOL FRChooseFolder(NSString *key, NSString *current) {
    NSOpenPanel *p = [NSOpenPanel openPanel];
    [p setCanChooseDirectories:YES];
    [p setCanChooseFiles:NO];
    [p setAllowsMultipleSelection:NO];
    [p setDirectoryURL:[NSURL fileURLWithPath:current]];
    [NSCursor unhide];
    [[FRController shared] setOverlayRaised:NO];   // the panel must be above First Row's window
    NSInteger r = [p runModal];
    [[FRController shared] setOverlayRaised:YES];
    [NSCursor hide];
    if (r == NSFileHandlingPanelOKButton && [p URL]) {
        [[NSUserDefaults standardUserDefaults] setObject:[[p URL] path] forKey:key];
        [[NSUserDefaults standardUserDefaults] synchronize];
        return YES;
    }
    return NO;
}

static void FRReloadTop(void) {
    id<FRScreen> top = [[FRController shared] topScreen];
    if ([top isKindOfClass:[FRMenuScreen class]]) [(FRMenuScreen *)top reload];
}

static NSString *FROnOff(BOOL v) { return FRT(v ? @"On" : @"Off"); }

// "<label>: On/Off" item that flips a boolean setting
static FRMenuItem *FRToggleItem(NSString *fmt, NSString *key, BOOL def) {
    __block FRMenuItem *it = [FRMenuItem itemWithTitle:FRTF(fmt, FROnOff(FRSettingBool(key, def))) action:nil];
    it.action = ^{
        BOOL v = !FRSettingBool(key, def);
        FRSetSettingBool(key, v);
        it.title = FRTF(fmt, FROnOff(v));
        FRReloadTop();
        FRUpdateRemoteMode();
    };
    return it;
}

#pragma mark - Settings menu

FRMenuScreen *FRBuildSettingsMenu(void) {
    FRMenuItem *photos = [FRMenuItem itemWithTitle:
        FRTF(@"Photos folder: %@", [FRPhotosPath() stringByAbbreviatingWithTildeInPath]) action:nil];
    FRMenuItem *videos = [FRMenuItem itemWithTitle:
        FRTF(@"Videos folder: %@", [FRVideosPath() stringByAbbreviatingWithTildeInPath]) action:nil];

    __block FRMenuItem *p = photos;
    __block FRMenuItem *v = videos;
    photos.action = ^{
        if (FRChooseFolder(@"PhotosPath", FRPhotosPath()))
            p.title = FRTF(@"Photos folder: %@", [FRPhotosPath() stringByAbbreviatingWithTildeInPath]);
        FRReloadTop();
    };
    videos.action = ^{
        if (FRChooseFolder(@"VideosPath", FRVideosPath()))
            v.title = FRTF(@"Videos folder: %@", [FRVideosPath() stringByAbbreviatingWithTildeInPath]);
        FRReloadTop();
    };

    BOOL french = [FRLanguage() isEqualToString:@"fr"];
    FRMenuItem *lang = [FRMenuItem itemWithTitle:FRTF(@"Language: %@", french ? @"Français" : @"English") action:^{
        FRSetLanguage(french ? @"en" : @"fr");
        // rebuild every screen with the new language, staying on the Settings menu
        FRMenuScreen *root = FRBuildRootMenu();
        root.selectedIndex = FR_ROOT_SETTINGS_INDEX;
        [root reload];
        FRMenuScreen *settings = FRBuildSettingsMenu();
        settings.selectedIndex = 4;
        [settings reload];
        [[FRController shared] resetStack:[NSArray arrayWithObjects:root, settings, nil]];
    }];

    NSString *remoteState = [[FRRemote shared] isRunning]
        ? FRT(@"IR remote: detected") : FRT(@"IR remote: not detected");

    NSArray *items = @[
        photos,
        videos,
        FRToggleItem(@"Run in background: %@", @"RunInBackground", YES),
        FRToggleItem(@"Start hidden: %@", @"StartHidden", NO),
        lang,
        [FRMenuItem itemWithTitle:FRT(@"Set Up Remote") action:^{
            [[FRController shared] push:[[[FRLearnScreen alloc] init] autorelease]];
        }],
        [FRMenuItem itemWithTitle:remoteState action:nil],
        [FRMenuItem itemWithTitle:FRT(@"Quit First Row") action:^{ [NSApp terminate:nil]; }]
    ];
    FRMenuScreen *m = [[[FRMenuScreen alloc] initWithTitle:FRT(@"Settings") items:items] autorelease];
    m.icon = @"settings";
    return m;
}

#pragma mark - Main menu

FRMenuScreen *FRBuildRootMenu(void) {
    NSArray *items = @[
        [[FRMenuItem itemWithTitle:FRT(@"Movies")   icon:@"movies"   action:^{ [[FRController shared] push:FRBuildMoviesMenu()]; }] withArrow],
        [[FRMenuItem itemWithTitle:FRT(@"TV Shows") icon:@"tvshows"  action:^{ [[FRController shared] push:FRBuildTVMenu()]; }] withArrow],
        [[FRMenuItem itemWithTitle:FRT(@"Music")    icon:@"music"    action:^{ [[FRController shared] push:FRBuildMusicMenu()]; }] withArrow],
        [[FRMenuItem itemWithTitle:FRT(@"Photos")   icon:@"photos"   action:^{ [[FRController shared] push:FRBuildPhotosMenu()]; }] withArrow],
        [[FRMenuItem itemWithTitle:FRT(@"Videos")   icon:@"videos"  action:^{ FRShowVideosMenu(); }] withArrow],
        [[FRMenuItem itemWithTitle:@"DVD"           icon:@"dvd"      action:^{ [[FRController shared] push:FRBuildDVDMenu()]; }] withArrow],
        [[FRMenuItem itemWithTitle:FRT(@"Settings") icon:@"settings" action:^{ [[FRController shared] push:FRBuildSettingsMenu()]; }] withArrow],
        // "Quit" does not really quit: First Row goes to the background and waits for the remote's
        // Menu button (or Cmd+Esc). A real quit is in Settings / Cmd+Q.
        [FRMenuItem itemWithTitle:FRT(@"Quit")      icon:@"logo"     action:^{
            if (FRSettingBool(@"RunInBackground", YES)) [[FRController shared] hideUI];
            else [NSApp terminate:nil];
        }]
    ];
    FRMenuScreen *m = [[[FRMenuScreen alloc] initWithTitle:@"First Row" items:items] autorelease];
    m.iconLayout = YES;
    return m;
}

#pragma mark - Remote set-up (7 buttons)

@implementation FRLearnScreen {
    FRInfoView *_view;
    NSInteger _step;
    NSMutableDictionary *_learned;
}

#define FR_LEARN_STEPS 9

// Same order as the FRCommand enum (Up, Down, Left, Right, Select, Menu, PlayPause, SeekForward, SeekBackward)
static NSString *FRLearnLabel(NSInteger i) {
    static NSString *labels[FR_LEARN_STEPS] = {
        @"“+” (up)", @"“–” (down)", @"“◀” (left)", @"“▶” (right)",
        @"“Center” (select)", @"“Menu” (back)", @"“Play/Pause” (separate from center)",
        @"Hold “▶” (fast-forward a song)", @"Hold “◀” (rewind a song)"
    };
    return FRT(labels[i]);
}

- (id)init {
    self = [super init];
    if (self) {
        _view = [[FRInfoView alloc] initWithFrame:NSMakeRect(0, 0, 100, 100)];
        [_view setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
        _learned = [[NSMutableDictionary alloc] init];
    }
    return self;
}

- (void)dealloc {
    [FRRemote shared].rawHandler = nil;      // the handler must never outlive this screen
    [NSObject cancelPreviousPerformRequestsWithTarget:self];
    [_view release];
    [_learned release];
    [super dealloc];
}

- (NSView *)view { return _view; }

- (void)updateText {
    [_view setLines:[NSArray arrayWithObjects:
        FRTF(@"Press %@", FRLearnLabel(_step)),
        FRTF(@"Button %ld of %d", (long)_step + 1, FR_LEARN_STEPS),
        FRT(@"Enter: skip this button — Esc: cancel"), nil]];
}

- (void)screenWillAppear {
    _step = 0;
    [_learned removeAllObjects];
    if (![[FRRemote shared] isRunning]) {
        [_view setLines:[NSArray arrayWithObjects:
            FRT(@"No Apple IR receiver detected"),
            FRT(@"Plug in the receiver or use the keyboard"), nil]];
        return;
    }
    [self updateText];
    __block FRLearnScreen *me = self;
    [FRRemote shared].rawHandler = ^(NSString *code) { [me captured:code]; };
}

- (void)screenDidDisappear {
    [FRRemote shared].rawHandler = nil;
    [NSObject cancelPreviousPerformRequestsWithTarget:self];
}

- (void)captured:(NSString *)code {
    if (_step >= FR_LEARN_STEPS) return;
    [_learned setObject:[NSNumber numberWithInteger:_step] forKey:code];
    [self advance];
}

- (void)advance {
    _step++;
    if (_step < FR_LEARN_STEPS) { [self updateText]; return; }

    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    NSMutableDictionary *all = [NSMutableDictionary dictionaryWithDictionary:[ud dictionaryForKey:@"RemoteMap"]];
    [all addEntriesFromDictionary:_learned];
    [ud setObject:all forKey:@"RemoteMap"];
    [ud synchronize];
    [[FRRemote shared] reloadMap];
    [FRRemote shared].rawHandler = nil;
    [_view setLines:[NSArray arrayWithObjects:FRT(@"Remote configured"), FRT(@"Returning to menu…"), nil]];
    [self performSelector:@selector(finish) withObject:nil afterDelay:1.5];
}

- (void)finish {
    [[FRController shared] back];
}

- (void)handleCommand:(FRCommand)c {
    if (c == FRCommandMenu) {
        [[FRController shared] back];
    } else if (c == FRCommandSelect && _step < FR_LEARN_STEPS && [[FRRemote shared] isRunning]) {
        [self advance];   // skip this button
    }
}
@end
