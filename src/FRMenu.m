// Menus: items, view and screen (Front Row look: black background, list on the right, icon on the left).
// The selection bar slides from row to row.
//
// Performance: the gradient and the icon+reflection are rendered once into cached bitmaps;
// during the selection animation only the list area is redrawn (30 fps).

#import "FR.h"
#import <QuartzCore/QuartzCore.h>

#pragma mark - Items

@implementation FRMenuItem
+ (FRMenuItem *)itemWithTitle:(NSString *)title action:(void (^)(void))action {
    FRMenuItem *i = [[[FRMenuItem alloc] init] autorelease];
    i.title = title;
    i.action = action;
    return i;
}
+ (FRMenuItem *)itemWithTitle:(NSString *)title action:(void (^)(void))action playAction:(void (^)(void))playAction {
    FRMenuItem *i = [FRMenuItem itemWithTitle:title action:action];
    i.playAction = playAction;
    return i;
}
+ (FRMenuItem *)itemWithTitle:(NSString *)title icon:(NSString *)icon action:(void (^)(void))action {
    FRMenuItem *i = [FRMenuItem itemWithTitle:title action:action];
    i.icon = icon;
    return i;
}
+ (FRMenuItem *)headerWithTitle:(NSString *)title {
    FRMenuItem *i = [FRMenuItem itemWithTitle:title action:nil];
    i.header = YES;
    return i;
}
- (FRMenuItem *)withArrow {
    _arrow = YES;
    return self;
}
- (FRMenuItem *)withArtIndex:(NSInteger)index key:(NSString *)key {
    _artIndex = index;
    self.artKey = key;
    return self;
}
- (void)dealloc {
    [_title release];
    [_action release];
    [_playAction release];
    [_icon release];
    [_artKey release];
    [super dealloc];
}
@end

#pragma mark - Images

static NSImage *FRImage(NSString *name) {
    if (!name) return nil;
    static NSMutableDictionary *cache = nil;
    if (!cache) cache = [[NSMutableDictionary alloc] init];
    NSImage *img = [cache objectForKey:name];
    if (!img) {
        NSString *p = [[NSBundle mainBundle] pathForResource:name ofType:@"png"];
        if (!p) return nil;
        img = [[[NSImage alloc] initWithContentsOfFile:p] autorelease];
        if (!img) return nil;
        [cache setObject:img forKey:name];
    }
    return img;
}

// Icon + floor reflection (inverted copy cut into strips of decreasing opacity). Flipped context.
static void FRDrawIcon(NSImage *icon, NSRect ir) {
    [icon drawInRect:ir fromRect:NSZeroRect operation:NSCompositeSourceOver fraction:1.0 respectFlipped:YES hints:nil];
    NSGraphicsContext *gc = [NSGraphicsContext currentContext];
    CGFloat yb = NSMaxY(ir);
    int strips = 14;
    CGFloat sh = ir.size.height * 0.35 / strips;
    for (int k = 0; k < strips; k++) {
        [gc saveGraphicsState];
        NSRectClip(NSMakeRect(ir.origin.x, yb + k * sh, ir.size.width, sh));
        NSAffineTransform *t = [NSAffineTransform transform];
        [t translateXBy:0 yBy:yb];
        [t scaleXBy:1 yBy:-1];
        [t translateXBy:0 yBy:-yb];
        [t concat];
        [icon drawInRect:ir fromRect:NSZeroRect operation:NSCompositeSourceOver
                fraction:0.30 * (1.0 - (CGFloat)k / strips) respectFlipped:YES hints:nil];
        [gc restoreGraphicsState];
    }
}

// Icon + reflection, pre-rendered once per icon (256 px): the carousel only scales and blends it
static NSImage *FRIconComposite(NSString *name) {
    if (!name) return nil;
    static NSMutableDictionary *cache = nil;
    if (!cache) cache = [[NSMutableDictionary alloc] init];
    NSImage *c = [cache objectForKey:name];
    if (c) return c;
    NSImage *icon = FRImage([@"icon_" stringByAppendingString:name]);
    if (!icon) return nil;
    CGFloat side = 256;
    c = [[[NSImage alloc] initWithSize:NSMakeSize(side, side * 1.36)] autorelease];
    [c setFlipped:YES];
    [c lockFocus];
    FRDrawIcon(icon, NSMakeRect(0, 0, side, side));
    [c unlockFocus];
    [cache setObject:c forKey:name];
    return c;
}

// An album cover with its reflection, pre-rendered (the cover keeps its proportions, bottom-aligned so the reflection attaches)
static NSImage *FRCoverComposite(NSImage *cover) {
    NSSize cs = [cover size];
    if (cs.width <= 0 || cs.height <= 0) return nil;
    CGFloat side = 256, w, h;
    if (cs.width >= cs.height) { w = side; h = side * cs.height / cs.width; }
    else { h = side; w = side * cs.width / cs.height; }
    NSImage *c = [[[NSImage alloc] initWithSize:NSMakeSize(side, side * 1.36)] autorelease];
    [c setFlipped:YES];
    [c lockFocus];
    [[NSGraphicsContext currentContext] setImageInterpolation:NSImageInterpolationHigh];
    FRDrawIcon(cover, NSMakeRect((side - w) / 2, side - h, w, h));
    [c unlockFocus];
    return c;
}

// Out-of-focus look for the icons on the sides. It used to be the icon shrunk to 32 px and scaled back up, which
// showed as big blocks. Now the icon is rendered at a decent size and really blurred (three box-blur passes,
// which approximate a Gaussian blur): same amount of blur, but smooth.
#define FR_SOFT_SIZE 192      // bitmap size in pixels
#define FR_SOFT_INSET 14      // transparent margin, so the blur can spread around the icon
#define FR_SOFT_RADIUS 5

// Box blur of one line of 4-channel pixels (everything outside the line counts as transparent)
static void FRBlurLine(const uint8_t *src, uint8_t *dst, int n, int step, int r) {
    int div = 2 * r + 1;
    int sum[4] = {0, 0, 0, 0};
    for (int i = 0; i <= r && i < n; i++)
        for (int c = 0; c < 4; c++) sum[c] += src[i * step + c];
    for (int i = 0; i < n; i++) {
        for (int c = 0; c < 4; c++) dst[i * step + c] = (uint8_t)((sum[c] + div / 2) / div);
        int add = i + r + 1, sub = i - r;
        if (add < n)  for (int c = 0; c < 4; c++) sum[c] += src[add * step + c];
        if (sub >= 0) for (int c = 0; c < 4; c++) sum[c] -= src[sub * step + c];
    }
}

static void FRBoxBlur(uint8_t *data, int w, int h, int stride, int r, int passes) {
    uint8_t *tmp = (uint8_t *)malloc((size_t)stride * (size_t)h);
    if (!tmp) return;
    for (int p = 0; p < passes; p++) {
        for (int y = 0; y < h; y++) FRBlurLine(data + (size_t)y * stride, tmp + (size_t)y * stride, w, 4, r);   // horizontal
        for (int x = 0; x < w; x++) FRBlurLine(tmp + x * 4, data + x * 4, h, stride, r);                       // vertical
    }
    free(tmp);
}

static NSImage *FRSoftIcon(NSString *name) {
    if (!name) return nil;
    static NSMutableDictionary *cache = nil;
    if (!cache) cache = [[NSMutableDictionary alloc] init];
    NSImage *s = [cache objectForKey:name];
    if (s) return s;
    NSImage *icon = FRImage([@"icon_" stringByAppendingString:name]);
    if (!icon) return nil;

    NSBitmapImageRep *rep = [[[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
        pixelsWide:FR_SOFT_SIZE pixelsHigh:FR_SOFT_SIZE bitsPerSample:8 samplesPerPixel:4
        hasAlpha:YES isPlanar:NO colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:0 bitsPerPixel:0] autorelease];
    NSGraphicsContext *ctx = rep ? [NSGraphicsContext graphicsContextWithBitmapImageRep:rep] : nil;
    if (ctx) {
        memset([rep bitmapData], 0, (size_t)[rep bytesPerRow] * FR_SOFT_SIZE);
        [NSGraphicsContext saveGraphicsState];
        [NSGraphicsContext setCurrentContext:ctx];
        [ctx setImageInterpolation:NSImageInterpolationHigh];
        CGFloat inner = FR_SOFT_SIZE - 2 * FR_SOFT_INSET;
        [icon drawInRect:NSMakeRect(FR_SOFT_INSET, FR_SOFT_INSET, inner, inner) fromRect:NSZeroRect
               operation:NSCompositeSourceOver fraction:1.0];
        [ctx flushGraphics];
        [NSGraphicsContext restoreGraphicsState];
        FRBoxBlur([rep bitmapData], FR_SOFT_SIZE, FR_SOFT_SIZE, (int)[rep bytesPerRow], FR_SOFT_RADIUS, 3);
        s = [[[NSImage alloc] initWithSize:NSMakeSize(FR_SOFT_SIZE, FR_SOFT_SIZE)] autorelease];
        [s addRepresentation:rep];
    } else {
        // fallback (should not happen): the old, blocky method
        s = [[[NSImage alloc] initWithSize:NSMakeSize(32, 32)] autorelease];
        [s lockFocus];
        [[NSGraphicsContext currentContext] setImageInterpolation:NSImageInterpolationHigh];
        [icon drawInRect:NSMakeRect(0, 0, 32, 32) fromRect:NSZeroRect operation:NSCompositeSourceOver fraction:1.0];
        [s unlockFocus];
    }
    [cache setObject:s forKey:name];
    return s;
}

#pragma mark - View
//
// Layout (modelled on Front Row of the Leopard / Snow Leopard era):
//  - black background; title centred above the list, on the right half of the screen
//  - list on the right: white text, chevron on the right of submenu entries, selected row = metallic bar
//    with a blue glow
//  - on the left: main menu = icon carousel (the icons rotate when the selection changes: the selected
//    one is large with its reflection, the following ones recede to the left, out of focus);
//    submenus = the section's icon

@interface FRMenuView : NSView
@property (nonatomic, assign) FRMenuScreen *screen;
- (void)selectionDidChange;
- (void)snapSelection;
- (void)artworkChanged;
@end

@implementation FRMenuView {
    CGFloat _pos;              // animated position (in rows) of the selection bar AND of the carousel
    NSTimer *_timer;
    // geometry of the last list drawing (to invalidate only the rows the selection bar crosses)
    CGFloat _dTop, _dRowH, _dX, _dW;
    NSInteger _dFirst, _dVisible;
    NSImage *_coverComposite;      // cover + reflection of the selected item, when it has one
}

- (BOOL)isFlipped { return YES; }

- (void)dealloc {
    [_timer invalidate];
    [_coverComposite release];
    [super dealloc];
}

// The selected item's cover arrived (or went away): redraw the left part of the screen
- (void)artworkChanged {
    [_coverComposite release];
    NSImage *a = [_screen artwork];
    _coverComposite = a ? [FRCoverComposite(a) retain] : nil;
    [self setNeedsDisplayInRect:[self carouselRect]];
}

- (void)drawCoverComposite {
    NSRect b = [self bounds];
    CGFloat side = b.size.height * 0.46, cx = b.size.width * 0.28, bottom = b.size.height * 0.68;
    [[NSGraphicsContext currentContext] setImageInterpolation:NSImageInterpolationHigh];
    [_coverComposite drawInRect:NSMakeRect(cx - side / 2, bottom - side, side, side * 1.36) fromRect:NSZeroRect
                      operation:NSCompositeSourceOver fraction:1.0 respectFlipped:YES hints:nil];
}

- (void)snapSelection {
    _pos = (CGFloat)[_screen selectedIndex];
    [self setNeedsDisplay:YES];
}

// The area covered by the list (rows + scroll arrows)
- (NSRect)listRectForBounds:(NSRect)b {
    CGFloat W = b.size.width, H = b.size.height, rowH = H * 0.066;
    return NSMakeRect(W * 0.52 - 14, H * 0.23 - rowH, W * 0.40 + 28, (H * 0.95 - H * 0.23) + 2 * rowH);
}

- (void)selectionDidChange {
    // only the list (scrolling) and, in the main menu, the carousel change: no need to repaint the whole screen
    NSRect r = [self listRectForBounds:[self bounds]];
    if ([_screen iconLayout]) r = NSUnionRect(r, [self carouselRect]);
    [self setNeedsDisplayInRect:r];
    if (!_timer)
        _timer = [NSTimer scheduledTimerWithTimeInterval:1.0 / 30.0 target:self selector:@selector(step) userInfo:nil repeats:YES];
}

- (NSRect)carouselRect {
    NSRect b = [self bounds];
    return NSMakeRect(0, b.size.height * 0.04, b.size.width * 0.54, b.size.height * 0.92);
}

- (void)step {
    CGFloat target = (CGFloat)[_screen selectedIndex];
    CGFloat prev = _pos;
    _pos += (target - _pos) * 0.40;
    if (fabs(target - _pos) < 0.01) {
        _pos = target;
        [_timer invalidate];
        _timer = nil;
    }
    if (_dRowH <= 0) { [self setNeedsDisplay:YES]; return; }
    // only the rows between the previous and the new bar position, plus the carousel, are redrawn
    CGFloat lo = MAX((CGFloat)_dFirst, MIN(prev, _pos));
    CGFloat hi = MIN((CGFloat)(_dFirst + _dVisible - 1), MAX(prev, _pos));
    if (hi < lo) hi = lo;
    NSInteger r0 = (NSInteger)floor(lo) - _dFirst, r1 = (NSInteger)ceil(hi) - _dFirst;
    NSRect r = NSMakeRect(_dX - 14, _dTop + r0 * _dRowH - 6, _dW + 28, (r1 - r0 + 1) * _dRowH + 12);
    if ([_screen iconLayout]) r = NSUnionRect(r, [self carouselRect]);
    [self setNeedsDisplayInRect:r];
}

// One icon of the carousel. rel = distance from the selection: 0 = selected, 1 = next item (recedes to the
// left), negative = previous item (leaves to the right, fading quickly).
- (void)drawIconNamed:(NSString *)name rel:(CGFloat)rel {
    NSRect b = [self bounds];
    CGFloat W = b.size.width, H = b.size.height;
    CGFloat a = fabs(rel);
    CGFloat alpha = (rel >= 0) ? MAX(0.0, 1.0 - 0.28 * rel) : MAX(0.0, 1.0 - 1.3 * a);
    if (alpha < 0.02) return;
    CGFloat dir = (rel >= 0) ? -1.0 : 1.0;
    CGFloat dx = 0.16 * W * MIN(a, 1.0) + 0.10 * W * MAX(0.0, MIN(a - 1.0, 1.0)) + 0.05 * W * MAX(0.0, a - 2.0);
    CGFloat s = (a <= 1.0) ? 1.0 - 0.55 * a : MAX(0.3, 0.45 - 0.05 * (a - 1.0));
    CGFloat side = H * 0.46 * s;
    CGFloat cx = W * 0.28 + dir * dx;
    CGFloat bottom = H * 0.68 - H * 0.25 * MIN(a, 1.0) - H * 0.04 * MAX(0.0, MIN(a - 1.0, 1.0));   // farther = higher
    CGFloat mix = MIN(1.0, a * 1.6);                                                                    // 0 sharp ... 1 blurred

    [[NSGraphicsContext currentContext] setImageInterpolation:NSImageInterpolationHigh];
    if (mix < 0.98) {
        NSImage *c = FRIconComposite(name);
        if (c) [c drawInRect:NSMakeRect(cx - side / 2, bottom - side, side, side * 1.36) fromRect:NSZeroRect
                   operation:NSCompositeSourceOver fraction:alpha * (1.0 - mix) respectFlipped:YES hints:nil];
    }
    if (mix > 0.02) {
        NSImage *soft = FRSoftIcon(name);
        if (soft) {
            // the bitmap has a transparent margin: draw it a little larger so the icon keeps its size
            CGFloat big = side * FR_SOFT_SIZE / (FR_SOFT_SIZE - 2.0 * FR_SOFT_INSET);
            [soft drawInRect:NSMakeRect(cx - big / 2, bottom - side / 2 - big / 2, big, big) fromRect:NSZeroRect
                   operation:NSCompositeSourceOver fraction:alpha * mix respectFlipped:YES hints:nil];
        }
    }
}

- (void)drawCarousel {
    NSArray *items = [_screen items];
    NSInteger n = (NSInteger)[items count];
    if (n == 0) return;
    NSInteger lo = MAX(0, (NSInteger)floor(_pos) - 2), hi = MIN(n - 1, (NSInteger)ceil(_pos) + 4);
    NSInteger order[16];
    CGFloat rels[16];
    int cnt = 0;
    for (NSInteger i = lo; i <= hi && cnt < 16; i++) { order[cnt] = i; rels[cnt] = (CGFloat)i - _pos; cnt++; }
    for (int i = 1; i < cnt; i++) {   // farthest first, so the selected icon is drawn on top
        NSInteger oi = order[i];
        CGFloat ri = rels[i];
        int j = i - 1;
        while (j >= 0 && fabs(rels[j]) < fabs(ri)) { order[j + 1] = order[j]; rels[j + 1] = rels[j]; j--; }
        order[j + 1] = oi;
        rels[j + 1] = ri;
    }
    for (int i = 0; i < cnt; i++) {
        NSString *ic = [(FRMenuItem *)[items objectAtIndex:order[i]] icon];
        if (ic) [self drawIconNamed:ic rel:rels[i]];
    }
}

- (void)drawChevronAtX:(CGFloat)cx centerY:(CGFloat)cy size:(CGFloat)s selected:(BOOL)sel {
    NSBezierPath *p = [NSBezierPath bezierPath];
    [p moveToPoint:NSMakePoint(cx - s * 0.35, cy - s * 0.55)];
    [p lineToPoint:NSMakePoint(cx + s * 0.25, cy)];
    [p lineToPoint:NSMakePoint(cx - s * 0.35, cy + s * 0.55)];
    [p setLineWidth:sel ? s * 0.30 : s * 0.22];
    [p setLineCapStyle:NSRoundLineCapStyle];
    [p setLineJoinStyle:NSRoundLineJoinStyle];
    [[NSColor colorWithCalibratedWhite:sel ? 1.0 : 0.82 alpha:1] setStroke];
    [p stroke];
}

- (void)drawTitle:(NSRect)b dirty:(NSRect)dirty {
    CGFloat W = b.size.width, H = b.size.height;
    CGFloat size = H * 0.053;
    NSRect tr = NSMakeRect(W * 0.52, H * 0.167 - size * 0.75, W * 0.40, size * 1.5);
    if (!NSIntersectsRect(tr, dirty)) return;
    NSMutableParagraphStyle *ps = [[[NSMutableParagraphStyle alloc] init] autorelease];
    [ps setAlignment:NSCenterTextAlignment];
    [ps setLineBreakMode:NSLineBreakByTruncatingTail];
    NSDictionary *ta = @{ NSFontAttributeName: [NSFont boldSystemFontOfSize:size],
                          NSForegroundColorAttributeName: [NSColor whiteColor],
                          NSParagraphStyleAttributeName: ps };
    NSString *title = [_screen title] ? [_screen title] : @"";
    [title drawInRect:tr withAttributes:ta];
}

// The list: white text, chevrons, metallic selection bar with a blue glow that slides between rows
- (void)drawList:(NSRect)b dirty:(NSRect)dirty {
    CGFloat W = b.size.width, H = b.size.height;
    CGFloat rowH = H * 0.066, top = H * 0.23, bottom = H * 0.95;
    CGFloat x = W * 0.52, w = W * 0.40;
    if (!NSIntersectsRect([self listRectForBounds:b], dirty)) return;

    NSArray *items = [_screen items];
    NSInteger n = (NSInteger)[items count];
    NSInteger sel = [_screen selectedIndex];
    if (n == 0) return;

    NSInteger visible = MAX(1, (NSInteger)((bottom - top) / rowH));
    NSInteger first = MAX(0, MIN(sel - visible / 2, n - visible));
    _dFirst = first; _dVisible = visible; _dTop = top; _dRowH = rowH; _dX = x; _dW = w;

    NSMutableParagraphStyle *ps = [[[NSMutableParagraphStyle alloc] init] autorelease];
    [ps setAlignment:NSLeftTextAlignment];
    [ps setLineBreakMode:NSLineBreakByTruncatingTail];
    NSMutableParagraphStyle *cps = [[[NSMutableParagraphStyle alloc] init] autorelease];
    [cps setAlignment:NSCenterTextAlignment];

    // shared by all the rows: built once per draw, heights from the font metrics (no per-row measuring)
    NSFont *fontSel = [NSFont boldSystemFontOfSize:rowH * 0.60];
    NSFont *fontNorm = [NSFont systemFontOfSize:rowH * 0.60];
    NSFont *fontHead = [NSFont boldSystemFontOfSize:rowH * 0.44];
    CGFloat hSel = ceil([fontSel ascender] - [fontSel descender]);
    CGFloat hNorm = ceil([fontNorm ascender] - [fontNorm descender]);
    CGFloat hHead = ceil([fontHead ascender] - [fontHead descender]);
    NSDictionary *attrSel = @{ NSFontAttributeName: fontSel, NSForegroundColorAttributeName: [NSColor whiteColor], NSParagraphStyleAttributeName: ps };
    NSDictionary *attrNorm = @{ NSFontAttributeName: fontNorm, NSForegroundColorAttributeName: [NSColor colorWithCalibratedWhite:0.96 alpha:1], NSParagraphStyleAttributeName: ps };
    NSDictionary *attrHead = @{ NSFontAttributeName: fontHead, NSForegroundColorAttributeName: [NSColor colorWithCalibratedWhite:0.55 alpha:1], NSParagraphStyleAttributeName: ps };

    // selection bar: blue glow, metallic grey fill, thin blue edge
    static NSGradient *barGradient = nil;
    if (!barGradient) {
        barGradient = [[NSGradient alloc] initWithColorsAndLocations:
            [NSColor colorWithCalibratedWhite:0.50 alpha:1], 0.0,
            [NSColor colorWithCalibratedWhite:0.74 alpha:1], 0.45,
            [NSColor colorWithCalibratedWhite:0.34 alpha:1], 1.0, nil];
    }
    CGFloat p = MAX((CGFloat)first, MIN((CGFloat)(first + visible - 1), _pos));
    NSRect bar = NSInsetRect(NSMakeRect(x, top + (p - first) * rowH, w, rowH), 0, rowH * 0.05);
    NSBezierPath *bp = [NSBezierPath bezierPathWithRoundedRect:bar xRadius:rowH * 0.12 yRadius:rowH * 0.12];
    NSColor *blue = [NSColor colorWithCalibratedRed:0.25 green:0.55 blue:1.0 alpha:1];
    NSGraphicsContext *gc = [NSGraphicsContext currentContext];
    [gc saveGraphicsState];
    NSShadow *glow = [[[NSShadow alloc] init] autorelease];
    [glow setShadowColor:[NSColor colorWithCalibratedRed:0.2 green:0.5 blue:1.0 alpha:0.95]];
    [glow setShadowBlurRadius:rowH * 0.30];
    [glow setShadowOffset:NSZeroSize];
    [glow set];
    [blue setStroke];
    [bp setLineWidth:rowH * 0.05];
    [bp stroke];
    [gc restoreGraphicsState];
    [barGradient drawInBezierPath:bp angle:90];
    [blue setStroke];
    [bp setLineWidth:rowH * 0.03];
    [bp stroke];

    CGFloat inset = rowH * 0.45;
    for (NSInteger i = 0; i < visible && first + i < n; i++) {
        NSInteger idx = first + i;
        FRMenuItem *it = [items objectAtIndex:idx];
        NSRect row = NSMakeRect(x, top + i * rowH, w, rowH);
        NSString *s = [it title] ? [it title] : @"";

        if ([it header]) {   // separator row (e.g. "Disc 2"): small dim label + thin line
            [s drawInRect:NSMakeRect(row.origin.x + inset, row.origin.y + (rowH - hHead) / 2 + rowH * 0.1, row.size.width - 2 * inset, hHead)
           withAttributes:attrHead];
            [[NSColor colorWithCalibratedWhite:1 alpha:0.18] set];
            NSRectFill(NSMakeRect(row.origin.x + inset, row.origin.y + rowH - 3, row.size.width - 2 * inset, 1));
            continue;
        }

        BOOL isSel = (idx == sel);
        CGFloat th = isSel ? hSel : hNorm;
        CGFloat padR = [it arrow] ? rowH * 1.1 : inset;
        [s drawInRect:NSMakeRect(row.origin.x + inset, row.origin.y + (rowH - th) / 2, row.size.width - inset - padR, th)
       withAttributes:isSel ? attrSel : attrNorm];
        if ([it arrow])
            [self drawChevronAtX:NSMaxX(row) - rowH * 0.55 centerY:NSMidY(row) size:rowH * 0.32 selected:isSel];
    }

    NSDictionary *arrow = @{ NSFontAttributeName: [NSFont systemFontOfSize:rowH * 0.35],
                             NSForegroundColorAttributeName: [NSColor colorWithCalibratedWhite:0.7 alpha:1],
                             NSParagraphStyleAttributeName: cps };
    if (first > 0)
        [@"▲" drawInRect:NSMakeRect(x, top - rowH * 0.62, w, rowH * 0.5) withAttributes:arrow];
    if (first + visible < n)
        [@"▼" drawInRect:NSMakeRect(x, top + visible * rowH + rowH * 0.05, w, rowH * 0.5) withAttributes:arrow];
}

- (void)drawRect:(NSRect)dirty {
    NSRect b = [self bounds];
    NSGraphicsContext *gc = [NSGraphicsContext currentContext];
    [gc saveGraphicsState];
    NSRectClip(dirty);
    [[NSColor blackColor] set];
    NSRectFill(dirty);

    if (NSIntersectsRect([self carouselRect], dirty)) {
        if ([_screen iconLayout]) [self drawCarousel];
        else if (_coverComposite) [self drawCoverComposite];
        else if ([_screen icon]) [self drawIconNamed:[_screen icon] rel:0];
    }
    [self drawTitle:b dirty:dirty];
    [self drawList:b dirty:dirty];
    [gc restoreGraphicsState];
}
@end

#pragma mark - Screen

@implementation FRMenuScreen {
    FRMenuView *_view;
    NSString *_artworkKey;     // key of the cover currently shown / being shown
}

- (NSInteger)selectableFrom:(NSInteger)start step:(NSInteger)step {
    NSInteger n = (NSInteger)[_items count];
    for (NSInteger i = start; i >= 0 && i < n; i += step)
        if (![(FRMenuItem *)[_items objectAtIndex:i] header]) return i;
    return -1;
}

- (id)initWithTitle:(NSString *)title items:(NSArray *)items {
    self = [super init];
    if (self) {
        _title = [title copy];
        _items = [items retain];
        _view = [[FRMenuView alloc] initWithFrame:NSMakeRect(0, 0, 100, 100)];
        [_view setScreen:self];
        [_view setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
        _selectedIndex = MAX(0, [self selectableFrom:0 step:1]);   // skip leading separators
        [_view snapSelection];
    }
    return self;
}

- (void)dealloc {
    [NSObject cancelPreviousPerformRequestsWithTarget:self];
    [_view setScreen:nil];
    [_view release];
    [_artwork release];
    [_artworkKey release];
    [_title release];
    [_items release];
    [_icon release];
    [super dealloc];
}

- (NSView *)view { return _view; }

- (void)setArtwork:(NSImage *)a {
    if (a == _artwork) return;
    [a retain];
    [_artwork release];
    _artwork = a;
    [_view artworkChanged];
}

// Album cover of the selected item (items opt in with artIndex / artKey). The section icon is shown until it arrives.
- (void)updateArtwork {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(fetchArtwork) object:nil];
    NSInteger n = (NSInteger)[_items count];
    FRMenuItem *it = (n > 0 && _selectedIndex < n) ? [_items objectAtIndex:_selectedIndex] : nil;
    NSString *key = ([it artIndex] > 0) ? [it artKey] : nil;
    if (!key) {
        [_artworkKey release];
        _artworkKey = nil;
        self.artwork = nil;
        return;
    }
    if ([key isEqualToString:_artworkKey]) return;      // same album: the cover stays
    if (FRArtworkIsCached(key)) { [self fetchArtwork]; return; }
    [_artworkKey release];
    _artworkKey = nil;
    self.artwork = nil;
    [self performSelector:@selector(fetchArtwork) withObject:nil afterDelay:0.15];
}

- (void)fetchArtwork {
    NSInteger n = (NSInteger)[_items count];
    FRMenuItem *it = (n > 0 && _selectedIndex < n) ? [_items objectAtIndex:_selectedIndex] : nil;
    if ([it artIndex] <= 0 || ![it artKey]) return;
    NSString *key = [[[it artKey] copy] autorelease];
    NSInteger sel = _selectedIndex;
    FRLoadArtwork([it artIndex], key, ^(NSImage *img) {
        if (_selectedIndex != sel) return;               // the selection moved on meanwhile
        [_artworkKey release];
        _artworkKey = [key copy];
        self.artwork = img;                              // nil = no cover found: the section icon stays
    });
}

- (void)screenWillAppear { [self updateArtwork]; }
- (void)screenDidDisappear { [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(fetchArtwork) object:nil]; }

- (void)reload {
    NSInteger n = (NSInteger)[_items count];
    if (_selectedIndex >= n) _selectedIndex = MAX(0, n - 1);
    if (n > 0 && [(FRMenuItem *)[_items objectAtIndex:_selectedIndex] header]) {
        NSInteger j = [self selectableFrom:_selectedIndex step:1];
        if (j < 0) j = [self selectableFrom:_selectedIndex step:-1];
        if (j >= 0) _selectedIndex = j;
    }
    [_view snapSelection];
    [self updateArtwork];
}

- (void)runAction:(void (^)(void))a {
    if (a) {
        [FRSound play:@"SelectionChange"];
        a();
    }
}

- (void)handleCommand:(FRCommand)c {
    NSInteger n = (NSInteger)[_items count];
    switch (c) {
        case FRCommandUp: {
            NSInteger j = [self selectableFrom:_selectedIndex - 1 step:-1];
            if (j >= 0) { _selectedIndex = j; [FRSound play:@"Selection"]; [_view selectionDidChange]; [self updateArtwork]; }
            else [FRSound play:@"Limit"];
            break;
        }
        case FRCommandDown: {
            NSInteger j = [self selectableFrom:_selectedIndex + 1 step:1];
            if (j >= 0) { _selectedIndex = j; [FRSound play:@"Selection"]; [_view selectionDidChange]; [self updateArtwork]; }
            else [FRSound play:@"Limit"];
            break;
        }
        case FRCommandSelect:
        case FRCommandRight:
            if (n > 0) [self runAction:[(FRMenuItem *)[_items objectAtIndex:_selectedIndex] action]];
            break;
        case FRCommandPlayPause:
            break;   // handled globally by the controller (play/pause of the playing media)
        case FRCommandLeft:
            if ([[FRController shared] canGoBack]) [[FRController shared] back];
            break;
        case FRCommandMenu:
            [[FRController shared] back];
            break;
        default: break;   // hold-to-seek commands only matter in Now Playing
    }
}
@end
