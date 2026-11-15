#import <Cocoa/Cocoa.h>

typedef NS_ENUM(NSInteger, FRCommand) {
    FRCommandUp = 0,
    FRCommandDown,
    FRCommandLeft,
    FRCommandRight,
    FRCommandSelect,      // centre button
    FRCommandMenu,
    FRCommandPlayPause,   // play/pause button, separate from the centre button
    FRCommandSeekForward, // hold the right button: fast-forward inside the song
    FRCommandSeekBackward,// hold the left button: rewind inside the song
    FRCommandSeekEnd      // the held left/right button was released
};

@protocol FRScreen <NSObject>
- (NSView *)view;
- (void)handleCommand:(FRCommand)command;
@optional
- (BOOL)ownsPlayPause;      // YES if the screen handles Play/Pause itself (video player); otherwise it toggles iTunes
- (void)screenWillAppear;
- (void)screenDidDisappear;
@end

#pragma mark - Localization (English / French)

NSString *FRT(NSString *english);                        // translated string (English text is the key)
#define FRTF(fmt, ...) [NSString stringWithFormat:FRT(fmt), ##__VA_ARGS__]
NSString *FRLanguage(void);                              // @"en" or @"fr"
void FRSetLanguage(NSString *code);

#pragma mark - Settings and helpers

BOOL FRSettingBool(NSString *key, BOOL defaultValue);
void FRSetSettingBool(NSString *key, BOOL value);
NSString *FRPhotosPath(void);
NSString *FRVideosPath(void);
void FRDrawBackground(NSRect bounds);
NSTextField *FRMakeLabel(CGFloat size);
NSArray *FRListFiles(NSString *root, NSSet *exts);
NSArray *FRListSubfolders(NSString *root);
// AppleScript runs on one background queue (defined in FRMusic.m)
dispatch_queue_t FRScriptQueue(void);
NSAppleEventDescriptor *FRRunErr(NSString *src, NSString **errOut);                 // synchronous
void FRRunVoid(NSString *src);                                                      // fire and forget
void FRRunAsync(NSString *src, void (^done)(NSAppleEventDescriptor *d, NSString *err));   // result on the main thread
// Album covers (FRArtwork.m): iTunes' own artwork first, then the song file's embedded picture, then a cover.jpg /
// folder.jpg next to the file. Playback is still entirely iTunes.
NSString *FRArtKey(NSString *artist, NSString *album);
BOOL FRArtworkIsCached(NSString *key);
void FRLoadArtwork(NSInteger libraryIndex, NSString *key, void (^done)(NSImage *image));   // libraryIndex 0 = the song iTunes is playing
void FRInvalidateArtwork(void);
void FRShowMessage(NSArray *lines);                      // pushes a simple information screen
void FRShowMessageTimed(NSArray *lines, NSTimeInterval seconds);   // same, goes back by itself

@interface FRSound : NSObject
+ (void)play:(NSString *)name;
@end

#pragma mark - Menus

@interface FRMenuItem : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) void (^action)(void);
@property (nonatomic, copy) void (^playAction)(void);   // Play/Pause button on this item
@property (nonatomic, copy) NSString *icon;             // base name of the icon_*.png images
@property (nonatomic, assign) BOOL arrow;               // "›" chevron: the item opens a submenu
@property (nonatomic, assign) BOOL header;              // non-selectable separator row (e.g. "Disc 2")
@property (nonatomic, assign) NSInteger artIndex;       // library song whose album cover is shown while this item is selected (0 = none)
@property (nonatomic, copy) NSString *artKey;           // cache key of that cover (artist + album)
+ (FRMenuItem *)itemWithTitle:(NSString *)title action:(void (^)(void))action;
+ (FRMenuItem *)itemWithTitle:(NSString *)title action:(void (^)(void))action playAction:(void (^)(void))playAction;
+ (FRMenuItem *)itemWithTitle:(NSString *)title icon:(NSString *)icon action:(void (^)(void))action;
+ (FRMenuItem *)headerWithTitle:(NSString *)title;
- (FRMenuItem *)withArrow;
- (FRMenuItem *)withArtIndex:(NSInteger)index key:(NSString *)key;
@end

@interface FRMenuScreen : NSObject <FRScreen>
@property (nonatomic, copy) NSString *title;
@property (nonatomic, retain) NSArray *items;
@property (nonatomic, assign) NSInteger selectedIndex;
@property (nonatomic, copy) NSString *icon;     // section icon shown on the right (submenus)
@property (nonatomic, retain) NSImage *artwork;  // cover of the selected item (nil = show the section icon)
@property (nonatomic, assign) BOOL iconLayout;  // Front Row main-menu style (large icon + centred list)
- (id)initWithTitle:(NSString *)title items:(NSArray *)items;
- (void)reload;
@end

@interface FRInfoScreen : NSObject <FRScreen>
- (id)initWithLines:(NSArray *)lines;
- (id)initWithLines:(NSArray *)lines dismissAfter:(NSTimeInterval)seconds;   // closes itself and goes back
- (void)setLines:(NSArray *)lines;
@end

@interface FRInfoView : NSView
@property (nonatomic, retain) NSArray *lines;
@property (nonatomic, retain) NSImage *image;
@end

#pragma mark - Controller

@interface FRController : NSObject
@property (nonatomic, readonly) BOOL visible;
+ (FRController *)shared;
- (void)setup;                                  // creates the (hidden) window
- (void)showUI;                                 // brings First Row to the front, at the root menu
- (void)hideUI;                                 // back to the background
- (void)toggleUI;                               // Cmd+Esc: show / hide
- (void)setOverlayRaised:(BOOL)raised;          // window above the menu bar (NO while a system panel is shown)
- (void)activeChanged;                          // called when the app is (de)activated
- (void)push:(id<FRScreen>)screen;
- (void)pop;
- (void)back;
- (BOOL)canGoBack;
- (void)resetStack:(NSArray *)screens;
- (id<FRScreen>)topScreen;
- (void)dispatch:(FRCommand)command;
@end

#pragma mark - IR remote

typedef NS_ENUM(NSInteger, FRRemoteMode) {
    FRRemoteModeOff = 0,
    FRRemoteModeShared,      // background: we listen, other apps still get the remote
    FRRemoteModeExclusive    // foreground / VLC session: we own the remote
};

@interface FRRemote : NSObject
@property (nonatomic, copy) void (^rawHandler)(NSString *code);
+ (FRRemote *)shared;
- (void)setMode:(FRRemoteMode)mode;
- (BOOL)isRunning;
- (void)reloadMap;
@end

void FRUpdateRemoteMode(void);

#pragma mark - External players

@interface FRVLC : NSObject
+ (FRVLC *)shared;
- (BOOL)active;                                 // a VLC session is running (self-heals if VLC is gone)
- (BOOL)isInstalled;
- (void)playPath:(NSString *)path;
- (BOOL)consumeCommand:(FRCommand)command;      // YES if the command was consumed by VLC
- (BOOL)ownsProcess:(pid_t)pid;
- (void)sessionEnded;
@end

void FRDVDMarkLaunched(void);
BOOL FRDVDIsActive(void);
void FRDVDEnded(void);
void FRDVDAdoptApp(NSRunningApplication *app);   // DVD Player was opened by something else (disc inserted...)
void FRDVDAdoptRunning(void);                    // same, for a DVD Player already running at launch

#pragma mark - Screens

@interface FRNowPlayingScreen : NSObject <FRScreen>
@end

@interface FRSlideshowScreen : NSObject <FRScreen>
- (id)initWithFolder:(NSString *)folder;
@end

@interface FRVideoScreen : NSObject <FRScreen>
- (id)initWithPath:(NSString *)path;
@end

@interface FRLearnScreen : NSObject <FRScreen>
@end

void FRStartNowPlayingTracker(void);
void FRTogglePlayback(void);                      // play/pause of whatever iTunes is playing
void FRPlayVideo(NSString *path);
void FRPlayVideoEx(NSString *path, void (^onProtected)(void));   // onProtected: called instead of playing a protected (store) file
FRMenuScreen *FRBuildRootMenu(void);
FRMenuScreen *FRBuildMoviesMenu(void);
FRMenuScreen *FRBuildTVMenu(void);
void FRInvalidateVideoLibrary(void);
FRMenuScreen *FRBuildMusicMenu(void);
FRMenuScreen *FRBuildPhotosMenu(void);
void FRShowVideosMenu(void);
FRMenuScreen *FRBuildDVDMenu(void);
FRMenuScreen *FRBuildSettingsMenu(void);

#pragma mark - Application

@interface FRApplication : NSApplication
@end

@interface FRAppDelegate : NSObject <NSApplicationDelegate>
@end
