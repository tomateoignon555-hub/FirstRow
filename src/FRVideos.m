// Movies and TV shows, read from the iTunes library (tracks whose "video kind" is movie / TV show).
//
//  Movies:   All Movies, Genres, Recently Added, Unwatched
//  TV Shows: Shows > Seasons > Episodes, Recently Added, Unwatched
//
// A local, unprotected file is played by First Row's own player (VLC for AVI/MKV...); a protected
// (store) file or one that is not on disk is played by iTunes itself.

#import "FR.h"
#import <AVFoundation/AVFoundation.h>

@interface FRVideoItem : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *show;
@property (nonatomic, copy) NSString *genre;
@property (nonatomic, copy) NSString *path;
@property (nonatomic, retain) NSDate *added;
@property (nonatomic, assign) NSInteger season, episode, year, plays, index;
@end

@implementation FRVideoItem
- (void)dealloc {
    [_name release]; [_show release]; [_genre release]; [_path release]; [_added release];
    [super dealloc];
}
@end

#pragma mark - Reading the iTunes library

static NSArray *FRVStrings(NSAppleEventDescriptor *l) {
    NSInteger n = [l numberOfItems];
    NSMutableArray *a = [NSMutableArray arrayWithCapacity:(NSUInteger)n];
    for (NSInteger i = 1; i <= n; i++) {
        NSString *s = [[l descriptorAtIndex:i] stringValue];
        [a addObject:(s ? s : @"")];
    }
    return a;
}

static NSArray *FRVInts(NSAppleEventDescriptor *l) {
    NSInteger n = [l numberOfItems];
    NSMutableArray *a = [NSMutableArray arrayWithCapacity:(NSUInteger)n];
    for (NSInteger i = 1; i <= n; i++)
        [a addObject:[NSNumber numberWithInt:(int)[[l descriptorAtIndex:i] int32Value]]];
    return a;
}

// A date descriptor ('ldt ') is a 64-bit count of seconds since 1 January 1904 (-dateValue does not exist in
// the 10.9 SDK, so it is decoded here). Only the ordering matters ("Recently Added").
static NSDate *FRDateFromDescriptor(NSAppleEventDescriptor *d) {
    NSData *data = [[d coerceToDescriptorType:(DescType)'ldt '] data];
    if ([data length] < 8) return nil;
    SInt64 secs = 0;
    [data getBytes:&secs length:8];
    return [NSDate dateWithTimeIntervalSince1970:(NSTimeInterval)(secs - 2082844800LL)];
}

// A file descriptor coerced to a file URL holds the URL as UTF-8 text (-fileURLValue is not in the 10.9 SDK either)
static NSString *FRPathFromDescriptor(NSAppleEventDescriptor *d) {
    NSData *data = [[d coerceToDescriptorType:(DescType)'furl'] data];
    if ([data length] == 0) return nil;
    NSString *s = [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease];
    return [[NSURL URLWithString:s] path];
}

// Runs on the script queue. Returns nil if iTunes cannot be read, an empty array if there are none.
static NSArray *FRLoadVideos(BOOL tv) {
    NSString *flt = [NSString stringWithFormat:@"(every track of library playlist 1 whose video kind is %@)", tv ? @"TV show" : @"movie"];
    NSMutableString *props = [NSMutableString stringWithFormat:
        @"name of %@, genre of %@, year of %@, date added of %@, played count of %@, index of %@, location of %@",
        flt, flt, flt, flt, flt, flt, flt];
    if (tv) [props appendFormat:@", show of %@, season number of %@, episode number of %@", flt, flt, flt];
    NSAppleEventDescriptor *d = FRRunErr([NSString stringWithFormat:@"tell application \"iTunes\"\nreturn {%@}\nend tell", props], NULL);
    if (!d || [d numberOfItems] < (tv ? 10 : 7)) return nil;

    NSArray *names = FRVStrings([d descriptorAtIndex:1]);
    NSArray *genres = FRVStrings([d descriptorAtIndex:2]);
    NSArray *years = FRVInts([d descriptorAtIndex:3]);
    NSAppleEventDescriptor *dates = [d descriptorAtIndex:4];
    NSArray *plays = FRVInts([d descriptorAtIndex:5]);
    NSArray *idxs = FRVInts([d descriptorAtIndex:6]);
    NSAppleEventDescriptor *locs = [d descriptorAtIndex:7];
    NSArray *shows = tv ? FRVStrings([d descriptorAtIndex:8]) : nil;
    NSArray *seasons = tv ? FRVInts([d descriptorAtIndex:9]) : nil;
    NSArray *episodes = tv ? FRVInts([d descriptorAtIndex:10]) : nil;

    NSUInteger n = [names count];
    if ([genres count] != n || [years count] != n || [plays count] != n || [idxs count] != n
        || (NSUInteger)[dates numberOfItems] != n || (NSUInteger)[locs numberOfItems] != n) return nil;
    if (tv && ([shows count] != n || [seasons count] != n || [episodes count] != n)) return nil;

    NSMutableArray *out = [NSMutableArray arrayWithCapacity:n];
    for (NSUInteger i = 0; i < n; i++) {
        FRVideoItem *v = [[[FRVideoItem alloc] init] autorelease];
        v.name = [names objectAtIndex:i];
        v.genre = [genres objectAtIndex:i];
        v.year = [[years objectAtIndex:i] integerValue];
        v.plays = [[plays objectAtIndex:i] integerValue];
        v.index = [[idxs objectAtIndex:i] integerValue];
        v.added = FRDateFromDescriptor([dates descriptorAtIndex:(NSInteger)i + 1]);
        v.path = FRPathFromDescriptor([locs descriptorAtIndex:(NSInteger)i + 1]);
        if (tv) {
            v.show = [shows objectAtIndex:i];
            v.season = [[seasons objectAtIndex:i] integerValue];
            v.episode = [[episodes objectAtIndex:i] integerValue];
        }
        [out addObject:v];
    }
    return out;
}

static NSArray *gMovies = nil;   // cache (read once; "Refresh Library" in the Music menu clears it)
static NSArray *gShows = nil;

void FRInvalidateVideoLibrary(void) {
    [gMovies release]; gMovies = nil;
    [gShows release]; gShows = nil;
}

// Loads (in the background, with a "Loading…" screen) then calls `then` on the main thread
static void FRWithVideos(BOOL tv, void (^then)(NSArray *items)) {
    NSArray *cached = tv ? gShows : gMovies;
    if (cached) { then(cached); return; }

    FRController *c = [FRController shared];
    id<FRScreen> loading = [[[FRInfoScreen alloc] initWithLines:[NSArray arrayWithObject:FRT(@"Loading videos…")]] autorelease];
    [c push:loading];
    (void)FRLanguage();

    dispatch_async(FRScriptQueue(), ^{
        NSArray *items = nil;
        @autoreleasepool { items = [FRLoadVideos(tv) retain]; }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (items) { if (tv) gShows = items; else gMovies = items; }   // cached (keeps the +1 from retain)
            if ([c topScreen] != loading) return;                             // the user went back meanwhile
            [c pop];
            if (!items) {
                FRShowMessage([NSArray arrayWithObjects:FRT(@"iTunes library unavailable"), FRT(@"Make sure iTunes contains songs"), nil]);
                return;
            }
            if ([items count] == 0) {
                FRShowMessage([NSArray arrayWithObject:FRT(tv ? @"No TV shows found in iTunes" : @"No movies found in iTunes")]);
                return;
            }
            then(items);
        });
    });
}

#pragma mark - Playing

static void FRPlayInITunes(FRVideoItem *v) {
    FRRunVoid([NSString stringWithFormat:@"tell application \"iTunes\" to play (track %ld of library playlist 1)", (long)v.index]);
    FRShowMessageTimed([NSArray arrayWithObject:FRT(@"Playing in iTunes")], 3.0);
}

static void FRPlayItem(FRVideoItem *v) {
    NSString *p = v.path;
    if ([p length] && [[NSFileManager defaultManager] fileExistsAtPath:p])
        FRPlayVideoEx(p, ^{ FRPlayInITunes(v); });     // a protected (store) file is played by iTunes itself
    else
        FRPlayInITunes(v);                             // not on this disk: iTunes plays it
}

#pragma mark - Helpers

static void FRPushVideoMenu(NSString *title, BOOL tv, NSArray *items) {
    FRMenuScreen *m = [[[FRMenuScreen alloc] initWithTitle:title items:items] autorelease];
    m.icon = tv ? @"tvshows" : @"movies";
    [[FRController shared] push:m];
}

static NSArray *FRSortedByName(NSArray *items) {
    return [items sortedArrayUsingComparator:^NSComparisonResult(id a, id b) {
        return [[a name] localizedCaseInsensitiveCompare:[b name]];
    }];
}

static NSArray *FRNewestFirst(NSArray *items) {
    return [items sortedArrayUsingComparator:^NSComparisonResult(id a, id b) {
        NSTimeInterval ta = [[a added] timeIntervalSince1970], tb = [[b added] timeIntervalSince1970];
        return ta > tb ? NSOrderedAscending : (ta < tb ? NSOrderedDescending : NSOrderedSame);
    }];
}

static NSArray *FREpisodeOrder(NSArray *items) {
    return [items sortedArrayUsingComparator:^NSComparisonResult(id a, id b) {
        FRVideoItem *x = a, *y = b;
        if (x.season != y.season) return x.season < y.season ? NSOrderedAscending : NSOrderedDescending;
        if (x.episode != y.episode) return x.episode < y.episode ? NSOrderedAscending : NSOrderedDescending;
        return [x.name localizedCaseInsensitiveCompare:y.name];
    }];
}

static NSArray *FRFirst(NSArray *items, NSUInteger n) {
    return [items count] > n ? [items subarrayWithRange:NSMakeRange(0, n)] : items;
}

static NSArray *FRUnwatched(NSArray *items) {
    NSMutableArray *out = [NSMutableArray array];
    for (FRVideoItem *v in items) if (v.plays == 0) [out addObject:v];
    return out;
}

// Group items by a string key; returns a dictionary key -> NSMutableArray
static NSDictionary *FRGroupBy(NSArray *items, BOOL byShow, NSString *unknown) {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    for (FRVideoItem *v in items) {
        NSString *k = byShow ? v.show : v.genre;
        if ([k length] == 0) k = unknown;
        NSMutableArray *l = [d objectForKey:k];
        if (!l) { l = [NSMutableArray array]; [d setObject:l forKey:k]; }
        [l addObject:v];
    }
    return d;
}

#pragma mark - Movies

static NSString *FRMovieTitle(FRVideoItem *v) {
    return v.year > 0 ? [NSString stringWithFormat:@"%@ (%ld)", v.name, (long)v.year] : v.name;
}

static void FRShowMovieList(NSString *title, NSArray *movies) {
    NSMutableArray *items = [NSMutableArray arrayWithCapacity:[movies count]];
    for (FRVideoItem *v in movies)
        [items addObject:[FRMenuItem itemWithTitle:FRMovieTitle(v) action:^{ FRPlayItem(v); }]];
    FRPushVideoMenu(title, NO, items);
}

static void FRShowGenres(NSArray *movies) {
    NSDictionary *groups = FRGroupBy(movies, NO, FRT(@"Unknown Genre"));
    NSMutableArray *items = [NSMutableArray array];
    for (NSString *g in [[groups allKeys] sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)]) {
        NSArray *list = [groups objectForKey:g];
        NSString *t = [NSString stringWithFormat:@"%@  (%lu)", g, (unsigned long)[list count]];
        [items addObject:[[FRMenuItem itemWithTitle:t action:^{ FRShowMovieList(g, FRSortedByName(list)); }] withArrow]];
    }
    FRPushVideoMenu(FRT(@"Genres"), NO, items);
}

FRMenuScreen *FRBuildMoviesMenu(void) {
    NSArray *items = @[
        [[FRMenuItem itemWithTitle:FRT(@"All Movies") action:^{
            FRWithVideos(NO, ^(NSArray *all) { FRShowMovieList(FRT(@"All Movies"), FRSortedByName(all)); });
        }] withArrow],
        [[FRMenuItem itemWithTitle:@"Genres" action:^{
            FRWithVideos(NO, ^(NSArray *all) { FRShowGenres(all); });
        }] withArrow],
        [[FRMenuItem itemWithTitle:FRT(@"Recently Added") action:^{
            FRWithVideos(NO, ^(NSArray *all) { FRShowMovieList(FRT(@"Recently Added"), FRFirst(FRNewestFirst(all), 50)); });
        }] withArrow],
        [[FRMenuItem itemWithTitle:FRT(@"Unwatched") action:^{
            FRWithVideos(NO, ^(NSArray *all) { FRShowMovieList(FRT(@"Unwatched"), FRSortedByName(FRUnwatched(all))); });
        }] withArrow]
    ];
    FRMenuScreen *m = [[[FRMenuScreen alloc] initWithTitle:FRT(@"Movies") items:items] autorelease];
    m.icon = @"movies";
    return m;
}

#pragma mark - TV shows

static void FRShowEpisodes(NSString *title, NSArray *episodes, BOOL withShowName) {
    NSMutableArray *items = [NSMutableArray arrayWithCapacity:[episodes count]];
    for (FRVideoItem *v in episodes) {
        NSString *t;
        if (withShowName) t = [NSString stringWithFormat:@"%@ — %@", v.show, v.name];
        else t = (v.episode > 0) ? [NSString stringWithFormat:@"%ld. %@", (long)v.episode, v.name] : v.name;
        [items addObject:[FRMenuItem itemWithTitle:t action:^{ FRPlayItem(v); }]];
    }
    FRPushVideoMenu(title, YES, items);
}

// One season: straight to the episodes. Several: a list of seasons first.
static void FRShowSeasons(NSString *show, NSArray *episodes) {
    NSMutableDictionary *bySeason = [NSMutableDictionary dictionary];
    for (FRVideoItem *v in episodes) {
        NSNumber *k = [NSNumber numberWithInteger:v.season];
        NSMutableArray *l = [bySeason objectForKey:k];
        if (!l) { l = [NSMutableArray array]; [bySeason setObject:l forKey:k]; }
        [l addObject:v];
    }
    if ([bySeason count] <= 1) { FRShowEpisodes(show, FREpisodeOrder(episodes), NO); return; }

    NSMutableArray *items = [NSMutableArray array];
    for (NSNumber *k in [[bySeason allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
        NSArray *list = [bySeason objectForKey:k];
        NSInteger s = [k integerValue];
        NSString *name = (s <= 0) ? FRT(@"Specials") : FRTF(@"Season %ld", (long)s);
        NSString *t = [NSString stringWithFormat:@"%@  (%lu)", name, (unsigned long)[list count]];
        [items addObject:[[FRMenuItem itemWithTitle:t action:^{
            FRShowEpisodes([NSString stringWithFormat:@"%@ — %@", show, name], FREpisodeOrder(list), NO);
        }] withArrow]];
    }
    FRPushVideoMenu(show, YES, items);
}

static void FRShowShows(NSArray *episodes) {
    NSDictionary *groups = FRGroupBy(episodes, YES, FRT(@"Unknown Show"));
    NSMutableArray *items = [NSMutableArray array];
    for (NSString *s in [[groups allKeys] sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)]) {
        NSArray *list = [groups objectForKey:s];
        NSString *t = [NSString stringWithFormat:@"%@  (%lu)", s, (unsigned long)[list count]];
        [items addObject:[[FRMenuItem itemWithTitle:t action:^{ FRShowSeasons(s, list); }] withArrow]];
    }
    FRPushVideoMenu(FRT(@"Shows"), YES, items);
}

FRMenuScreen *FRBuildTVMenu(void) {
    NSArray *items = @[
        [[FRMenuItem itemWithTitle:FRT(@"Shows") action:^{
            FRWithVideos(YES, ^(NSArray *all) { FRShowShows(all); });
        }] withArrow],
        [[FRMenuItem itemWithTitle:FRT(@"Recently Added") action:^{
            FRWithVideos(YES, ^(NSArray *all) { FRShowEpisodes(FRT(@"Recently Added"), FRFirst(FRNewestFirst(all), 50), YES); });
        }] withArrow],
        [[FRMenuItem itemWithTitle:FRT(@"Unwatched") action:^{
            FRWithVideos(YES, ^(NSArray *all) {
                FRShowEpisodes(FRT(@"Unwatched"), FRFirst(FRNewestFirst(FRUnwatched(all)), 300), YES);
            });
        }] withArrow]
    ];
    FRMenuScreen *m = [[[FRMenuScreen alloc] initWithTitle:FRT(@"TV Shows") items:items] autorelease];
    m.icon = @"tvshows";
    return m;
}
