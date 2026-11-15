// iTunes 11 integration: library browsing (artists / albums / songs), playlists,
// in-order or shuffled playback, play queue management and the Now Playing screen.
//
// How playback works: the library is read once (cached). Every time something is played, a
// temporary iTunes playlist called "First Row" is filled with the wanted tracks (in order, or
// shuffled here) and started. First Row keeps its OWN copy of that queue (FRQueue), so skipping
// to the next/previous track is done by explicitly playing the right entry of the playlist
// instead of using iTunes' "next track" (which follows iTunes' own Up Next queue).

#import "FR.h"

static NSString * const kTempPlaylist = @"First Row";

#pragma mark - AppleScript helpers

static NSString *FRQuote(NSString *s) {
    s = [s stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"];
    return [s stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
}

// All AppleScript runs on ONE serial background queue, so a slow iTunes never freezes the interface.
//  - FRRunVoid:  fire and forget
//  - FRRunAsync: result delivered later on the main thread
//  - FRRun/FRRunErr: synchronous (waits for the queue; only used for short, rare requests)
static char kScriptQueueKey;

dispatch_queue_t FRScriptQueue(void) {
    static dispatch_queue_t q = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        q = dispatch_queue_create("firstrow.applescript", DISPATCH_QUEUE_SERIAL);
        dispatch_queue_set_specific(q, &kScriptQueueKey, &kScriptQueueKey, NULL);
    });
    return q;
}

// Executes a script right now (must be called on the script queue)
static NSAppleEventDescriptor *FRRunNow(NSString *src, NSString **errOut) {
    NSDictionary *err = nil;
    NSAppleScript *s = [[NSAppleScript alloc] initWithSource:src];
    NSAppleEventDescriptor *d = [s executeAndReturnError:&err];
    [s release];
    if (!d) {
        NSString *msg = [err objectForKey:NSAppleScriptErrorMessage];
        NSString *text = [NSString stringWithFormat:@"%@ (%@)", msg ? msg : @"AppleScript error",
                          [err objectForKey:NSAppleScriptErrorNumber]];
        NSLog(@"AppleScript: %@", text);
        if (errOut) *errOut = text;
    }
    return d;
}

NSAppleEventDescriptor *FRRunErr(NSString *src, NSString **errOut) {
    if (dispatch_get_specific(&kScriptQueueKey)) return FRRunNow(src, errOut);   // already on the queue
    __block NSAppleEventDescriptor *d = nil;
    __block NSString *e = nil;
    dispatch_sync(FRScriptQueue(), ^{
        @autoreleasepool {
            NSString *err = nil;
            d = [FRRunNow(src, &err) retain];
            e = [err retain];
        }
    });
    if (errOut) *errOut = [e autorelease]; else [e release];
    return [d autorelease];
}

static NSAppleEventDescriptor *FRRun(NSString *src) { return FRRunErr(src, NULL); }

void FRRunVoid(NSString *src) {
    dispatch_async(FRScriptQueue(), ^{
        @autoreleasepool { (void)FRRunNow(src, NULL); }
    });
}

void FRRunAsync(NSString *src, void (^done)(NSAppleEventDescriptor *d, NSString *err)) {
    dispatch_async(FRScriptQueue(), ^{
        NSAppleEventDescriptor *d = nil;
        NSString *err = nil;
        @autoreleasepool {
            NSString *e = nil;
            d = [FRRunNow(src, &e) retain];
            err = [e retain];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            done(d, err);
            [d release];
            [err release];
        });
    });
}

static NSArray *FRStrings(NSAppleEventDescriptor *l) {
    if ([l descriptorType] != (DescType)'list') {     // a single value instead of a list (one-element range)
        NSString *one = [l stringValue];
        return one ? [NSArray arrayWithObject:one] : [NSArray array];
    }
    NSInteger n = [l numberOfItems];
    NSMutableArray *a = [NSMutableArray arrayWithCapacity:(NSUInteger)n];
    for (NSInteger i = 1; i <= n; i++) {
        NSString *s = [[l descriptorAtIndex:i] stringValue];
        [a addObject:(s ? s : @"")];
    }
    return a;
}

static NSArray *FRInts(NSAppleEventDescriptor *l) {
    if ([l descriptorType] != (DescType)'list')
        return [NSArray arrayWithObject:[NSNumber numberWithInt:(int)[l int32Value]]];
    NSInteger n = [l numberOfItems];
    NSMutableArray *a = [NSMutableArray arrayWithCapacity:(NSUInteger)n];
    for (NSInteger i = 1; i <= n; i++)
        [a addObject:[NSNumber numberWithInt:(int)[[l descriptorAtIndex:i] int32Value]]];
    return a;
}

static void FRPushNowPlaying(void) {
    [[FRController shared] push:[[[FRNowPlayingScreen alloc] init] autorelease]];
}

static void FRPushMenu(NSString *title, NSArray *items) {
    FRMenuScreen *m = [[[FRMenuScreen alloc] initWithTitle:title items:items] autorelease];
    m.icon = @"music";
    [[FRController shared] push:m];
}

static NSMutableArray *FRShuffled(NSArray *a) {
    NSMutableArray *m = [NSMutableArray arrayWithArray:a];
    for (NSUInteger i = [m count]; i > 1; i--)
        [m exchangeObjectAtIndex:i - 1 withObjectAtIndex:arc4random_uniform((uint32_t)i)];
    return m;
}

static NSArray *FRRange(NSUInteger count) {
    NSMutableArray *a = [NSMutableArray arrayWithCapacity:count];
    for (NSUInteger i = 1; i <= count; i++) [a addObject:[NSNumber numberWithUnsignedInteger:i]];
    return a;
}

#pragma mark - Play queue (First Row's own copy)

@interface FRQueue : NSObject
@property (nonatomic, retain) NSMutableArray *entries;   // NSDictionary: n (name), a (artist), b (album)
@property (nonatomic, assign) NSInteger position;        // entry being played, -1 = unknown / outside the queue
+ (FRQueue *)shared;
- (void)replaceWith:(NSArray *)entries position:(NSInteger)pos;
- (void)appendEntries:(NSArray *)entries;
- (void)syncWithName:(NSString *)name;
@end

@implementation FRQueue
+ (FRQueue *)shared {
    static FRQueue *s = nil;
    if (!s) {
        s = [[FRQueue alloc] init];
        s.entries = [NSMutableArray array];
        s.position = -1;
    }
    return s;
}
- (void)replaceWith:(NSArray *)entries position:(NSInteger)pos {
    [_entries setArray:entries];
    _position = pos;
}
- (void)appendEntries:(NSArray *)entries { [_entries addObjectsFromArray:entries]; }

// iTunes told us which song is playing: find it in our queue (starting at the current position)
- (void)syncWithName:(NSString *)name {
    NSInteger count = (NSInteger)[_entries count];
    if (count == 0 || [name length] == 0) return;
    NSInteger start = MAX(0, _position);
    for (NSInteger k = 0; k < count; k++) {
        NSInteger i = (start + k) % count;
        if ([[[_entries objectAtIndex:i] objectForKey:@"n"] isEqualToString:name]) { _position = i; return; }
    }
    _position = -1;   // played outside of our queue (e.g. directly from iTunes)
}
@end

#pragma mark - Now playing tracker (iTunes notification)
// iTunes posts "com.apple.iTunes.playerInfo" on every track / state change: no AppleScript needed.
// The last track is remembered (even across restarts).

@interface FRNowPlaying : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *artist;
@property (nonatomic, copy) NSString *album;
@property (nonatomic, copy) NSString *state;     // "Playing", "Paused", "Stopped"; nil = unknown
@property (nonatomic, assign) BOOL live;         // YES if the info comes from this session
+ (FRNowPlaying *)shared;
- (void)start;
- (void)noteName:(NSString *)name artist:(NSString *)artist album:(NSString *)album;
@end

@implementation FRNowPlaying

+ (FRNowPlaying *)shared {
    static FRNowPlaying *s = nil;
    if (!s) s = [[FRNowPlaying alloc] init];
    return s;
}

- (void)start {
    NSDictionary *last = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"LastTrack"];
    if (last) {
        self.name = [last objectForKey:@"Name"];
        self.artist = [last objectForKey:@"Artist"];
        self.album = [last objectForKey:@"Album"];
    }
    [[NSDistributedNotificationCenter defaultCenter] addObserver:self selector:@selector(playerInfo:)
        name:@"com.apple.iTunes.playerInfo" object:nil
        suspensionBehavior:NSNotificationSuspensionBehaviorDeliverImmediately];
}

- (void)save {
    if ([_name length] == 0) return;
    NSDictionary *d = [NSDictionary dictionaryWithObjectsAndKeys:
        _name, @"Name", (_artist ? _artist : @""), @"Artist", (_album ? _album : @""), @"Album", nil];
    [[NSUserDefaults standardUserDefaults] setObject:d forKey:@"LastTrack"];
}

- (void)changed {
    [[NSNotificationCenter defaultCenter] postNotificationName:@"FRNowPlayingChanged" object:nil];
}

- (void)playerInfo:(NSNotification *)n {
    NSDictionary *u = [n userInfo];
    NSString *nm = [u objectForKey:@"Name"];
    if ([nm length]) {
        self.name = nm;
        NSString *ar = [u objectForKey:@"Artist"], *al = [u objectForKey:@"Album"];
        self.artist = ar ? ar : @"";
        self.album = al ? al : @"";
        [self save];
        [[FRQueue shared] syncWithName:nm];
    }
    NSString *st = [u objectForKey:@"Player State"];
    if (st) self.state = st;
    self.live = YES;
    [self changed];
}

- (void)noteName:(NSString *)name artist:(NSString *)artist album:(NSString *)album {
    self.name = name;
    self.artist = artist;
    self.album = album;
    self.state = @"Playing";
    self.live = YES;
    [self save];
    [self changed];
}
@end

void FRStartNowPlayingTracker(void) { [[FRNowPlaying shared] start]; }

#pragma mark - Playing

static BOOL gNoShuffleProp = NO, gNoShuffleEnabled = NO;   // that term does not exist in this iTunes: stop trying

// Runs a script that may not compile on this iTunes version (unknown term). A compile-type error (-27xx)
// disables it for good; other errors (e.g. the playlist does not exist yet) do not count.
static void FRTryOptional(NSString *src, BOOL *disabled) {
    if (*disabled) return;
    NSString *err = nil;
    if (!FRRunErr(src, &err) && [err rangeOfString:@"(-27"].location != NSNotFound) *disabled = YES;
}

static NSUInteger gFillGeneration = 0;   // a newer playback request cancels the pending chunks of the previous one
static BOOL gFillActive = NO;            // chunks of a playback request are still being appended

// Appends list[from...] to the temporary playlist, 40 tracks per script. Runs on the script queue; between
// two chunks the other commands (skip, volume, seek...) get their turn instead of waiting for the whole fill.
static void FRFillChunk(NSArray *list, NSUInteger from, NSString *source, NSUInteger generation) {
    if (generation != gFillGeneration) return;   // superseded by a newer request
    NSUInteger n = (from < [list count]) ? MIN((NSUInteger)40, [list count] - from) : 0;
    if (n == 0) { gFillActive = NO; return; }
    NSString *joined = [[list subarrayWithRange:NSMakeRange(from, n)] componentsJoinedByString:@", "];
    FRRun([NSString stringWithFormat:
        @"tell application \"iTunes\"\n"
        @"if not (exists user playlist \"%@\") then make new user playlist with properties {name:\"%@\"}\n"
        @"set pl to user playlist \"%@\"\n"
        @"set src to %@\n"
        @"repeat with i in {%@}\n"
        @"set n to contents of i\n"
        @"try\nduplicate (track n of src) to pl\nend try\n"
        @"end repeat\n"
        @"end tell", kTempPlaylist, kTempPlaylist, kTempPlaylist, source, joined]);
    if (from + n < [list count]) {
        dispatch_async(FRScriptQueue(), ^{ FRFillChunk(list, from + n, source, generation); });
    } else {
        gFillActive = NO;
    }
}

// Fills the temporary playlist with `idxs` (1-based indices inside `source`) and starts it at `*start`.
// Returns the list actually queued (shuffled / truncated); *start is updated. Playback starts as soon as
// the first tracks are in the playlist; the rest is appended while the music plays.
static NSArray *FRPlayIndices(NSArray *idxs, NSInteger *start, BOOL shuffle, NSUInteger limit, NSString *source) {
    NSMutableArray *list = shuffle ? FRShuffled(idxs) : [NSMutableArray arrayWithArray:idxs];
    NSInteger st = shuffle ? 0 : *start;
    if ([list count] > limit) [list removeObjectsInRange:NSMakeRange(limit, [list count] - limit)];
    if ([list count] == 0) return nil;
    if (st < 0 || st >= (NSInteger)[list count]) st = 0;
    *start = st;

    NSArray *snapshot = [NSArray arrayWithArray:list];
    NSUInteger gen = ++gFillGeneration;
    gFillActive = YES;
    NSUInteger firstCount = MIN((NSUInteger)(st + 1 + 5), [snapshot count]);   // enough to start at st
    NSString *first = [[snapshot subarrayWithRange:NSMakeRange(0, firstCount)] componentsJoinedByString:@", "];
    NSString *startScript = [NSString stringWithFormat:
        @"tell application \"iTunes\"\n"
        @"if not (exists user playlist \"%@\") then make new user playlist with properties {name:\"%@\"}\n"
        @"set pl to user playlist \"%@\"\n"
        @"try\ndelete every track of pl\nend try\n"
        @"set src to %@\n"
        @"repeat with i in {%@}\n"
        @"set n to contents of i\n"
        @"try\nduplicate (track n of src) to pl\nend try\n"
        @"end repeat\n"
        @"try\nplay (track %ld of pl)\non error\nplay pl\nend try\n"
        @"end tell",
        kTempPlaylist, kTempPlaylist, kTempPlaylist, source, first, (long)(st + 1)];
    NSString *shuffleOff1 = [NSString stringWithFormat:@"tell application \"iTunes\" to set shuffle of user playlist \"%@\" to false", kTempPlaylist];

    dispatch_async(FRScriptQueue(), ^{
        if (gen != gFillGeneration) return;
        // iTunes shuffle settings: separate scripts, because depending on the iTunes version these
        // terms may not exist (an error here is harmless).
        FRTryOptional(shuffleOff1, &gNoShuffleProp);
        FRTryOptional(@"tell application \"iTunes\" to set shuffle enabled to false", &gNoShuffleEnabled);
        FRRun(startScript);
        FRFillChunk(snapshot, firstCount, source, gen);
    });
    return list;
}

static void FRNoteEntry(NSDictionary *e) {
    [[FRNowPlaying shared] noteName:[e objectForKey:@"n"] artist:[e objectForKey:@"a"] album:[e objectForKey:@"b"]];
}

// Plays entry `i` of OUR queue explicitly (bypasses iTunes' Up Next queue)
static void FRQueuePlayIndex(NSInteger i) {
    FRQueue *q = [FRQueue shared];
    if (i < 0 || i >= (NSInteger)[q.entries count]) return;
    FRRunVoid([NSString stringWithFormat:@"tell application \"iTunes\" to play (track %ld of user playlist \"%@\")",
               (long)i + 1, kTempPlaylist]);
    q.position = i;
    FRNoteEntry([q.entries objectAtIndex:(NSUInteger)i]);
}

// Next / previous song, following First Row's queue
static void FRSkip(BOOL forward) {
    FRQueue *q = [FRQueue shared];
    NSInteger count = (NSInteger)[q.entries count];
    if (q.position >= 0 && count > 0) {
        NSInteger pos = q.position;
        if (forward) {
            if (pos + 1 < count) { FRQueuePlayIndex(pos + 1); return; }
        } else {
            // more than 3 s into the song: restart it, otherwise go to the previous one
            FRRunAsync(@"tell application \"iTunes\" to return (player position as integer)",
                       ^(NSAppleEventDescriptor *d, NSString *err) {
                NSInteger secs = d ? (NSInteger)[d int32Value] : 0;
                if (secs > 3 || pos == 0) FRRunVoid(@"tell application \"iTunes\" to set player position to 0");
                else FRQueuePlayIndex(pos - 1);
            });
            return;
        }
    }
    // queue unknown or finished: let iTunes decide
    FRRunVoid(forward ? @"tell application \"iTunes\" to next track" : @"tell application \"iTunes\" to previous track");
}

#pragma mark - Library cache

@interface FRGroup : NSObject
@property (nonatomic, copy) NSString *title;            // artist or album name
@property (nonatomic, copy) NSString *artist;
@property (nonatomic, retain) NSMutableArray *idxs;     // 1-based indices in the library
@end

@implementation FRGroup
- (id)init {
    self = [super init];
    if (self) _idxs = [[NSMutableArray alloc] init];
    return self;
}
- (void)dealloc {
    [_title release];
    [_artist release];
    [_idxs release];
    [super dealloc];
}
@end

@interface FRLibrary : NSObject
@property (nonatomic, retain) NSArray *names;
@property (nonatomic, retain) NSArray *artists;          // album artist if known, else the song's artist
@property (nonatomic, retain) NSArray *albums;
@property (nonatomic, retain) NSArray *trackNos;
@property (nonatomic, retain) NSArray *discs;
@property (nonatomic, retain) NSArray *songOrder;        // song indices sorted by title (computed once)
@property (nonatomic, retain) NSArray *artistGroups;
@property (nonatomic, retain) NSArray *albumGroups;
@property (nonatomic, retain) NSDictionary *albumsByArtist;
@property (nonatomic, assign) BOOL loaded;
@property (nonatomic, assign) BOOL loading;               // a load is running (main thread)
@property (nonatomic, assign) NSUInteger progressDone, progressTotal;
@property (copy) NSString *lastError;                  // why the last load failed (shown on screen)
+ (FRLibrary *)shared;
- (BOOL)load;
- (void)startLoadIfNeeded;
- (void)invalidate;
@end

@implementation FRLibrary

+ (FRLibrary *)shared {
    static FRLibrary *s = nil;
    if (!s) {
        s = [[FRLibrary alloc] init];
        [[NSNotificationCenter defaultCenter] addObserver:s selector:@selector(invalidate)
                                                     name:@"FRLanguageChanged" object:nil];
    }
    return s;
}

- (void)invalidate { self.loaded = NO; }

// Starts reading the library in the background (once, whoever asks), on the main thread.
- (void)startLoadIfNeeded {
    if (_loaded || _loading) return;
    _loading = YES;
    _progressDone = 0;
    _progressTotal = 0;
    self.lastError = nil;
    NSDate *started = [NSDate date];
    dispatch_async(FRScriptQueue(), ^{
        BOOL ok;
        @autoreleasepool { ok = [self load]; }
        dispatch_async(dispatch_get_main_queue(), ^{
            _loading = NO;
            if (ok) NSLog(@"First Row: iTunes library loaded (%lu songs, %.1f s)", (unsigned long)[_names count],
                          -[started timeIntervalSinceNow]);
            else NSLog(@"First Row: could not load the iTunes library: %@", [self lastError] ? [self lastError] : @"(no error)");
        });
    });
}

static BOOL gNoAlbumArtist = NO;   // that iTunes does not know the "album artist" term: stop asking

// Runs on the script queue. The library is read in chunks of 500 songs: every AppleScript call stays short (a
// single call for a big library used to hit the AppleEvent time-out), the loading screen shows the progress and
// a failure now says why.
- (BOOL)load {
    NSString *err = nil;
    NSAppleEventDescriptor *cd = FRRunErr(@"tell application \"iTunes\" to return count of tracks of library playlist 1", &err);
    if (!cd) { self.lastError = err; return NO; }
    NSUInteger total = (NSUInteger)[cd int32Value];
    if (total == 0) { self.lastError = nil; return NO; }
    dispatch_async(dispatch_get_main_queue(), ^{ _progressTotal = total; });

    NSMutableArray *arM = [NSMutableArray arrayWithCapacity:total], *alM = [NSMutableArray arrayWithCapacity:total];
    NSMutableArray *nmM = [NSMutableArray arrayWithCapacity:total], *tnM = [NSMutableArray arrayWithCapacity:total];
    NSMutableArray *dnM = [NSMutableArray arrayWithCapacity:total], *aaM = [NSMutableArray arrayWithCapacity:total];
    BOOL haveAlbumArtist = NO;

    for (NSUInteger from = 1; from <= total; from += 500) {
        @autoreleasepool {
            NSUInteger to = MIN(total, from + 499);
            NSString *rng = [NSString stringWithFormat:@"(tracks %lu thru %lu of library playlist 1)", (unsigned long)from, (unsigned long)to];
            // artist / album / name exist on every kind of track; the numbers are optional
            NSString *src = [NSString stringWithFormat:
                @"tell application \"iTunes\"\n"
                @"with timeout of 600 seconds\n"
                @"set a to artist of %@\n"
                @"set b to album of %@\n"
                @"set n to name of %@\n"
                @"set tn to {}\n"
                @"set dn to {}\n"
                @"try\nset tn to track number of %@\nend try\n"
                @"try\nset dn to disc number of %@\nend try\n"
                @"return {a, b, n, tn, dn}\n"
                @"end timeout\n"
                @"end tell", rng, rng, rng, rng, rng];
            NSAppleEventDescriptor *d = FRRunErr(src, &err);
            if (!d || [d numberOfItems] < 5) { self.lastError = err; return NO; }

            NSArray *a1 = FRStrings([d descriptorAtIndex:1]);
            NSArray *b1 = FRStrings([d descriptorAtIndex:2]);
            NSArray *n1 = FRStrings([d descriptorAtIndex:3]);
            NSArray *t1 = FRInts([d descriptorAtIndex:4]);
            NSArray *d1 = FRInts([d descriptorAtIndex:5]);
            NSUInteger k = [n1 count];
            if (k == 0 || [a1 count] != k || [b1 count] != k) {
                self.lastError = @"Unexpected answer from iTunes";
                return NO;
            }
            [arM addObjectsFromArray:a1];
            [alM addObjectsFromArray:b1];
            [nmM addObjectsFromArray:n1];
            for (NSUInteger i = 0; i < k; i++) {      // missing numbers count as 0
                [tnM addObject:(i < [t1 count] && [t1 count] == k) ? [t1 objectAtIndex:i] : [NSNumber numberWithInt:0]];
                [dnM addObject:(i < [d1 count] && [d1 count] == k) ? [d1 objectAtIndex:i] : [NSNumber numberWithInt:0]];
            }

            // "Album artist": its own script (if this iTunes does not know the term, it does not even compile)
            NSArray *aa1 = nil;
            if (!gNoAlbumArtist) {
                NSString *err2 = nil;
                NSAppleEventDescriptor *ad = FRRunErr([NSString stringWithFormat:
                    @"tell application \"iTunes\"\n"
                    @"try\n"
                    @"with timeout of 600 seconds\n"
                    @"return album artist of %@\n"
                    @"end timeout\n"
                    @"on error\nreturn {}\nend try\n"
                    @"end tell", rng], &err2);
                if (ad) aa1 = FRStrings(ad);
                else if ([err2 rangeOfString:@"(-27"].location != NSNotFound) gNoAlbumArtist = YES;
            }
            if ([aa1 count] == k) { [aaM addObjectsFromArray:aa1]; haveAlbumArtist = YES; }
            else for (NSUInteger i = 0; i < k; i++) [aaM addObject:@""];

            NSUInteger done = to;
            dispatch_async(dispatch_get_main_queue(), ^{ _progressDone = done; });
        }
    }

    NSArray *ar = arM, *al = alM, *nm = nmM, *tn = tnM, *dn = dnM;
    NSArray *aa = haveAlbumArtist ? aaM : nil;
    NSUInteger n = [nm count];
    if (n == 0 || [ar count] != n || [al count] != n || [tn count] != n || [dn count] != n || (aa && [aa count] != n)) {
        self.lastError = @"Unexpected answer from iTunes";
        return NO;
    }

    NSString *unknownArtist = FRT(@"Unknown Artist"), *unknownAlbum = FRT(@"Unknown Album");
    NSMutableArray *eff = [NSMutableArray arrayWithCapacity:n];
    NSMutableArray *alb = [NSMutableArray arrayWithCapacity:n];
    NSMutableDictionary *artistMap = [NSMutableDictionary dictionary];
    NSMutableDictionary *albumMap = [NSMutableDictionary dictionary];

    for (NSUInteger i = 0; i < n; i++) {
        NSString *a = (aa && [[aa objectAtIndex:i] length]) ? [aa objectAtIndex:i] : [ar objectAtIndex:i];
        if ([a length] == 0) a = unknownArtist;
        NSString *b = [al objectAtIndex:i];
        if ([b length] == 0) b = unknownAlbum;
        [eff addObject:a];
        [alb addObject:b];

        NSNumber *num = [NSNumber numberWithUnsignedInteger:i + 1];

        FRGroup *g = [artistMap objectForKey:a];
        if (!g) {
            g = [[[FRGroup alloc] init] autorelease];
            g.title = a;
            g.artist = a;
            [artistMap setObject:g forKey:a];
        }
        [g.idxs addObject:num];

        NSString *key = [NSString stringWithFormat:@"%@\x1F%@", a, b];
        FRGroup *ag = [albumMap objectForKey:key];
        if (!ag) {
            ag = [[[FRGroup alloc] init] autorelease];
            ag.title = b;
            ag.artist = a;
            [albumMap setObject:ag forKey:key];
        }
        [ag.idxs addObject:num];
    }

    // Track order inside an album: disc, track number, title
    NSComparisonResult (^cmp)(id, id) = ^NSComparisonResult(id x, id y) {
        NSUInteger i = [x unsignedIntegerValue] - 1, j = [y unsignedIntegerValue] - 1;
        NSInteger d1 = MAX(1, [[dn objectAtIndex:i] integerValue]), d2 = MAX(1, [[dn objectAtIndex:j] integerValue]);
        if (d1 != d2) return d1 < d2 ? NSOrderedAscending : NSOrderedDescending;
        NSInteger t1 = [[tn objectAtIndex:i] integerValue], t2 = [[tn objectAtIndex:j] integerValue];
        if (t1 != t2) return t1 < t2 ? NSOrderedAscending : NSOrderedDescending;
        return [[nm objectAtIndex:i] localizedCaseInsensitiveCompare:[nm objectAtIndex:j]];
    };

    NSMutableDictionary *byArtist = [NSMutableDictionary dictionary];
    for (FRGroup *g in [albumMap allValues]) {
        [g.idxs sortUsingComparator:cmp];
        NSMutableArray *l = [byArtist objectForKey:g.artist];
        if (!l) {
            l = [NSMutableArray array];
            [byArtist setObject:l forKey:g.artist];
        }
        [l addObject:g];
    }
    for (NSMutableArray *l in [byArtist allValues]) {
        [l sortUsingComparator:^NSComparisonResult(id a, id b) {
            return [[a title] localizedCaseInsensitiveCompare:[b title]];
        }];
    }
    // "Play All" for an artist: album by album, in track order
    for (FRGroup *g in [artistMap allValues]) {
        [g.idxs removeAllObjects];
        for (FRGroup *a in [byArtist objectForKey:g.title]) [g.idxs addObjectsFromArray:a.idxs];
    }

    // Songs sorted by title: done once, here (background thread), with pre-folded keys (much faster than
    // calling a localized comparison 100,000 times)
    NSMutableArray *folded = [NSMutableArray arrayWithCapacity:n];
    for (NSString *t in nm)
        [folded addObject:[t stringByFoldingWithOptions:(NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch) locale:nil]];
    NSMutableArray *order = [NSMutableArray arrayWithCapacity:n];
    for (NSUInteger i = 1; i <= n; i++) [order addObject:[NSNumber numberWithUnsignedInteger:i]];
    [order sortUsingComparator:^NSComparisonResult(id x, id y) {
        return [[folded objectAtIndex:[x unsignedIntegerValue] - 1] compare:[folded objectAtIndex:[y unsignedIntegerValue] - 1]];
    }];
    self.songOrder = order;

    self.names = nm;
    self.artists = eff;
    self.albums = alb;
    self.trackNos = tn;
    self.discs = dn;
    self.albumsByArtist = byArtist;
    self.artistGroups = [[artistMap allValues] sortedArrayUsingComparator:^NSComparisonResult(id a, id b) {
        return [[a title] localizedCaseInsensitiveCompare:[b title]];
    }];
    self.albumGroups = [[albumMap allValues] sortedArrayUsingComparator:^NSComparisonResult(id a, id b) {
        NSComparisonResult r = [[a title] localizedCaseInsensitiveCompare:[b title]];
        return r != NSOrderedSame ? r : [[a artist] localizedCaseInsensitiveCompare:[b artist]];
    }];
    self.loaded = YES;
    return YES;
}
@end

static NSArray *FRLibraryEntries(FRLibrary *lib, NSArray *idxs) {
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:[idxs count]];
    for (NSNumber *num in idxs) {
        NSUInteger i = [num unsignedIntegerValue] - 1;
        if (i >= [lib.names count]) continue;
        [out addObject:[NSDictionary dictionaryWithObjectsAndKeys:
            [lib.names objectAtIndex:i], @"n", [lib.artists objectAtIndex:i], @"a",
            [lib.albums objectAtIndex:i], @"b", num, @"i", nil]];
    }
    return out;
}

static void FRPlayGroup(NSArray *idxs, NSInteger start, BOOL shuffle) {
    NSInteger st = start;
    NSArray *list = FRPlayIndices(idxs, &st, shuffle, 1500, @"library playlist 1");
    if (!list) return;
    NSArray *entries = FRLibraryEntries([FRLibrary shared], list);
    [[FRQueue shared] replaceWith:entries position:st];
    if ((NSUInteger)st < [entries count]) FRNoteEntry([entries objectAtIndex:(NSUInteger)st]);   // shows the song right away
    FRPushNowPlaying();
}

// Appends after the running fill is finished (otherwise the playlist order and our queue would differ)
static void FRAppendWhenIdle(NSArray *snapshot, NSUInteger generation) {
    if (generation != gFillGeneration) return;   // a new playback replaced the queue meanwhile
    if (gFillActive) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            FRAppendWhenIdle(snapshot, generation);
        });
        return;
    }
    dispatch_async(FRScriptQueue(), ^{ FRFillChunk(snapshot, 0, @"library playlist 1", generation); });
}

// "Add to Queue": appends to First Row's playlist without interrupting the current song
static void FRAppendToQueue(FRLibrary *lib, NSArray *idxs) {
    FRQueue *q = [FRQueue shared];
    if ([q.entries count] == 0) { FRPlayGroup(idxs, 0, NO); return; }
    NSMutableArray *list = [NSMutableArray arrayWithArray:idxs];
    if ([list count] > 1500) [list removeObjectsInRange:NSMakeRange(1500, [list count] - 1500)];
    FRAppendWhenIdle([NSArray arrayWithArray:list], gFillGeneration);
    [q appendEntries:FRLibraryEntries(lib, list)];
    FRShowMessageTimed([NSArray arrayWithObjects:FRT(@"Added to queue"), FRTF(@"%lu songs", (unsigned long)[list count]), nil], 3.0);
}

// Loads the library if needed (reading iTunes + sorting happen on the script queue; the interface stays
// responsive and shows a "Loading…" screen)
static void FRPollLibrary(FRLibrary *lib, FRInfoScreen *loading, void (^then)(FRLibrary *lib)) {
    FRController *c = [FRController shared];
    if ([c topScreen] != loading) return;          // the user went back: the load goes on in the background
    if ([lib loading]) {
        NSString *second = ([lib progressTotal] > 0)
            ? FRTF(@"%lu of %lu songs", (unsigned long)[lib progressDone], (unsigned long)[lib progressTotal])
            : FRT(@"This may take a moment");
        [loading setLines:[NSArray arrayWithObjects:FRT(@"Loading iTunes library…"), second, nil]];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            FRPollLibrary(lib, loading, then);
        });
        return;
    }
    [c pop];
    if ([lib loaded]) then(lib);
    else FRShowMessage([NSArray arrayWithObjects:FRT(@"iTunes library unavailable"),
                        [lib lastError] ? [lib lastError] : FRT(@"Make sure iTunes contains songs"), nil]);
}

// Loads the library if needed: reading iTunes and sorting happen on the script queue; the interface stays
// responsive and shows a "Loading…" screen with the progress.
static void FRWithLibrary(void (^then)(FRLibrary *lib)) {
    FRLibrary *lib = [FRLibrary shared];
    if ([lib loaded]) { then(lib); return; }

    FRController *c = [FRController shared];
    FRInfoScreen *loading = [[[FRInfoScreen alloc] initWithLines:
        [NSArray arrayWithObjects:FRT(@"Loading iTunes library…"), FRT(@"This may take a moment"), nil]] autorelease];
    [c push:loading];
    (void)FRLanguage();      // initialised on the main thread before the background load uses FRT()
    [lib startLoadIfNeeded];
    FRPollLibrary(lib, loading, then);
}

#pragma mark - Library screens

static void FRShowAlbum(FRLibrary *lib, FRGroup *a);

// first song of a group (its cover is the album's cover)
static NSUInteger FRFirstIndex(FRGroup *g) {
    return [g.idxs count] ? [[g.idxs objectAtIndex:0] unsignedIntegerValue] : 0;
}

// an artist is shown with the cover of its first album
static NSUInteger FRArtistCoverIndex(FRLibrary *lib, FRGroup *g) {
    NSArray *albums = [lib.albumsByArtist objectForKey:g.title];
    return [albums count] ? FRFirstIndex([albums objectAtIndex:0]) : FRFirstIndex(g);
}

// the cover of library song `idx` is shown while the item is selected
static FRMenuItem *FRArt(FRMenuItem *it, FRLibrary *lib, NSUInteger idx) {
    if (idx >= 1 && idx <= [lib.names count])
        [it withArtIndex:(NSInteger)idx key:FRArtKey([lib.artists objectAtIndex:idx - 1], [lib.albums objectAtIndex:idx - 1])];
    return it;
}

static void FRShowArtist(FRLibrary *lib, FRGroup *g) {
    NSUInteger cover = FRArtistCoverIndex(lib, g);
    NSMutableArray *items = [NSMutableArray array];
    [items addObject:FRArt([FRMenuItem itemWithTitle:FRT(@"Play All") action:^{ FRPlayGroup(g.idxs, 0, NO); }], lib, cover)];
    [items addObject:FRArt([FRMenuItem itemWithTitle:FRT(@"Shuffle") action:^{ FRPlayGroup(g.idxs, 0, YES); }], lib, cover)];
    [items addObject:FRArt([FRMenuItem itemWithTitle:FRT(@"Add to Queue") action:^{ FRAppendToQueue(lib, g.idxs); }], lib, cover)];
    for (FRGroup *a in [lib.albumsByArtist objectForKey:g.title]) {
        NSString *t = [NSString stringWithFormat:@"%@  (%lu)", a.title, (unsigned long)[a.idxs count]];
        [items addObject:FRArt([[FRMenuItem itemWithTitle:t
                                                   action:^{ FRShowAlbum(lib, a); }
                                               playAction:^{ FRPlayGroup(a.idxs, 0, NO); }] withArrow], lib, FRFirstIndex(a))];
    }
    FRPushMenu(g.title, items);
}

static void FRShowAlbum(FRLibrary *lib, FRGroup *a) {
    NSUInteger cover = FRFirstIndex(a);
    NSMutableArray *items = [NSMutableArray array];
    [items addObject:FRArt([FRMenuItem itemWithTitle:FRT(@"Play Album") action:^{ FRPlayGroup(a.idxs, 0, NO); }], lib, cover)];
    [items addObject:FRArt([FRMenuItem itemWithTitle:FRT(@"Shuffle") action:^{ FRPlayGroup(a.idxs, 0, YES); }], lib, cover)];
    [items addObject:FRArt([FRMenuItem itemWithTitle:FRT(@"Add to Queue") action:^{ FRAppendToQueue(lib, a.idxs); }], lib, cover)];

    // Multi-disc albums get a "Disc N" separator before each disc
    NSMutableSet *discSet = [NSMutableSet set];
    for (NSNumber *num in a.idxs)
        [discSet addObject:[NSNumber numberWithInteger:MAX(1, [[lib.discs objectAtIndex:[num unsignedIntegerValue] - 1] integerValue])]];
    BOOL multiDisc = ([discSet count] > 1);
    NSInteger lastDisc = -1;

    for (NSUInteger pos = 0; pos < [a.idxs count]; pos++) {
        NSUInteger idx = [[a.idxs objectAtIndex:pos] unsignedIntegerValue];
        NSInteger disc = MAX(1, [[lib.discs objectAtIndex:idx - 1] integerValue]);
        if (multiDisc && disc != lastDisc) {
            [items addObject:[FRMenuItem headerWithTitle:FRTF(@"Disc %ld", (long)disc)]];
            lastDisc = disc;
        }
        NSInteger tn = [[lib.trackNos objectAtIndex:idx - 1] integerValue];
        NSString *name = [lib.names objectAtIndex:idx - 1];
        NSString *title = (tn > 0) ? [NSString stringWithFormat:@"%ld. %@", (long)tn, name] : name;
        NSInteger start = (NSInteger)pos;
        [items addObject:FRArt([FRMenuItem itemWithTitle:title action:^{ FRPlayGroup(a.idxs, start, NO); }], lib, cover)];
    }
    FRPushMenu(a.title, items);
}

static void FRShowArtists(FRLibrary *lib) {
    NSMutableArray *items = [NSMutableArray array];
    for (FRGroup *g in lib.artistGroups) {
        [items addObject:FRArt([[FRMenuItem itemWithTitle:g.title
                                                   action:^{ FRShowArtist(lib, g); }
                                               playAction:^{ FRPlayGroup(g.idxs, 0, NO); }] withArrow], lib, FRArtistCoverIndex(lib, g))];
    }
    FRPushMenu(FRT(@"Artists"), items);
}

static void FRShowAlbums(FRLibrary *lib) {
    NSMutableArray *items = [NSMutableArray array];
    for (FRGroup *a in lib.albumGroups) {
        NSString *t = [NSString stringWithFormat:@"%@ — %@", a.title, a.artist];
        [items addObject:FRArt([[FRMenuItem itemWithTitle:t
                                                   action:^{ FRShowAlbum(lib, a); }
                                               playAction:^{ FRPlayGroup(a.idxs, 0, NO); }] withArrow], lib, FRFirstIndex(a))];
    }
    FRPushMenu(FRT(@"Albums"), items);
}

// Plays a song, then carries on with the rest of its album
static void FRPlaySong(FRLibrary *lib, NSUInteger idx) {
    NSNumber *key = [NSNumber numberWithUnsignedInteger:idx];
    NSString *artist = [lib.artists objectAtIndex:idx - 1];
    for (FRGroup *a in [lib.albumsByArtist objectForKey:artist]) {
        NSUInteger pos = [a.idxs indexOfObject:key];
        if (pos != NSNotFound) { FRPlayGroup(a.idxs, (NSInteger)pos, NO); return; }
    }
    FRPlayGroup([NSArray arrayWithObject:key], 0, NO);
}

static void FRShowSongs(FRLibrary *lib) {
    NSArray *names = lib.names;
    NSArray *order = lib.songOrder;
    NSMutableArray *items = [NSMutableArray arrayWithCapacity:[order count]];
    for (NSNumber *num in order) {
        NSUInteger idx = [num unsignedIntegerValue];
        NSString *t = [NSString stringWithFormat:@"%@ — %@", [names objectAtIndex:idx - 1], [lib.artists objectAtIndex:idx - 1]];
        [items addObject:FRArt([FRMenuItem itemWithTitle:t action:^{ FRPlaySong(lib, idx); }], lib, idx)];
    }
    FRPushMenu(FRT(@"Songs"), items);
}

static void FRShuffleAll(FRLibrary *lib) {
    NSMutableArray *all = FRShuffled(FRRange([lib.names count]));
    if ([all count] > 500) [all removeObjectsInRange:NSMakeRange(500, [all count] - 500)];
    FRPlayGroup(all, 0, NO);
}

#pragma mark - Queue screen

static NSString *FREntryLabel(NSDictionary *e) {
    NSString *n = [e objectForKey:@"n"], *a = [e objectForKey:@"a"];
    return [a length] ? [NSString stringWithFormat:@"%@ — %@", n, a] : n;
}

static void FRShowQueue(void) {
    FRQueue *q = [FRQueue shared];
    if ([q.entries count] == 0) {
        FRShowMessage([NSArray arrayWithObjects:FRT(@"Queue is empty"), FRT(@"Play something from Artists, Albums or Playlists"), nil]);
        return;
    }
    NSMutableArray *items = [NSMutableArray arrayWithCapacity:[q.entries count]];
    for (NSUInteger i = 0; i < [q.entries count]; i++) {
        NSInteger target = (NSInteger)i;
        NSString *label = FREntryLabel([q.entries objectAtIndex:i]);
        if ((NSInteger)i == q.position) label = [@"▶ " stringByAppendingString:label];
        FRMenuItem *item = [FRMenuItem itemWithTitle:label action:^{
            FRQueuePlayIndex(target);
            FRPushNowPlaying();
        }];
        NSDictionary *e = [q.entries objectAtIndex:i];
        if ([[e objectForKey:@"i"] integerValue] > 0)
            [item withArtIndex:[[e objectForKey:@"i"] integerValue] key:FRArtKey([e objectForKey:@"a"], [e objectForKey:@"b"])];
        [items addObject:item];
    }
    FRMenuScreen *m = [[[FRMenuScreen alloc] initWithTitle:FRT(@"Queue") items:items] autorelease];
    m.icon = @"music";
    m.selectedIndex = MAX(0, q.position);
    [m reload];
    [[FRController shared] push:m];
}

#pragma mark - Playlists

static NSString *FRPlaylistSource(NSString *name) {
    return [NSString stringWithFormat:@"playlist \"%@\"", FRQuote(name)];
}

static void FRPlayPlaylist(NSString *name, NSArray *names, NSArray *artists, NSInteger start, BOOL shuffle) {
    NSInteger st = start;
    NSArray *list = FRPlayIndices(FRRange([names count]), &st, shuffle, 1500, FRPlaylistSource(name));
    if (!list) return;
    NSMutableArray *entries = [NSMutableArray arrayWithCapacity:[list count]];
    for (NSNumber *num in list) {
        NSUInteger i = [num unsignedIntegerValue] - 1;
        NSString *ar = (i < [artists count]) ? [artists objectAtIndex:i] : @"";
        [entries addObject:[NSDictionary dictionaryWithObjectsAndKeys:
            [names objectAtIndex:i], @"n", ar, @"a", @"", @"b", nil]];
    }
    [[FRQueue shared] replaceWith:entries position:st];
    if ((NSUInteger)st < [entries count]) FRNoteEntry([entries objectAtIndex:(NSUInteger)st]);
    FRPushNowPlaying();
}

static void FRShowPlaylist(NSString *name) {
    NSString *src = [NSString stringWithFormat:
        @"tell application \"iTunes\"\n"
        @"set p to playlist \"%@\"\n"
        @"set n to count of tracks of p\n"
        @"if n is 0 then return {{}, {}}\n"
        @"if n > 1500 then set n to 1500\n"
        @"return {name of (tracks 1 thru n of p), artist of (tracks 1 thru n of p)}\n"
        @"end tell", FRQuote(name)];

    FRController *c = [FRController shared];
    id<FRScreen> loading = [[[FRInfoScreen alloc] initWithLines:[NSArray arrayWithObject:FRT(@"Loading…")]] autorelease];
    [c push:loading];
    FRRunAsync(src, ^(NSAppleEventDescriptor *d, NSString *err) {
        if ([c topScreen] != loading) return;   // the user went back meanwhile
        [c pop];
        NSArray *names = [NSArray array], *artists = [NSArray array];
        if (d && [d numberOfItems] >= 2) {
            names = FRStrings([d descriptorAtIndex:1]);
            artists = FRStrings([d descriptorAtIndex:2]);
        }
        NSMutableArray *items = [NSMutableArray array];
        if ([names count] == 0) {
            [items addObject:[FRMenuItem itemWithTitle:FRT(@"(Empty playlist or iTunes unavailable)") action:nil]];
        } else {
            [items addObject:[FRMenuItem itemWithTitle:FRT(@"Play Playlist") action:^{ FRPlayPlaylist(name, names, artists, 0, NO); }]];
            [items addObject:[FRMenuItem itemWithTitle:FRT(@"Shuffle") action:^{ FRPlayPlaylist(name, names, artists, 0, YES); }]];
            for (NSUInteger i = 0; i < [names count]; i++) {
                NSInteger start = (NSInteger)i;
                [items addObject:[FRMenuItem itemWithTitle:[names objectAtIndex:i]
                                                    action:^{ FRPlayPlaylist(name, names, artists, start, NO); }]];
            }
        }
        FRPushMenu(name, items);
    });
}

static void FRShowPlaylists(void) {
    FRController *c = [FRController shared];
    id<FRScreen> loading = [[[FRInfoScreen alloc] initWithLines:[NSArray arrayWithObject:FRT(@"Loading…")]] autorelease];
    [c push:loading];
    FRRunAsync(@"tell application \"iTunes\" to return name of playlists", ^(NSAppleEventDescriptor *d, NSString *err) {
        if ([c topScreen] != loading) return;   // the user went back meanwhile
        [c pop];
        NSArray *names = d ? FRStrings(d) : [NSArray array];
        NSMutableArray *items = [NSMutableArray array];
        for (NSString *n in names) {
            if ([n isEqualToString:kTempPlaylist]) continue;
            [items addObject:[[FRMenuItem itemWithTitle:n action:^{ FRShowPlaylist(n); }] withArrow]];
        }
        if ([items count] == 0)
            [items addObject:[FRMenuItem itemWithTitle:FRT(@"(No playlists or iTunes unavailable)") action:nil]];
        FRPushMenu(FRT(@"Playlists"), items);
    });
}

#pragma mark - Music menu

FRMenuScreen *FRBuildMusicMenu(void) {
    NSArray *items = @[
        [FRMenuItem itemWithTitle:FRT(@"Now Playing") action:^{ FRPushNowPlaying(); }],
        [[FRMenuItem itemWithTitle:FRT(@"Queue")     action:^{ FRShowQueue(); }] withArrow],
        [[FRMenuItem itemWithTitle:FRT(@"Artists")   action:^{ FRWithLibrary(^(FRLibrary *lib) { FRShowArtists(lib); }); }] withArrow],
        [[FRMenuItem itemWithTitle:FRT(@"Albums")    action:^{ FRWithLibrary(^(FRLibrary *lib) { FRShowAlbums(lib); }); }] withArrow],
        [[FRMenuItem itemWithTitle:FRT(@"Songs")     action:^{ FRWithLibrary(^(FRLibrary *lib) { FRShowSongs(lib); }); }] withArrow],
        [[FRMenuItem itemWithTitle:FRT(@"Playlists") action:^{ FRShowPlaylists(); }] withArrow],
        [FRMenuItem itemWithTitle:FRT(@"Shuffle All") action:^{ FRWithLibrary(^(FRLibrary *lib) { FRShuffleAll(lib); }); }],
        [FRMenuItem itemWithTitle:FRT(@"Refresh Library") action:^{
            [[FRLibrary shared] invalidate];
            FRInvalidateVideoLibrary();
            FRInvalidateArtwork();
            FRWithLibrary(^(FRLibrary *lib) {
                FRShowMessageTimed([NSArray arrayWithObjects:FRT(@"Library refreshed"),
                               FRTF(@"%lu songs", (unsigned long)[lib.names count]), nil], 3.0);
            });
        }]
    ];
    FRMenuScreen *m = [[[FRMenuScreen alloc] initWithTitle:FRT(@"Music") items:items] autorelease];
    m.icon = @"music";
    return m;
}

static NSInteger gVolPending = 0;
static BOOL gVolBusy = NO;

// Volume changes are accumulated and sent one script at a time: holding the button never builds a backlog
static void FRVolumeFlush(void) {
    if (gVolBusy || gVolPending == 0) return;
    NSInteger delta = gVolPending;
    gVolPending = 0;
    gVolBusy = YES;
    NSString *src = [NSString stringWithFormat:
        @"tell application \"iTunes\"\n"
        @"set v to (sound volume) + (%ld)\n"
        @"if v > 100 then set v to 100\n"
        @"if v < 0 then set v to 0\n"
        @"set sound volume to v\n"
        @"end tell", (long)delta];
    FRRunAsync(src, ^(NSAppleEventDescriptor *d, NSString *err) {
        gVolBusy = NO;
        FRVolumeFlush();
    });
}

static void FRVolumeStep(NSInteger delta) {
    gVolPending = MAX(-100, MIN(100, gVolPending + delta));
    FRVolumeFlush();
}

void FRTogglePlayback(void) {
    FRRunVoid(@"tell application \"iTunes\" to playpause");
}

#pragma mark - Now Playing screen

static NSString *FRStateLabel(NSString *st) {
    NSString *l = [st lowercaseString];
    if ([l isEqualToString:@"playing"]) return FRT(@"▶ Playing");
    if ([l isEqualToString:@"paused"]) return FRT(@"❚❚ Paused");
    if ([l isEqualToString:@"stopped"]) return FRT(@"■ Stopped");
    return st ? st : @"";
}

@implementation FRNowPlayingScreen {
    FRInfoView *_view;
    NSTimer *_timer;
    NSString *_lastName;      // song currently displayed
    NSString *_artName;       // song whose artwork was requested
    NSString *_lastErr;
    NSInteger _failures;
    NSInteger _tick;
    BOOL _forceScript;
    BOOL _scriptBusy;
    // hold ▶ / ◀: scrub inside the song
    BOOL _seeking;
    BOOL _seekBusy;
    NSInteger _seekDir;
    NSInteger _seekTicks;
    NSTimer *_seekTimer;
}

- (id)init {
    self = [super init];
    if (self) {
        _view = [[FRInfoView alloc] initWithFrame:NSMakeRect(0, 0, 100, 100)];
        [_view setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    }
    return self;
}

- (void)dealloc {
    [_timer invalidate];
    [_seekTimer invalidate];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_view release];
    [_lastName release];
    [_artName release];
    [_lastErr release];
    [super dealloc];
}

- (NSView *)view { return _view; }

- (void)screenWillAppear {
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(trackChanged:)
                                                 name:@"FRNowPlayingChanged" object:nil];
    _forceScript = YES;
    [self refresh];
    _timer = [NSTimer scheduledTimerWithTimeInterval:2.0 target:self selector:@selector(refresh) userInfo:nil repeats:YES];
}

- (void)screenDidDisappear {
    [self endSeek];
    [_timer invalidate];
    _timer = nil;
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)trackChanged:(NSNotification *)n {
    _forceScript = YES;
    [self refresh];
}

#pragma mark Hold ▶ / ◀ : scrub inside the song

// Instead of iTunes' fast-forward/rewind commands (which keep going until a "resume" arrives, and drift
// when the interface lags), we move the playback position ourselves in small steps while the button is
// held. At most one step is in flight, so nothing piles up: stopping is immediate and exact.
- (void)beginSeek:(BOOL)forward {
    [self endSeek];
    _seeking = YES;
    _seekDir = forward ? 1 : -1;
    _seekTicks = 0;
    _seekTimer = [NSTimer scheduledTimerWithTimeInterval:0.25 target:self selector:@selector(seekTick) userInfo:nil repeats:YES];
    [self seekTick];
}

- (void)seekTick {
    if (!_seeking) return;
    _seekTicks++;
    if (_seekTicks > 100) { [self endSeek]; return; }   // safety: about 25 s without a release
    if (_seekBusy) return;                               // the previous step is not finished yet
    _seekBusy = YES;
    NSInteger step = (_seekTicks < 8) ? 3 : (_seekTicks < 20 ? 6 : 12);   // accelerates the longer you hold
    NSString *src = [NSString stringWithFormat:
        @"tell application \"iTunes\"\n"
        @"try\n"
        @"set p to (player position) + (%ld)\n"
        @"set d to duration of current track\n"
        @"if p > d - 1 then set p to d - 1\n"
        @"if p < 0 then set p to 0\n"
        @"set player position to p\n"
        @"end try\n"
        @"end tell", (long)(_seekDir * step)];
    FRRunAsync(src, ^(NSAppleEventDescriptor *d, NSString *err) { _seekBusy = NO; });
}

- (void)endSeek {
    _seeking = NO;
    [_seekTimer invalidate];
    _seekTimer = nil;
}

#pragma mark Display

- (void)showName:(NSString *)name artist:(NSString *)artist album:(NSString *)album label:(NSString *)label {
    if ([name length] == 0) {
        name = FRT(@"Nothing playing");
        artist = @"";
        album = @"";
        label = _lastErr ? FRTF(@"iTunes unavailable — %@", _lastErr) : @"";
    }
    [_view setLines:[NSArray arrayWithObjects:name, artist, album, label, nil]];
    if (![name isEqualToString:_lastName]) {
        [_lastName release];
        _lastName = [name copy];
        [_view setImage:nil];      // the previous artwork no longer applies
    }
}

- (void)loadArtworkFor:(NSString *)name {
    if ([name length] == 0 || [name isEqualToString:_artName]) return;
    [_artName release];
    _artName = [name copy];

    // When First Row started the song from the library, its library index is known: the cover is then found
    // (and cached) exactly like in the menus. Otherwise it is read from the song iTunes is playing.
    FRQueue *q = [FRQueue shared];
    NSDictionary *e = (q.position >= 0 && q.position < (NSInteger)[q.entries count]) ? [q.entries objectAtIndex:(NSUInteger)q.position] : nil;
    NSInteger idx = ([[e objectForKey:@"i"] integerValue] > 0 && [[e objectForKey:@"n"] isEqualToString:name])
                        ? [[e objectForKey:@"i"] integerValue] : 0;
    NSString *key = (idx > 0) ? FRArtKey([e objectForKey:@"a"], [e objectForKey:@"b"]) : nil;

    FRLoadArtwork(idx, key, ^(NSImage *img) {
        if (![name isEqualToString:_artName]) return;   // the song changed meanwhile
        if (img && [name isEqualToString:_lastName]) [_view setImage:img];
    });
}

// 1) instant: info from iTunes' notification (or the last song started / remembered);
// 2) then, asynchronously and not on every tick: AppleScript, which also gives the artwork.
- (void)refresh {
    FRNowPlaying *t = [FRNowPlaying shared];
    NSString *name = t.name ? t.name : @"";
    NSString *artist = t.artist ? t.artist : @"";
    NSString *album = t.album ? t.album : @"";
    NSString *label = @"";
    if ([name length]) label = (t.live && t.state) ? FRStateLabel(t.state) : FRT(@"Last song played");
    [self showName:name artist:artist album:album label:label];
    if ([name length] && t.live) [self loadArtworkFor:name];   // the cover does not wait for the status script

    _tick++;
    BOOL tryScript = _forceScript || (_tick % 3 == 0);
    if (_failures >= 3 && !_forceScript && (_tick % 15) != 0) tryScript = NO;   // back off while it keeps failing
    _forceScript = NO;
    if (!tryScript || _scriptBusy) return;
    _scriptBusy = YES;

    FRRunAsync(@"tell application \"iTunes\"\n"
               @"if player state is stopped then return {\"\", \"\", \"\", \"stopped\"}\n"
               @"set st to \"playing\"\n"
               @"if player state is paused then set st to \"paused\"\n"
               @"try\n"
               @"return {name of current track, artist of current track, album of current track, st}\n"
               @"on error\n"
               @"return {\"\", \"\", \"\", st}\n"
               @"end try\n"
               @"end tell", ^(NSAppleEventDescriptor *d, NSString *err) {
        _scriptBusy = NO;
        if (d && [d numberOfItems] >= 4) {
            _failures = 0;
            [_lastErr release];
            _lastErr = nil;
            NSString *n = [[d descriptorAtIndex:1] stringValue];
            NSString *a = [[d descriptorAtIndex:2] stringValue];
            NSString *b = [[d descriptorAtIndex:3] stringValue];
            NSString *s = [[d descriptorAtIndex:4] stringValue];
            BOOL have = ([n length] > 0);
            NSString *nm = have ? n : name;
            [self showName:nm
                    artist:have ? (a ? a : @"") : artist
                     album:have ? (b ? b : @"") : album
                     label:s ? FRStateLabel(s) : label];
            [self loadArtworkFor:nm];
        } else {
            _failures++;
            [_lastErr release];
            _lastErr = [err copy];
            [self showName:name artist:artist album:album label:label];
        }
    });
}

- (void)handleCommand:(FRCommand)c {
    if (c == FRCommandSeekForward) { [self beginSeek:YES]; return; }
    if (c == FRCommandSeekBackward) { [self beginSeek:NO]; return; }
    if (c == FRCommandSeekEnd) { [self endSeek]; return; }
    [self endSeek];
    switch (c) {
        case FRCommandSelect:
        case FRCommandPlayPause:
            FRRunVoid(@"tell application \"iTunes\" to playpause");
            break;
        case FRCommandLeft:
            FRSkip(NO);
            break;
        case FRCommandRight:
            FRSkip(YES);
            break;
        case FRCommandUp:
            FRVolumeStep(5);
            return;                       // nothing to refresh: the volume does not change what is displayed
        case FRCommandDown:
            FRVolumeStep(-5);
            return;
        case FRCommandMenu:
            [[FRController shared] back];
            return;
        default: break;
    }
    _forceScript = YES;
    [self refresh];
}
@end
