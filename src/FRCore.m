#import "FR.h"
#import <QuartzCore/QuartzCore.h>

#pragma mark - Localization (English is the default, French is available in Settings)

static NSDictionary *FRFrench(void) {
    static NSDictionary *d = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
    d = [[NSDictionary alloc] initWithObjectsAndKeys:
        // Main menu / sections
        @"Musique", @"Music", @"Vidéos", @"Videos", @"Réglages", @"Settings", @"Quitter", @"Quit",
        @"Quitter First Row", @"Quit First Row",
        // Music
        @"Lecture en cours", @"Now Playing", @"File d'attente", @"Queue", @"Artistes", @"Artists",
        @"Morceaux", @"Songs", @"Tout lire en aléatoire", @"Shuffle All",
        @"Actualiser la bibliothèque", @"Refresh Library", @"Tout lire", @"Play All",
        @"Lire en aléatoire", @"Shuffle", @"Lire l'album", @"Play Album",
        @"Ajouter à la file d'attente", @"Add to Queue", @"Disque %ld", @"Disc %ld",
        @"Lire la playlist", @"Play Playlist", @"Artiste inconnu", @"Unknown Artist",
        @"Album inconnu", @"Unknown Album",
        @"(Playlist vide ou iTunes indisponible)", @"(Empty playlist or iTunes unavailable)",
        @"(Aucune playlist ou iTunes indisponible)", @"(No playlists or iTunes unavailable)",
        @"Chargement de la bibliothèque iTunes…", @"Loading iTunes library…",
        @"Cela peut prendre un moment", @"This may take a moment",
        @"Bibliothèque iTunes indisponible", @"iTunes library unavailable",
        @"Vérifiez qu'iTunes contient des morceaux", @"Make sure iTunes contains songs",
        @"Bibliothèque actualisée", @"Library refreshed", @"%lu morceaux", @"%lu songs",
        @"La file d'attente est vide", @"Queue is empty",
        @"Lancez un morceau depuis Artistes, Albums ou Playlists", @"Play something from Artists, Albums or Playlists",
        @"%lu sur %lu morceaux", @"%lu of %lu songs",
        @"Ajouté à la file d'attente", @"Added to queue",
        // Now playing
        @"▶ Lecture", @"▶ Playing", @"❚❚ Pause", @"❚❚ Paused", @"■ Arrêt", @"■ Stopped",
        @"Dernier morceau lancé", @"Last song played", @"Aucune lecture", @"Nothing playing",
        @"iTunes indisponible — %@", @"iTunes unavailable — %@",
        // Photos / videos
        @"Toutes les photos", @"All Photos", @"Dossier introuvable (voir Réglages)", @"Folder not found (see Settings)",
        @"Aucune photo dans ce dossier", @"No photos in this folder", @"Chargement…", @"Loading…",
        @"Aucune vidéo trouvée", @"No videos found", @"Format non pris en charge", @"Unsupported format",
        @"❚❚ Pause — %@", @"❚❚ Paused — %@",
        @"VLC est nécessaire pour lire ce format", @"VLC is required to play this format",
        @"Installez-le depuis videolan.org", @"Install it from videolan.org",
        @"Impossible de lancer VLC", @"Could not launch VLC",
        // DVD
        @"Lire « %@ »", @"Play “%@”", @"Éjecter le disque", @"Eject Disc", @"Aucun DVD détecté", @"No DVD detected",
        @"Chercher à nouveau", @"Search Again", @"Ouvrir DVD Player", @"Open DVD Player",
        // Settings
        @"Dossier photos : %@", @"Photos folder: %@", @"Dossier vidéos : %@", @"Videos folder: %@",
        @"Exécuter en arrière-plan : %@", @"Run in background: %@", @"Démarrer masqué : %@", @"Start hidden: %@",
        @"Langue : %@", @"Language: %@", @"Activé", @"On", @"Désactivé", @"Off",
        @"Configurer la télécommande", @"Set Up Remote",
        @"Télécommande IR : détectée", @"IR remote: detected", @"Télécommande IR : non détectée", @"IR remote: not detected",
        // Remote set-up
        @"Appuyez sur %@", @"Press %@", @"Bouton %ld sur %d", @"Button %ld of %d",
        @"Entrée : passer ce bouton — Échap : annuler", @"Enter: skip this button — Esc: cancel",
        @"Aucun récepteur IR Apple détecté", @"No Apple IR receiver detected",
        @"Branchez le récepteur ou utilisez le clavier", @"Plug in the receiver or use the keyboard",
        @"Télécommande configurée", @"Remote configured", @"Retour au menu…", @"Returning to menu…",
        @"« + » (haut)", @"“+” (up)", @"« – » (bas)", @"“–” (down)", @"« ◀ » (gauche)", @"“◀” (left)",
        @"« ▶ » (droite)", @"“▶” (right)", @"« Centre » (valider)", @"“Center” (select)",
        @"« Menu » (retour)", @"“Menu” (back)",
        @"« Lecture/Pause » (bouton séparé du centre)", @"“Play/Pause” (separate from center)",
        @"Maintenir « ▶ » (avance rapide dans un morceau)", @"Hold “▶” (fast-forward a song)",
        @"Maintenir « ◀ » (retour rapide dans un morceau)", @"Hold “◀” (rewind a song)",
        // Movies / TV shows
        @"Films", @"Movies", @"Séries TV", @"TV Shows", @"Tous les films", @"All Movies",
        @"Ajoutés récemment", @"Recently Added", @"Non vus", @"Unwatched", @"Séries", @"Shows",
        @"Saison %ld", @"Season %ld", @"Épisodes spéciaux", @"Specials", @"Genre inconnu", @"Unknown Genre",
        @"Série inconnue", @"Unknown Show", @"Chargement des vidéos…", @"Loading videos…",
        @"Aucun film dans iTunes", @"No movies found in iTunes", @"Aucune série dans iTunes", @"No TV shows found in iTunes",
        @"Lecture dans iTunes", @"Playing in iTunes",
        nil];   // objectsAndKeys: French value first, English key second
    });
    return d;
}

static int gLangState = -1;   // -1 = not read yet, 0 = English, 1 = French (a plain int: safe to read from any thread)

NSString *FRLanguage(void) {
    if (gLangState < 0) {
        NSString *l = [[NSUserDefaults standardUserDefaults] stringForKey:@"Language"];
        gLangState = [l isEqualToString:@"fr"] ? 1 : 0;
    }
    return gLangState == 1 ? @"fr" : @"en";
}

void FRSetLanguage(NSString *code) {
    gLangState = [code isEqualToString:@"fr"] ? 1 : 0;
    [[NSUserDefaults standardUserDefaults] setObject:(gLangState == 1 ? @"fr" : @"en") forKey:@"Language"];
    [[NSUserDefaults standardUserDefaults] synchronize];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"FRLanguageChanged" object:nil];
}

NSString *FRT(NSString *english) {
    if (gLangState < 0) (void)FRLanguage();
    if (gLangState != 1) return english;
    NSString *fr = [FRFrench() objectForKey:english];
    return fr ? fr : english;
}

#pragma mark - Settings and helpers

BOOL FRSettingBool(NSString *key, BOOL def) {
    id v = [[NSUserDefaults standardUserDefaults] objectForKey:key];
    return v ? [v boolValue] : def;
}

void FRSetSettingBool(NSString *key, BOOL value) {
    [[NSUserDefaults standardUserDefaults] setBool:value forKey:key];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

NSString *FRPhotosPath(void) {
    NSString *p = [[NSUserDefaults standardUserDefaults] stringForKey:@"PhotosPath"];
    return p ? p : [NSHomeDirectory() stringByAppendingPathComponent:@"Pictures"];
}

NSString *FRVideosPath(void) {
    NSString *p = [[NSUserDefaults standardUserDefaults] stringForKey:@"VideosPath"];
    return p ? p : [NSHomeDirectory() stringByAppendingPathComponent:@"Movies"];
}

void FRDrawBackground(NSRect b) {
    static NSGradient *g = nil;   // created once
    if (!g) {
        g = [[NSGradient alloc]
            initWithStartingColor:[NSColor colorWithCalibratedRed:0.0 green:0.0 blue:0.0 alpha:1]
                      endingColor:[NSColor colorWithCalibratedRed:0.04 green:0.05 blue:0.09 alpha:1]];
    }
    [g drawInRect:b angle:90];
}

NSTextField *FRMakeLabel(CGFloat size) {
    NSTextField *t = [[[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 400, size * 1.5)] autorelease];
    [t setBezeled:NO];
    [t setBordered:NO];
    [t setEditable:NO];
    [t setSelectable:NO];
    [t setDrawsBackground:YES];
    [t setBackgroundColor:[NSColor colorWithCalibratedWhite:0 alpha:0.6]];
    [t setTextColor:[NSColor whiteColor]];
    [t setFont:[NSFont boldSystemFontOfSize:size]];
    [t setAlignment:NSCenterTextAlignment];
    return t;
}

NSArray *FRListFiles(NSString *root, NSSet *exts) {
    NSMutableArray *out = [NSMutableArray array];
    NSURL *url = [NSURL fileURLWithPath:root isDirectory:YES];
    NSDirectoryEnumerator *en = [[NSFileManager defaultManager]
        enumeratorAtURL:url
        includingPropertiesForKeys:nil
        options:(NSDirectoryEnumerationSkipsHiddenFiles | NSDirectoryEnumerationSkipsPackageDescendants)
        errorHandler:nil];
    for (NSURL *u in en) {
        if ([exts containsObject:[[u pathExtension] lowercaseString]]) [out addObject:[u path]];
    }
    [out sortUsingSelector:@selector(localizedStandardCompare:)];
    return out;
}

NSArray *FRListSubfolders(NSString *root) {
    NSMutableArray *out = [NSMutableArray array];
    NSArray *names = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:root error:nil];
    for (NSString *n in names) {
        if ([n hasPrefix:@"."]) continue;
        NSString *full = [root stringByAppendingPathComponent:n];
        BOOL isDir = NO;
        if ([[NSFileManager defaultManager] fileExistsAtPath:full isDirectory:&isDir] && isDir
            && ![[n pathExtension] isEqualToString:@"photoslibrary"]) {
            [out addObject:full];
        }
    }
    [out sortUsingSelector:@selector(localizedStandardCompare:)];
    return out;
}

void FRShowMessage(NSArray *lines) {
    [[FRController shared] push:[[[FRInfoScreen alloc] initWithLines:lines] autorelease]];
}

void FRShowMessageTimed(NSArray *lines, NSTimeInterval seconds) {
    [[FRController shared] push:[[[FRInfoScreen alloc] initWithLines:lines dismissAfter:seconds] autorelease]];
}

#pragma mark - Sounds

@implementation FRSound
+ (void)play:(NSString *)name {
    static NSMutableDictionary *cache = nil;
    if (!cache) cache = [[NSMutableDictionary alloc] init];
    NSSound *s = [cache objectForKey:name];
    if (!s) {
        NSString *p = [[NSBundle mainBundle] pathForResource:name ofType:@"aif"];
        if (!p) return;
        s = [[[NSSound alloc] initWithContentsOfFile:p byReference:YES] autorelease];
        if (!s) return;
        [cache setObject:s forKey:name];
    }
    [s stop];
    [s play];
}
@end

#pragma mark - Information view and screen

@implementation FRInfoView
- (BOOL)isFlipped { return YES; }

// no redraw when nothing changed (the Now Playing screen refreshes regularly)
- (void)setLines:(NSArray *)l {
    if (l == _lines || [l isEqualToArray:_lines]) return;
    [l retain];
    [_lines release];
    _lines = l;
    [self setNeedsDisplay:YES];
}

- (void)setImage:(NSImage *)i {
    if (i == _image) return;
    [i retain];
    [_image release];
    _image = i;
    [self setNeedsDisplay:YES];
}

- (void)dealloc {
    [_lines release];
    [_image release];
    [super dealloc];
}

- (void)drawRect:(NSRect)dirty {
    NSRect b = [self bounds];
    FRDrawBackground(b);
    CGFloat W = b.size.width, H = b.size.height;
    CGFloat textX = W * 0.1, textW = W * 0.8;
    NSTextAlignment align = NSCenterTextAlignment;

    if (_image) {
        CGFloat side = H * 0.45;
        NSSize is = [_image size];
        CGFloat k = (is.width > 0 && is.height > 0) ? MIN(side / is.width, side / is.height) : 1.0;
        NSRect ir = NSMakeRect(W * 0.1 + (side - is.width * k) / 2, (H - is.height * k) / 2, is.width * k, is.height * k);
        [[NSGraphicsContext currentContext] setImageInterpolation:NSImageInterpolationHigh];
        [_image drawInRect:ir fromRect:NSZeroRect operation:NSCompositeSourceOver fraction:1.0 respectFlipped:YES hints:nil];
        textX = W * 0.1 + side + W * 0.04;
        textW = W * 0.92 - textX;
        align = NSLeftTextAlignment;
    }

    NSMutableParagraphStyle *ps = [[[NSMutableParagraphStyle alloc] init] autorelease];
    [ps setAlignment:align];
    [ps setLineBreakMode:NSLineBreakByTruncatingTail];

    CGFloat sizes[4] = { H * 0.06, H * 0.045, H * 0.038, H * 0.032 };
    NSInteger count = MIN((NSInteger)[_lines count], 4);
    CGFloat total = 0;
    for (NSInteger i = 0; i < count; i++) total += sizes[i] * 1.5;
    CGFloat y = (H - total) / 2;

    for (NSInteger i = 0; i < count; i++) {
        NSString *s = [_lines objectAtIndex:i];
        NSDictionary *attrs = @{
            NSFontAttributeName: (i == 0) ? [NSFont boldSystemFontOfSize:sizes[i]] : [NSFont systemFontOfSize:sizes[i]],
            NSForegroundColorAttributeName: (i == 0) ? [NSColor whiteColor] : [NSColor colorWithCalibratedWhite:(i == 1 ? 0.8 : 0.6) alpha:1],
            NSParagraphStyleAttributeName: ps };
        [s drawInRect:NSMakeRect(textX, y, textW, sizes[i] * 1.4) withAttributes:attrs];
        y += sizes[i] * 1.5;
    }
}
@end

@implementation FRInfoScreen {
    FRInfoView *_view;
    NSTimeInterval _dismissAfter;
}
- (id)initWithLines:(NSArray *)lines dismissAfter:(NSTimeInterval)seconds {
    self = [super init];
    if (self) {
        _view = [[FRInfoView alloc] initWithFrame:NSMakeRect(0, 0, 100, 100)];
        [_view setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
        [_view setLines:lines];
        _dismissAfter = seconds;
    }
    return self;
}
- (id)initWithLines:(NSArray *)lines { return [self initWithLines:lines dismissAfter:0]; }
- (void)dealloc {
    [NSObject cancelPreviousPerformRequestsWithTarget:self];
    [_view release];
    [super dealloc];
}
- (NSView *)view { return _view; }
- (void)setLines:(NSArray *)lines { [_view setLines:lines]; }
- (void)screenWillAppear {
    if (_dismissAfter > 0) [self performSelector:@selector(dismiss) withObject:nil afterDelay:_dismissAfter];
}
- (void)screenDidDisappear { [NSObject cancelPreviousPerformRequestsWithTarget:self]; }
// closes itself and returns to the previous menu (unless the user already left)
- (void)dismiss {
    if ([[FRController shared] topScreen] == self) [[FRController shared] back];
}
- (void)handleCommand:(FRCommand)c {
    if (c == FRCommandMenu || c == FRCommandLeft || c == FRCommandSelect) [[FRController shared] back];
}
@end

#pragma mark - Window and controller

@interface FRWindow : NSWindow
@end

@implementation FRWindow
- (BOOL)canBecomeKeyWindow { return YES; }
- (BOOL)canBecomeMainWindow { return YES; }
- (void)keyDown:(NSEvent *)e {
    if ([e isARepeat] && [e keyCode] != 126 && [e keyCode] != 125) return;
    FRController *c = [FRController shared];
    switch ([e keyCode]) {
        case 126: [c dispatch:FRCommandUp]; break;
        case 125: [c dispatch:FRCommandDown]; break;
        case 123: [c dispatch:FRCommandLeft]; break;
        case 124: [c dispatch:FRCommandRight]; break;
        case 36: case 76: [c dispatch:FRCommandSelect]; break;
        case 49: [c dispatch:FRCommandPlayPause]; break;
        case 53: case 51: [c dispatch:FRCommandMenu]; break;
        default: break;
    }
}
@end

static void FRSlideFade(CALayer *layer, CGFloat fx, CGFloat tx, float fa, float ta, CFTimeInterval dur, BOOL keep) {
    if (!layer) return;
    CAMediaTimingFunction *ease = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    CABasicAnimation *m = [CABasicAnimation animationWithKeyPath:@"transform.translation.x"];
    [m setFromValue:[NSNumber numberWithDouble:fx]];
    [m setToValue:[NSNumber numberWithDouble:tx]];
    CABasicAnimation *o = [CABasicAnimation animationWithKeyPath:@"opacity"];
    [o setFromValue:[NSNumber numberWithFloat:fa]];
    [o setToValue:[NSNumber numberWithFloat:ta]];
    for (CABasicAnimation *an in [NSArray arrayWithObjects:m, o, nil]) {
        [an setDuration:dur];
        [an setTimingFunction:ease];
        if (keep) { [an setFillMode:kCAFillModeForwards]; [an setRemovedOnCompletion:NO]; }
    }
    [layer addAnimation:m forKey:@"fr.slide"];
    [layer addAnimation:o forKey:@"fr.fade"];
}

@implementation FRController {
    NSWindow *_window;
    NSView *_container;
    NSMutableArray *_stack;
    BOOL _visible;
    BOOL _cursorHidden;
}

@synthesize visible = _visible;

+ (FRController *)shared {
    static FRController *s = nil;
    if (!s) s = [[FRController alloc] init];
    return s;
}

- (void)setup {
    _stack = [[NSMutableArray alloc] init];
    NSRect frame = [[NSScreen mainScreen] frame];
    _window = [[FRWindow alloc] initWithContentRect:frame
                                          styleMask:NSBorderlessWindowMask
                                            backing:NSBackingStoreBuffered
                                              defer:NO];
    [_window setBackgroundColor:[NSColor blackColor]];
    [_window setOpaque:YES];
    [_window setReleasedWhenClosed:NO];

    _container = [[NSView alloc] initWithFrame:[[_window contentView] bounds]];
    [_container setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    [_container setWantsLayer:YES];
    [[_window contentView] addSubview:_container];
}

- (void)clearScreens {
    id<FRScreen> top = [_stack lastObject];
    if (top && [top respondsToSelector:@selector(screenDidDisappear)]) [top screenDidDisappear];
    [_stack removeAllObjects];
    for (NSView *v in [NSArray arrayWithArray:[_container subviews]]) [v removeFromSuperview];
}

// Brings First Row to the front (from the background, or after DVD Player / VLC)
- (void)showUI {
    if (!_window) return;
    if (_visible) {   // already up (coming back from VLC / DVD Player): re-assert everything
        [NSApp unhide:nil];
        [self setOverlayRaised:YES];
        [_window makeKeyAndOrderFront:nil];
        [NSApp activateIgnoringOtherApps:YES];
        [NSApp setPresentationOptions:NSApplicationPresentationHideDock | NSApplicationPresentationHideMenuBar];
        [self performSelector:@selector(reactivate) withObject:nil afterDelay:0.4];
        FRUpdateRemoteMode();
        return;
    }
    _visible = YES;
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];   // menu bar / Dock hiding need a regular app
    [self clearScreens];
    [_window setFrame:[[NSScreen mainScreen] frame] display:NO];
    [self push:FRBuildRootMenu()];
    [NSApp unhide:nil];
    [self setOverlayRaised:YES];
    [_window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
    [NSApp setPresentationOptions:NSApplicationPresentationHideDock | NSApplicationPresentationHideMenuBar];
    if (!_cursorHidden) { [NSCursor hide]; _cursorHidden = YES; }
    [self performSelector:@selector(reactivate) withObject:nil afterDelay:0.4];
    FRUpdateRemoteMode();
}

// Activation can lose a race with the app that was in front (VLC closing): try again
- (void)reactivate {
    if (!_visible) return;
    if (![NSApp isActive]) [NSApp activateIgnoringOtherApps:YES];
    [self activeChanged];
    FRUpdateRemoteMode();
}

// Back to the background: the app keeps running and listens to the Menu button
- (void)hideUI {
    if (!_visible) return;
    _visible = NO;
    [self clearScreens];
    [_window orderOut:nil];
    if (_cursorHidden) { [NSCursor unhide]; _cursorHidden = NO; }
    [NSApp setPresentationOptions:NSApplicationPresentationDefault];
    [NSApp hide:nil];
    [_window setLevel:NSNormalWindowLevel];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];   // back to a Dock-less background app
    FRUpdateRemoteMode();
}

// Cmd+Esc
- (void)toggleUI {
    if (_visible && [NSApp isActive]) {
        if (FRSettingBool(@"RunInBackground", YES)) [self hideUI];
        else [NSApp terminate:nil];
    } else {
        [self showUI];
    }
}

// The window sits above the menu bar and Dock (so nothing of the desktop shows), except while another
// app is in front (DVD Player, VLC) or a system panel is open.
- (void)setOverlayRaised:(BOOL)raised {
    [_window setLevel:raised ? NSMainMenuWindowLevel + 1 : NSNormalWindowLevel];
}

- (void)activeChanged {
    [self setOverlayRaised:(_visible && [NSApp isActive])];
}

// Screen change: the new screen slides in with a fade while the old one slides out
- (void)swapFrom:(id<FRScreen>)old to:(id<FRScreen>)next forward:(BOOL)fwd {
    NSView *nv = [next view];
    [nv setFrame:[_container bounds]];
    [nv setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    NSView *ov = old ? [[old view] retain] : nil;
    if (old && [old respondsToSelector:@selector(screenDidDisappear)]) [old screenDidDisappear];
    [_container addSubview:nv];
    if ([next respondsToSelector:@selector(screenWillAppear)]) [next screenWillAppear];
    [nv setNeedsDisplay:YES];
    if (!ov) return;

    CGFloat d = [_container bounds].size.width * 0.06 * (fwd ? 1 : -1);
    CFTimeInterval dur = 0.32;
    FRSlideFade([nv layer], d, 0, 0.0f, 1.0f, dur, NO);
    FRSlideFade([ov layer], 0, -d, 1.0f, 0.0f, dur, YES);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((dur + 0.05) * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        // not if the user already came back to this screen (push then quick pop): that would blank it
        if ([(id<FRScreen>)[_stack lastObject] view] != ov) [ov removeFromSuperview];
        [ov release];
    });
}

- (void)push:(id<FRScreen>)screen {
    id<FRScreen> old = [_stack lastObject];
    [_stack addObject:screen];
    [self swapFrom:old to:screen forward:YES];
}

- (void)pop {
    if ([_stack count] <= 1) return;
    id<FRScreen> old = [[_stack lastObject] retain];
    [_stack removeLastObject];
    [self swapFrom:old to:[_stack lastObject] forward:NO];
    [old release];
}

- (void)resetStack:(NSArray *)screens {
    if ([screens count] == 0) return;
    id<FRScreen> old = [[_stack lastObject] retain];
    [_stack setArray:screens];
    [self swapFrom:old to:[_stack lastObject] forward:YES];
    [old release];
}

- (BOOL)canGoBack { return [_stack count] > 1; }

// Menu button: previous screen; at the root, go to the background (or quit if background mode is off)
- (void)back {
    if ([self canGoBack]) {
        [FRSound play:@"Exit"];
        [self pop];
    } else if (FRSettingBool(@"RunInBackground", YES)) {
        [self hideUI];
    } else {
        [NSApp terminate:nil];
    }
}

- (id<FRScreen>)topScreen { return [_stack lastObject]; }

- (void)dispatch:(FRCommand)c {
    if ([[FRVLC shared] consumeCommand:c]) return;  // VLC is playing: forward to VLC
    if (FRDVDIsActive()) return;                    // DVD Player has the remote
    if (c == FRCommandSeekEnd) {                    // a held button was released: always deliver
        [(id<FRScreen>)[_stack lastObject] handleCommand:c];
        return;
    }
    if (!_visible || ![NSApp isActive]) {
        if (c == FRCommandMenu) [self showUI];      // Menu from the background opens First Row
        return;
    }
    id<FRScreen> top = [[_stack lastObject] retain];
    if (c == FRCommandPlayPause && !([top respondsToSelector:@selector(ownsPlayPause)] && [top ownsPlayPause])) {
        FRTogglePlayback();                         // Play/Pause always controls the playing media
    } else {
        [top handleCommand:c];
    }
    [top release];
}
@end
