// Album covers. Music is still played by iTunes; only the pictures are looked up here, in this order:
//   1. iTunes' own artwork (AppleScript: "data of artwork 1")
//   2. the picture embedded in the song file (ID3 / MP4 tags, read with AVFoundation)
//   3. a cover.jpg / folder.jpg / front.jpg ... next to the file
// Everything happens in the background; results are cached per album (artist + album).

#import "FR.h"
#import <AVFoundation/AVFoundation.h>
#import <ApplicationServices/ApplicationServices.h>

static NSCache *gArtCache = nil;                 // key -> NSImage, or NSNull when the album has no cover
static NSMutableDictionary *gArtPending = nil;   // key -> blocks waiting for the same cover (main thread only)

static void FRArtInit(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gArtCache = [[NSCache alloc] init];
        [gArtCache setCountLimit:50];
        gArtPending = [[NSMutableDictionary alloc] init];
    });
}

NSString *FRArtKey(NSString *artist, NSString *album) {
    return [NSString stringWithFormat:@"%@\x1F%@", artist ? artist : @"", album ? album : @""];
}

BOOL FRArtworkIsCached(NSString *key) {
    FRArtInit();
    return key && [gArtCache objectForKey:key] != nil;
}

void FRInvalidateArtwork(void) {
    FRArtInit();
    [gArtCache removeAllObjects];
}

// Decodes picture data at a size that is enough for the screen (covers can be 1400 px or more)
static NSImage *FRImageFromData(NSData *data) {
    if ([data length] < 100) return nil;
    NSImage *img = nil;
    CGImageSourceRef src = CGImageSourceCreateWithData((CFDataRef)data, NULL);
    if (src && CGImageSourceGetCount(src) > 0) {
        NSDictionary *opts = [NSDictionary dictionaryWithObjectsAndKeys:
            (id)kCFBooleanTrue, (id)kCGImageSourceCreateThumbnailFromImageAlways,
            (id)kCFBooleanTrue, (id)kCGImageSourceCreateThumbnailWithTransform,
            [NSNumber numberWithInt:512], (id)kCGImageSourceThumbnailMaxPixelSize, nil];
        CGImageRef cg = CGImageSourceCreateThumbnailAtIndex(src, 0, (CFDictionaryRef)opts);
        if (cg) {
            img = [[[NSImage alloc] initWithCGImage:cg size:NSZeroSize] autorelease];
            CGImageRelease(cg);
        }
    }
    if (src) CFRelease(src);
    if (!img) img = [[[NSImage alloc] initWithData:data] autorelease];   // formats ImageIO does not handle
    return img;
}

// A cover.jpg / folder.jpg ... in the song's folder
static NSImage *FRFolderImage(NSString *songPath) {
    NSString *dir = [songPath stringByDeletingLastPathComponent];
    NSArray *names = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil];
    NSArray *wanted = [NSArray arrayWithObjects:@"cover", @"folder", @"front", @"album", @"albumart", @"artwork", @"thumb", nil];
    NSArray *exts = [NSArray arrayWithObjects:@"jpg", @"jpeg", @"png", nil];
    for (NSString *w in wanted) {
        for (NSString *n in names) {
            if (![[[n stringByDeletingPathExtension] lowercaseString] isEqualToString:w]) continue;
            if (![exts containsObject:[[n pathExtension] lowercaseString]]) continue;
            NSImage *img = FRImageFromData([NSData dataWithContentsOfFile:[dir stringByAppendingPathComponent:n]]);
            if (img) return img;
        }
    }
    return nil;
}

// The picture embedded in the song file, then the folder picture. `done` is called on a background thread.
static void FRArtworkFromFile(NSString *path, void (^done)(NSImage *img)) {
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:path] options:nil];
    [asset loadValuesAsynchronouslyForKeys:[NSArray arrayWithObject:@"commonMetadata"] completionHandler:^{
        NSImage *img = nil;
        @autoreleasepool {
            NSArray *items = [AVMetadataItem metadataItemsFromArray:[asset commonMetadata]
                                                            withKey:AVMetadataCommonKeyArtwork
                                                           keySpace:AVMetadataKeySpaceCommon];
            for (AVMetadataItem *it in items) {
                id v = [it value];
                NSData *data = nil;
                if ([v isKindOfClass:[NSData class]]) data = (NSData *)v;
                else if ([v isKindOfClass:[NSDictionary class]]) data = [(NSDictionary *)v objectForKey:@"data"];
                img = FRImageFromData(data);
                if (img) break;
            }
            if (!img) img = FRFolderImage(path);
            [img retain];
        }
        done(img);
        [img release];
    }];
}

// libraryIndex > 0: song number `libraryIndex` of the library (the cover is cached under `key`);
// libraryIndex == 0: the song iTunes is playing right now (not cached).
// `done` is always called on the main thread (immediately if the cover is already cached).
void FRLoadArtwork(NSInteger libraryIndex, NSString *key, void (^done)(NSImage *image)) {
    FRArtInit();
    if (key) {
        id hit = [gArtCache objectForKey:key];
        if (hit) { done([hit isKindOfClass:[NSImage class]] ? (NSImage *)hit : nil); return; }
        NSMutableArray *waiting = [gArtPending objectForKey:key];
        if (waiting) { [waiting addObject:[[done copy] autorelease]]; return; }   // the same cover is already being loaded
        [gArtPending setObject:[NSMutableArray arrayWithObject:[[done copy] autorelease]] forKey:key];
    }

    // runs on the main thread
    void (^finish)(NSImage *) = ^(NSImage *img) {
        if (!img) NSLog(@"First Row: no cover found for %@",
                        key ? [key stringByReplacingOccurrencesOfString:@"\x1F" withString:@" — "] : @"the current song");
        NSArray *waiters;
        if (key) {
            [gArtCache setObject:(img ? (id)img : (id)[NSNull null]) forKey:key];
            waiters = [[[gArtPending objectForKey:key] retain] autorelease];
            [gArtPending removeObjectForKey:key];
        } else {
            waiters = [NSArray arrayWithObject:done];
        }
        for (id w in waiters) ((void (^)(NSImage *))w)(img);
    };

    NSString *track = (libraryIndex > 0) ? [NSString stringWithFormat:@"track %ld of library playlist 1", (long)libraryIndex]
                                         : @"current track";
    NSString *src = [NSString stringWithFormat:
        @"tell application \"iTunes\"\n"
        @"set t to %@\n"
        @"set art to missing value\n"
        @"set p to \"\"\n"
        @"try\nset art to data of artwork 1 of t\nend try\n"
        @"try\nset p to POSIX path of (location of t)\nend try\n"
        @"return {art, p}\n"
        @"end tell", track];

    FRRunAsync(src, ^(NSAppleEventDescriptor *d, NSString *err) {
        NSData *artData = nil;
        NSString *path = nil;
        if (d && [d numberOfItems] >= 2) {
            artData = [[d descriptorAtIndex:1] data];
            path = [[d descriptorAtIndex:2] stringValue];
        }
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            NSImage *img = FRImageFromData(artData);                       // 1. iTunes' artwork
            if (img || [path length] == 0) {
                dispatch_async(dispatch_get_main_queue(), ^{ finish(img); });
                return;
            }
            FRArtworkFromFile(path, ^(NSImage *fileImg) {                  // 2. embedded picture, 3. folder picture
                dispatch_async(dispatch_get_main_queue(), ^{ finish(fileImg); });
            });
        });
    });
}
