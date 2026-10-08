#import "resources.h"
#import "Oneko.h"
#import "EdgeMap.h"
#import <objc/message.h>

@interface UIScreen(Private)
- (CGRect)_referenceBounds;
- (CGFloat)_displayCornerRadius;
@end

@interface UIWindow(Private)
- (UIInterfaceOrientation)interfaceOrientation;
- (void)_rotateWindowToOrientation:(UIInterfaceOrientation)orientation
    updateStatusBar:(BOOL)updateStatusBar duration:(CGFloat)duration
    skipCallbacks:(BOOL)skipCallbacks;
@end

@interface SpringBoard : UIApplication
- (BOOL)isLocked;
- (NSSet<UIWindowScene *> *)connectedScenes;
- (UIInterfaceOrientation)activeInterfaceOrientation;
@end

@interface OnekoWindow : UIWindow
@end

@implementation OnekoWindow
- (BOOL)autorotates {
    return NO;
}
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    return NO;
}
@end

@interface OnekoViewController : UIViewController
@end

@implementation OnekoViewController
- (BOOL)shouldAutorotate {
    return NO;
}
@end

//FIXME: There has to be a better way to do this
static CGPoint TranslatePoint(CGPoint point, CGSize bounds,
    UIInterfaceOrientation from, UIInterfaceOrientation to)
{
    CGPoint ret = point;
    const CGFloat origX = point.x;
    const CGFloat origY = point.y;
    const CGFloat mirroredX = bounds.width - origX;
    const CGFloat mirroredY = bounds.height - origY;
    
    switch (from) {
        case UIInterfaceOrientationPortraitUpsideDown: switch (to) {
            case UIInterfaceOrientationPortraitUpsideDown:
                // no change
                break;
            case UIInterfaceOrientationLandscapeRight:
                ret = CGPointMake(mirroredY, origX);
                break;
            case UIInterfaceOrientationLandscapeLeft:
                ret = CGPointMake(origY, mirroredX);
                break;
            case UIInterfaceOrientationPortrait:
                ret = CGPointMake(mirroredX, mirroredY);
            default:
                break;
        }
        break;
        case UIInterfaceOrientationLandscapeRight: switch (to) {
            case UIInterfaceOrientationPortraitUpsideDown:
                ret = CGPointMake(origY, mirroredX);
                break;
            case UIInterfaceOrientationLandscapeRight:
                // no change
                break;
            case UIInterfaceOrientationLandscapeLeft:
                ret = CGPointMake(mirroredX, mirroredY);
                break;
            case UIInterfaceOrientationPortrait:
                ret = CGPointMake(mirroredY, origX);
            default:
                break;
        }
        break;
        case UIInterfaceOrientationLandscapeLeft: switch (to) {
            case UIInterfaceOrientationPortraitUpsideDown:
                ret = CGPointMake(mirroredY, origX);
                break;
            case UIInterfaceOrientationLandscapeRight:
                ret = CGPointMake(mirroredX, mirroredY);
                break;
            case UIInterfaceOrientationLandscapeLeft:
                // no change
                break;
            case UIInterfaceOrientationPortrait:
                ret = CGPointMake(origY, mirroredX);
            default:
                break;
        }
        break;
        case UIInterfaceOrientationPortrait:
        default: switch (to) {
            case UIInterfaceOrientationPortraitUpsideDown:
                ret = CGPointMake(mirroredX, mirroredY);
                break;
            case UIInterfaceOrientationLandscapeRight:
                ret = CGPointMake(origY, mirroredX);
                break;
            case UIInterfaceOrientationLandscapeLeft:
                ret = CGPointMake(mirroredY, origX);
                break;
            case UIInterfaceOrientationPortrait:
                // no change
                break;
            default:
                break;
        }
        break;
    }
    return ret;
}

static OnekoViewController *viewController;
static Oneko *neko;
static OnekoWindow *window;
static NSTimer *timer;

// Rescan the screen every this many ticks (0.125 s each), less often while the cat sleeps.
#define SCAN_INTERVAL 4
#define SCAN_INTERVAL_ASLEEP 8
// The sprites leave a few empty rows under the cat's feet.
#define FOOT_INSET 3.0
#define CAT_SIZE 32.0
// How far beside the cat (points) a wall can be for it to step over and scratch it.
#define WALL_REACH 12.0

static dispatch_queue_t scanQueue;
static BOOL scanning, scanSoon;
static unsigned scanTicks;
// Where the cat's feet are headed, always on an edge from the last scan.
static BOOL hasTarget;
static CGPoint targetFoot;
// Whether the cat scratches the edge it stands on once it gets there; picked at
// random for each new target so it doesn't happen every time.
static BOOL scratchDownHere;
// A tap sends the cat to the edge closest to it.
static BOOL touchPending;
static CGPoint touchPoint;
// With Random Edges, only a tap on the cat itself counts, and sends it to a random edge.
static BOOL touchOnCat;
// Taps this close around the cat's frame count as on it (it's a small target).
#define CAT_TAP_SLOP 8.0

// Settings > Oneko (a PreferenceLoader page), saved by the Settings app via cfprefsd.
#define PREFS_DOMAIN CFSTR("com.pixelomer.oneko")
#define PREFS_CHANGED CFSTR("com.pixelomer.oneko/changed")
// Stay at the bottom of the screen and only follow the x of taps.
static BOOL bottomOnly;
// Tapping the cat or losing its edge sends it to a random edge instead of the closest one.
static BOOL randomEdges;

static BOOL boolPref(CFStringRef key) {
    id value = CFBridgingRelease(CFPreferencesCopyAppValue(key, PREFS_DOMAIN));
    return [value respondsToSelector:@selector(boolValue)] && [value boolValue];
}

static void loadPrefs() {
    CFPreferencesAppSynchronize(PREFS_DOMAIN);
    bottomOnly = boolPref(CFSTR("BottomOnly"));
    randomEdges = boolPref(CFSTR("RandomEdges"));
}

static void prefsChanged(CFNotificationCenterRef center, void *observer, CFStringRef name,
    const void *object, CFDictionaryRef userInfo)
{
    loadPrefs();
    NSLog(@"bottomOnly = %d, randomEdges = %d", bottomOnly, randomEdges);
    hasTarget = NO;
    scanSoon = YES;
}

static void setTargetFoot(CGPoint foot) {
    if (!hasTarget || !CGPointEqualToPoint(foot, targetFoot)) {
        NSLog(@"target edge %.0f,%.0f", foot.x, foot.y);
    }
    if (!hasTarget || !CGPointEqualToPoint(foot, targetFoot)) {
        scratchDownHere = arc4random_uniform(2) == 0;
    }
    hasTarget = YES;
    targetFoot = foot;
    neko.mouseLocation = CGPointMake(foot.x, foot.y + FOOT_INSET - CAT_SIZE);
    neko.hasRestLocation = NO;
}

static void applyEdges(OnekoEdgeMap *map) {
    if (bottomOnly) {
        // Switched on while this scan was running.
        return;
    }
    CGRect frame = neko.frame;
    CGPoint foot = CGPointMake(CGRectGetMidX(frame), CGRectGetMaxY(frame) - FOOT_INSET);
    if (touchPending) {
        touchPending = NO;
        setTargetFoot(randomEdges ? [map randomFootAwayFrom:foot width:CAT_SIZE] :
            [map nearestFootTo:touchPoint width:CAT_SIZE]);
    } else if (!hasTarget || ![map hasEdgeAtFoot:targetFoot]) {
        // The edge went away (or never was): go to the next closest one, or any.
        setTargetFoot(randomEdges ? [map randomFootAwayFrom:foot width:CAT_SIZE] :
            [map nearestFootTo:foot width:CAT_SIZE]);
    }
    // The frame's top, where the paws reach when scratching up.
    CGFloat paws = targetFoot.y + FOOT_INSET - CAT_SIZE;
    // A wall beside the target, where the side-scratching paws reach (sprite rows
    // 3-12, at its very side): step over to it, if the feet stay on the edge.
    CGFloat left = [map wallFromX:targetFoot.x - CAT_SIZE / 2 direction:-1
        minY:paws + 3 maxY:paws + 12 reach:WALL_REACH];
    CGFloat right = [map wallFromX:targetFoot.x + CAT_SIZE / 2 direction:1
        minY:paws + 3 maxY:paws + 12 reach:WALL_REACH];
    OnekoScratch wall = OnekoScratchNone;
    CGFloat shift = 0;
    if (!isnan(left) && (isnan(right) || left <= right)) {
        wall = OnekoScratchLeft;
        shift = -left;
    } else if (!isnan(right)) {
        wall = OnekoScratchRight;
        shift = right;
    }
    CGPoint shifted = CGPointMake(targetFoot.x + shift, targetFoot.y);
    if (wall != OnekoScratchNone && [map hasEdgeAtFoot:shifted]) {
        if (fabs(shift) > 1) {
            setTargetFoot(shifted);
        }
        if (neko.scratchDirection != wall) {
            NSLog(@"wall %s, shift %.0f", wall == OnekoScratchLeft ? "left" : "right", shift);
        }
        neko.scratchDirection = wall;
    } else if ([map hasEdgeFromY:paws - 4 toY:paws + 4 atX:targetFoot.x]) {
        // An edge right above the target is a ceiling to scratch.
        neko.scratchDirection = OnekoScratchUp;
    } else {
        neko.scratchDirection = scratchDownHere ? OnekoScratchDown : OnekoScratchNone;
    }
}

// The display's rounded corners (~41 pt on the XR) would hide a cat standing at
// the very bottom near a side, so the bottom floor curves up with them.
static CGFloat displayCornerRadius;
// The feet reach about this far either side of the cat's center.
#define FEET_HALF_WIDTH 10.0

static CGFloat bottomFloorY(CGFloat x, CGSize size) {
    CGFloat r = displayCornerRadius;
    CGFloat d = MAX(MIN(x, size.width - x) - FEET_HALF_WIDTH, 0);
    if (d >= r) {
        return size.height;
    }
    return size.height - (r - sqrt(r * r - (r - d) * (r - d)));
}

static void followBottom() {
    CGSize size = viewController.view.bounds.size;
    CGFloat x;
    const CGFloat minX = CAT_SIZE / 2, maxX = size.width - CAT_SIZE / 2;
    if (touchPending) {
        touchPending = NO;
        x = touchPoint.x;
        // A tap closer to a side than the cat can get: scratch that wall.
        neko.scratchDirection = x < minX ? OnekoScratchLeft :
            x > maxX ? OnekoScratchRight : OnekoScratchNone;
    } else if (hasTarget && fabs(targetFoot.y - bottomFloorY(targetFoot.x, size)) < 0.5) {
        return;
    } else {
        x = CGRectGetMidX(neko.frame);
        neko.scratchDirection = OnekoScratchNone;
    }
    x = MIN(MAX(x, minX), maxX);
    setTargetFoot(CGPointMake(x, bottomFloorY(x, size)));
    // Up a corner's slope: slide down to where the floor turns flat before sleeping.
    const CGFloat flat = displayCornerRadius + FEET_HALF_WIDTH;
    CGFloat restX = MIN(MAX(x, flat), size.width - flat);
    if (restX != x) {
        neko.restLocation = CGPointMake(restX, size.height + FOOT_INSET - CAT_SIZE);
        neko.hasRestLocation = YES;
    }
}

static void startEdgeScan() {
    if (scanning) {
        return;
    }
    scanning = YES;
    scanSoon = NO;
    UIView *view = viewController.view;
    CGSize viewSize = view.bounds.size;
    CGFloat minY = MAX(view.safeAreaInsets.top, CAT_SIZE - FOOT_INSET);
    UIInterfaceOrientation orientation = [window interfaceOrientation];
    // Screenshots are in the screen's native (portrait) orientation.
    CGPoint o = TranslatePoint(CGPointZero, viewSize, orientation, UIInterfaceOrientationPortrait);
    CGPoint x = TranslatePoint(CGPointMake(1, 0), viewSize, orientation, UIInterfaceOrientationPortrait);
    CGPoint y = TranslatePoint(CGPointMake(0, 1), viewSize, orientation, UIInterfaceOrientationPortrait);
    CGAffineTransform viewToNative = CGAffineTransformMake(x.x - o.x, x.y - o.y,
        y.x - o.x, y.y - o.y, o.x, o.y);
    dispatch_async(scanQueue, ^{
#if DEBUG
        CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
#endif
        OnekoEdgeMap *map = [[OnekoEdgeMap alloc] initWithViewSize:viewSize
            viewToNative:viewToNative minY:minY];
#if DEBUG
        static int scans;
        BOOL dump = access("/var/tmp/oneko-dump", F_OK) == 0;
        if (++scans % 40 == 1 || dump) {
            NSLog(@"scan: %.1f ms, %lu edges", (CFAbsoluteTimeGetCurrent() - start) * 1000,
                (unsigned long)map.edgeCount);
        }
        if (dump) {
            [map writeDebugImageToPath:@"/var/tmp/oneko-edges.png"];
        }
#endif
        dispatch_async(dispatch_get_main_queue(), ^{
            scanning = NO;
            // A rotation since the screenshot makes it useless.
            if (map != nil && [window interfaceOrientation] == orientation) {
                applyEdges(map);
            }
        });
    });
}

// Max length (s) and movement (points) of a touch that counts as a tap.
#define TAP_MAX_DURATION 0.35
#define TAP_MAX_MOVEMENT 10.0

// A quick single-finger touch that barely moves sends the cat to the edge
// closest to it. Swipes, holds and multi-finger gestures are ignored.
static void handleTouches(UIEvent *event) {
    // SpringBoard sees each event twice (with different touch objects), so this
    // tracks one possible tap rather than a particular touch.
    static BOOL armed;
    static CGPoint tapStart;
    static NSTimeInterval tapStartTime;
    NSSet<UITouch *> *touches = [event allTouches];
    if (touches.count != 1) {
        armed = NO;
        return;
    }
    UITouch *touch = [touches anyObject];
    CGPoint point = [touch locationInView:nil];
    switch (touch.phase) {
        case UITouchPhaseBegan:
            armed = YES;
            tapStart = point;
            tapStartTime = touch.timestamp;
            break;
        case UITouchPhaseMoved:
            if (hypot(point.x - tapStart.x, point.y - tapStart.y) > TAP_MAX_MOVEMENT) {
                armed = NO;
            }
            break;
        case UITouchPhaseEnded:
            if (armed && touch.timestamp - tapStartTime <= TAP_MAX_DURATION &&
                hypot(point.x - tapStart.x, point.y - tapStart.y) <= TAP_MAX_MOVEMENT &&
                [[touch window] interfaceOrientation] == UIInterfaceOrientationPortrait)
            {
                CGSize referenceBounds = [[UIScreen mainScreen] _referenceBounds].size;
                touchPoint = TranslatePoint(tapStart, referenceBounds,
                    UIInterfaceOrientationPortrait, [window interfaceOrientation]);
                touchOnCat = CGRectContainsPoint(CGRectInset(neko.frame, -CAT_TAP_SLOP,
                    -CAT_TAP_SLOP), touchPoint);
                // With Random Edges the cat only answers taps on itself.
                if (!randomEdges || bottomOnly || touchOnCat) {
                    touchPending = YES;
                    scanSoon = YES;
                }
                NSLog(@"tap at %.0f,%.0f%s", touchPoint.x, touchPoint.y, touchOnCat ? " (cat)" : "");
            }
            armed = NO;
            break;
        case UITouchPhaseCancelled:
            armed = NO;
            break;
        default:
            break;
    }
}

static void onekoTimerTick() {
    SpringBoard *springboard = (SpringBoard *)[UIApplication sharedApplication];
    if ([springboard isLocked]) {
        neko.hidden = YES;
        return;
    }
    neko.hidden = NO;
    UIInterfaceOrientation orientation = [springboard activeInterfaceOrientation];
    if ([window interfaceOrientation] != orientation) {
        CGSize vcSize = [viewController.view bounds].size;
        UIInterfaceOrientation from = [window interfaceOrientation];
        UIInterfaceOrientation to = orientation;
        CGRect frame = neko.frame;
        frame.origin.x += frame.size.width / 2;
        frame.origin.y += frame.size.height / 2;
        frame.origin = TranslatePoint(frame.origin, vcSize, from, to);
        frame.origin.y -= frame.size.height / 2;
        neko.mouseLocation = frame.origin;
        frame.origin.x -= frame.size.width / 2;
        neko.frame = frame;
        [window _rotateWindowToOrientation:orientation updateStatusBar:NO
            duration:0 skipCallbacks:NO];
        hasTarget = NO;
        scanSoon = YES;
    }
    if (bottomOnly) {
        followBottom();
    } else if (scanSoon || ++scanTicks >= (neko.asleep ? SCAN_INTERVAL_ASLEEP : SCAN_INTERVAL)) {
        scanTicks = 0;
        startEdgeScan();
    }
    [neko handleTimer:timer];
}

%hook SpringBoard

- (void)sendEvent:(UIEvent *)event {
    if (event.type == UIEventTypeTouches) {
        handleTouches(event);
    }
    %orig;
}

- (void)applicationDidFinishLaunching:(id)application {
    %orig;

    window = [[OnekoWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    if (@available(iOS 13.0, *)) {
        window.windowScene = (id)[self connectedScenes].allObjects[0];
    }
    else {
        window.screen = [UIScreen mainScreen];
    }

    viewController = [OnekoViewController new];

    neko = [Oneko new];
    neko.userInteractionEnabled = NO;
    // Keep the cat out of screenshots (ours and the user's), so it never finds edges on itself.
    if ([neko.layer respondsToSelector:@selector(setDisableUpdateMask:)]) {
        ((void (*)(id, SEL, unsigned int))objc_msgSend)(neko.layer,
            @selector(setDisableUpdateMask:), 0x12);
    }
    [OnekoEdgeMap prepareWithScreen:[UIScreen mainScreen]];
    scanQueue = dispatch_queue_create("com.pixelomer.oneko.edges", DISPATCH_QUEUE_SERIAL);
    if ([UIScreen.mainScreen respondsToSelector:@selector(_displayCornerRadius)]) {
        displayCornerRadius = [UIScreen.mainScreen _displayCornerRadius];
    }
    NSLog(@"display corner radius %.1f", displayCornerRadius);
    loadPrefs();
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
        prefsChanged, PREFS_CHANGED, NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    [viewController.view addSubview:neko];
    
    window.rootViewController = viewController;
    window.userInteractionEnabled = YES;
    window.opaque = NO;
    window.hidden = NO;
    window.backgroundColor = [UIColor clearColor];
    window.windowLevel = CGFLOAT_MAX / 2.0;
    [window makeKeyAndVisible];

    timer = [NSTimer
        timerWithTimeInterval:0.125f
        repeats:YES
        block:^(NSTimer *timer) {
            onekoTimerTick();
        }
    ];
    [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
}

%end
