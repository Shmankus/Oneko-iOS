#import "EdgeMap.h"
#import <IOSurface/IOSurfaceRef.h>
#import <dlfcn.h>

// Sum of the RGB differences (0-765) above which two pixels count as different colors.
#define EDGE_THRESHOLD 48
// Both sides of an edge must stay this uniform for a few rows, which rules out text.
#define FLAT_THRESHOLD 32
// Shortest edge worth standing on, in points. Keeps text and noise out.
#define EDGE_MIN_LENGTH 40
// Pixels that may break a run without ending it (antialiasing, dotted lines).
#define EDGE_MAX_GAP 2
// How far (points) the cat may be from an edge and still be standing on it.
#define EDGE_TOLERANCE 3
// Upper bound on stored edges, in case the screen is all noise.
#define EDGE_MAX_COUNT 8192

typedef struct {
    int16_t y, x0, x1;
} OnekoEdge;

// Pixels of a screenshot in native orientation, with the byte offsets of the
// most significant byte of each color component.
typedef struct {
    const uint8_t *base;
    size_t width, height, bytesPerRow, bytesPerPixel;
    int r, g, b;
    CGFloat scale; // pixels per point
} OnekoPixels;

static CGSize nativePixelSize;
static CGFloat nativeScale;

static inline int ColorDistance(const uint8_t *a, const uint8_t *b) {
    return abs(a[0] - b[0]) + abs(a[1] - b[1]) + abs(a[2] - b[2]);
}

@implementation OnekoEdgeMap {
    uint8_t *_pixels; // one RGBX pixel per point of the view
    int _width, _height;
    NSMutableData *_edges;
}

+ (void)prepareWithScreen:(UIScreen *)screen {
    nativePixelSize = screen.nativeBounds.size;
    nativeScale = screen.nativeScale;
}

- (instancetype)initWithViewSize:(CGSize)size
    viewToNative:(CGAffineTransform)viewToNative
    minY:(CGFloat)minY
{
    if ((self = [super init])) {
        _width = (int)size.width;
        _height = (int)size.height;
        if (_width < 8 || _height < 8) {
            return nil;
        }
        // One pixel per point: plenty for finding edges and 4x less work than native.
        _pixels = malloc((size_t)_width * _height * 4);
        if (![self captureRenderServer:viewToNative] && ![self captureUIKit:viewToNative]) {
            return nil;
        }
        _edges = [NSMutableData new];
        [self scanFromY:(int)ceil(minY)];
    }
    return self;
}

- (void)dealloc {
    free(_pixels);
}

#pragma mark - Capture

// Byte offset of the pixel under view point (x, y), clamped to the image.
static inline size_t PixelOffset(const OnekoPixels *src, CGAffineTransform t, int x, int y) {
    CGPoint p = CGPointApplyAffineTransform(CGPointMake(x + 0.5, y + 0.5), t);
    size_t px = (size_t)MIN(MAX(p.x, 0), src->width - 1);
    size_t py = (size_t)MIN(MAX(p.y, 0), src->height - 1);
    return py * src->bytesPerRow + px * src->bytesPerPixel;
}

// Copies the pixel under each point of the view into _pixels.
- (void)sample:(const OnekoPixels *)src viewToNative:(CGAffineTransform)viewToNative {
    const CGAffineTransform t = CGAffineTransformConcat(viewToNative,
        CGAffineTransformMakeScale(src->scale, src->scale));
    // Rotations by 90 degrees keep each native coordinate a function of only one
    // view coordinate, so offsets split into a column part plus a row part.
    size_t *columns = malloc(_width * sizeof(size_t)), *rows = malloc(_height * sizeof(size_t));
    const size_t origin = PixelOffset(src, t, 0, 0);
    for (int x = 0; x < _width; x++) {
        columns[x] = PixelOffset(src, t, x, 0) - origin;
    }
    for (int y = 0; y < _height; y++) {
        rows[y] = PixelOffset(src, t, 0, y);
    }
    const int r = src->r, g = src->g, b = src->b;
    uint8_t *out = _pixels;
    for (int y = 0; y < _height; y++) {
        const uint8_t *row = src->base + rows[y];
        for (int x = 0; x < _width; x++, out += 4) {
            const uint8_t *pixel = row + columns[x];
            out[0] = pixel[r];
            out[1] = pixel[g];
            out[2] = pixel[b];
            out[3] = 255;
        }
    }
    free(columns);
    free(rows);
}

// Renders the display into our own 8-bit surface: much faster to read than a
// UIKit screenshot, which comes as a 16-bit image that takes ~75 ms to copy.
- (BOOL)captureRenderServer:(CGAffineTransform)viewToNative {
    static void (*renderDisplay)(mach_port_t, CFStringRef, IOSurfaceRef, int, int);
    static IOSurfaceRef surface;
    static BOOL failed;
    if (failed) {
        return NO;
    }
    if (surface == NULL) {
        renderDisplay = dlsym(RTLD_DEFAULT, "CARenderServerRenderDisplay");
        size_t width = (size_t)nativePixelSize.width, height = (size_t)nativePixelSize.height;
        if (renderDisplay == NULL || width == 0 || height == 0) {
            NSLog(@"CARenderServerRenderDisplay unavailable");
            failed = YES;
            return NO;
        }
        surface = IOSurfaceCreate((__bridge CFDictionaryRef)@{
            (__bridge NSString *)kIOSurfaceWidth: @(width),
            (__bridge NSString *)kIOSurfaceHeight: @(height),
            (__bridge NSString *)kIOSurfaceBytesPerElement: @4,
            (__bridge NSString *)kIOSurfacePixelFormat: @((uint32_t)'BGRA'),
            (__bridge NSString *)kIOSurfaceCacheMode: @(kIOSurfaceMapCopybackCache),
        });
        if (surface == NULL) {
            failed = YES;
            return NO;
        }
    }
    // The display is opaque, so a pixel with alpha 0 afterwards means nothing was rendered.
    IOSurfaceLock(surface, 0, NULL);
    uint8_t *base = IOSurfaceGetBaseAddress(surface);
    base[3] = 0;
    IOSurfaceUnlock(surface, 0, NULL);
    renderDisplay(0, CFSTR("LCD"), surface, 0, 0);
    IOSurfaceLock(surface, kIOSurfaceLockReadOnly, NULL);
    BOOL rendered = base[3] != 0;
    if (rendered) {
        OnekoPixels src = {
            .base = base,
            .width = IOSurfaceGetWidth(surface),
            .height = IOSurfaceGetHeight(surface),
            .bytesPerRow = IOSurfaceGetBytesPerRow(surface),
            .bytesPerPixel = 4,
            .r = 2, .g = 1, .b = 0,
            .scale = nativeScale,
        };
        [self sample:&src viewToNative:viewToNative];
    }
    IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, NULL);
    if (!rendered) {
        NSLog(@"CARenderServerRenderDisplay rendered nothing, using UIKit screenshots");
        failed = YES;
    }
    return rendered;
}

- (BOOL)captureUIKit:(CGAffineTransform)viewToNative {
    static CFTypeRef (*createScreenImage)(void);
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        createScreenImage = dlsym(RTLD_DEFAULT, "_UICreateScreenUIImage");
    });
    if (createScreenImage == NULL) {
        return NO;
    }
    UIImage *screen = CFBridgingRelease(createScreenImage());
    CGImageRef image = screen.CGImage;
    if (image == NULL) {
        return NO;
    }
    const size_t bpc = CGImageGetBitsPerComponent(image);
    CGBitmapInfo info = CGImageGetBitmapInfo(image);
    if ((bpc != 8 && bpc != 16) || CGImageGetBitsPerPixel(image) != bpc * 4 ||
        (info & kCGBitmapFloatComponents))
    {
        NSLog(@"unsupported screenshot format: %zu bpc, info 0x%x", bpc, info);
        return NO;
    }
    CGImageAlphaInfo alpha = info & kCGBitmapAlphaInfoMask;
    BOOL alphaFirst = alpha == kCGImageAlphaFirst || alpha == kCGImageAlphaPremultipliedFirst ||
        alpha == kCGImageAlphaNoneSkipFirst;
    CGBitmapInfo byteOrder = info & kCGBitmapByteOrderMask;
    // The XR (iOS 17) gives 16-bit little-endian RGBX.
    int offsets[3];
    for (int c = 0; c < 3; c++) {
        int index = c + (alphaFirst ? 1 : 0);
        if (bpc == 8) {
            offsets[c] = (byteOrder == kCGBitmapByteOrder32Little) ? 3 - index : index;
        } else {
            offsets[c] = index * 2 + ((byteOrder == kCGBitmapByteOrder16Little) ? 1 : 0);
        }
    }
    CFDataRef data = CGDataProviderCopyData(CGImageGetDataProvider(image));
    if (data == NULL) {
        return NO;
    }
    OnekoPixels src = {
        .base = CFDataGetBytePtr(data),
        .width = CGImageGetWidth(image),
        .height = CGImageGetHeight(image),
        .bytesPerRow = CGImageGetBytesPerRow(image),
        .bytesPerPixel = bpc / 2,
        .r = offsets[0], .g = offsets[1], .b = offsets[2],
        .scale = screen.scale,
    };
    // Already turned like the view if it has the view's shape.
    BOOL matchesView = (screen.size.width > screen.size.height) == (_width > _height);
    [self sample:&src viewToNative:matchesView ? CGAffineTransformIdentity : viewToNative];
    CFRelease(data);
    return YES;
}

#pragma mark - Edges

- (NSUInteger)edgeCount {
    return _edges.length / sizeof(OnekoEdge);
}

- (void)addEdgeAtY:(int)y x0:(int)x0 x1:(int)x1 {
    if (self.edgeCount >= EDGE_MAX_COUNT) {
        return;
    }
    OnekoEdge edge = { (int16_t)y, (int16_t)x0, (int16_t)x1 };
    [_edges appendBytes:&edge length:sizeof(edge)];
}

- (void)scanFromY:(int)minY {
    const int stride = _width * 4;
    for (int y = MAX(minY, 4); y < _height - 3; y++) {
        // Compare two rows above the line with one below so an edge that falls
        // between two sampled rows is still found at full strength.
        const uint8_t *above = _pixels + (y - 2) * stride;
        const uint8_t *below = _pixels + (y + 1) * stride;
        const uint8_t *farAbove = _pixels + (y - 4) * stride;
        const uint8_t *farBelow = _pixels + (y + 3) * stride;
        int start = -1, last = -1;
        for (int x = 0; x < _width; x++) {
            const int i = x * 4;
            if (ColorDistance(above + i, below + i) >= EDGE_THRESHOLD &&
                ColorDistance(above + i, farAbove + i) < FLAT_THRESHOLD &&
                ColorDistance(below + i, farBelow + i) < FLAT_THRESHOLD)
            {
                if (start < 0) {
                    start = x;
                }
                last = x;
            } else if (start >= 0 && x - last > EDGE_MAX_GAP) {
                if (last - start + 1 >= EDGE_MIN_LENGTH) {
                    [self addEdgeAtY:y x0:start x1:last];
                }
                start = -1;
            }
        }
        if (start >= 0 && last - start + 1 >= EDGE_MIN_LENGTH) {
            [self addEdgeAtY:y x0:start x1:last];
        }
    }
}

- (BOOL)hasEdgeAtFoot:(CGPoint)foot {
    if (self.edgeCount == 0) {
        // Nothing to stand on but the bottom of the screen.
        return foot.y >= _height - EDGE_TOLERANCE;
    }
    const OnekoEdge *edges = _edges.bytes;
    for (NSUInteger i = 0, n = self.edgeCount; i < n; i++) {
        if (fabs(edges[i].y - foot.y) <= EDGE_TOLERANCE &&
            foot.x >= edges[i].x0 - EDGE_TOLERANCE &&
            foot.x <= edges[i].x1 + EDGE_TOLERANCE)
        {
            return YES;
        }
    }
    return NO;
}

- (BOOL)hasEdgeFromY:(CGFloat)minY toY:(CGFloat)maxY atX:(CGFloat)x {
    const OnekoEdge *edges = _edges.bytes;
    for (NSUInteger i = 0, n = self.edgeCount; i < n; i++) {
        if (edges[i].y >= minY && edges[i].y <= maxY && x >= edges[i].x0 && x <= edges[i].x1) {
            return YES;
        }
    }
    return NO;
}

- (CGFloat)wallFromX:(CGFloat)x direction:(NSInteger)direction
    minY:(CGFloat)minY maxY:(CGFloat)maxY reach:(CGFloat)reach
{
    const int y0 = MAX((int)minY, 0), y1 = MIN((int)maxY, _height - 1);
    if (_pixels == NULL || y1 < y0) {
        return NAN;
    }
    const int rows = y1 - y0 + 1;
    for (int d = -2; d <= (int)reach; d++) {
        // The wall's boundary is between columns c - 1 and c, sampled like a
        // horizontal edge turned on its side.
        const int c = (int)lround(x) + (int)direction * d;
        if (c < 4 || c > _width - 4) {
            continue;
        }
        const int far = direction < 0 ? c - 2 : c + 1;
        const int farther = direction < 0 ? c - 4 : c + 3;
        int hits = 0;
        for (int y = y0; y <= y1; y++) {
            const uint8_t *row = _pixels + y * _width * 4;
            if (ColorDistance(row + (c - 2) * 4, row + (c + 1) * 4) >= EDGE_THRESHOLD &&
                ColorDistance(row + far * 4, row + farther * 4) < FLAT_THRESHOLD)
            {
                hits++;
            }
        }
        if (hits * 10 >= rows * 8) {
            return d;
        }
    }
    return NAN;
}

- (CGPoint)nearestFootTo:(CGPoint)point width:(CGFloat)width {
    const OnekoEdge *edges = _edges.bytes;
    // Without edges the cat waits at the bottom of the screen.
    CGPoint best = CGPointMake(MIN(MAX(point.x, width / 2), _width - width / 2), _height);
    CGFloat bestDistance = CGFLOAT_MAX;
    for (NSUInteger i = 0, n = self.edgeCount; i < n; i++) {
        // Keep the whole cat on the edge when it's long enough.
        CGFloat lo = edges[i].x0 + width / 2, hi = edges[i].x1 + 1 - width / 2;
        CGFloat x = (lo > hi) ? (edges[i].x0 + edges[i].x1) / 2.0 : MIN(MAX(point.x, lo), hi);
        CGFloat dx = x - point.x, dy = edges[i].y - point.y;
        CGFloat distance = dx * dx + dy * dy;
        if (distance < bestDistance) {
            bestDistance = distance;
            best = CGPointMake(x, edges[i].y);
        }
    }
    return best;
}

- (CGPoint)randomFootAwayFrom:(CGPoint)point width:(CGFloat)width {
    const OnekoEdge *edges = _edges.bytes;
    // Pick uniformly among the edges with a spot far enough away (reservoir sampling).
    NSUInteger candidates = 0;
    CGFloat pickLo = 0, pickHi = 0, pickY = 0;
    for (NSUInteger i = 0, n = self.edgeCount; i < n; i++) {
        CGFloat lo = edges[i].x0 + width / 2, hi = edges[i].x1 + 1 - width / 2;
        if (lo > hi) {
            lo = hi = (edges[i].x0 + edges[i].x1) / 2.0;
        }
        CGFloat farX = fabs(lo - point.x) > fabs(hi - point.x) ? lo : hi;
        if (hypot(farX - point.x, edges[i].y - point.y) < width) {
            continue;
        }
        if (arc4random_uniform((uint32_t)++candidates) == 0) {
            pickLo = lo;
            pickHi = hi;
            pickY = edges[i].y;
        }
    }
    if (candidates == 0) {
        return [self nearestFootTo:point width:width];
    }
    // A random spot along it, skipping the part that's too close.
    for (int tries = 0; tries < 8; tries++) {
        CGFloat x = pickLo + (pickHi - pickLo) * arc4random_uniform(10001) / 10000.0;
        if (hypot(x - point.x, pickY - point.y) >= width) {
            return CGPointMake(x, pickY);
        }
    }
    return CGPointMake(fabs(pickLo - point.x) > fabs(pickHi - point.x) ? pickLo : pickHi, pickY);
}

#if DEBUG
- (void)writeDebugImageToPath:(NSString *)path {
    uint8_t *copy = malloc((size_t)_width * _height * 4);
    memcpy(copy, _pixels, (size_t)_width * _height * 4);
    const OnekoEdge *edges = _edges.bytes;
    for (NSUInteger i = 0, n = self.edgeCount; i < n; i++) {
        if (edges[i].y >= _height) {
            continue;
        }
        for (int x = edges[i].x0; x <= edges[i].x1; x++) {
            uint8_t *p = copy + (edges[i].y * _width + x) * 4;
            p[0] = 255; p[1] = 0; p[2] = 0;
        }
    }
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(copy, _width, _height, 8, _width * 4,
        colorSpace, kCGImageAlphaNoneSkipLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(colorSpace);
    CGImageRef cgImage = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    free(copy);
    NSData *png = UIImagePNGRepresentation([UIImage imageWithCGImage:cgImage]);
    CGImageRelease(cgImage);
    [png writeToFile:path atomically:YES];
}
#endif

@end
