#import <UIKit/UIKit.h>

// Horizontal color edges on the screen, in the cat view's coordinates. An edge
// at y means the color changes between the rows just above and below y, so a
// cat whose feet are at y stands on it.
@interface OnekoEdgeMap : NSObject

// Remembers the screen's native size. Call once on the main thread.
+ (void)prepareWithScreen:(UIScreen *)screen;

// Takes a screenshot and finds its edges (any thread, not concurrently).
// viewToNative maps the view's points to the screen's native (portrait) points;
// size is the view's bounds size. Edges above minY are ignored. nil if the screen
// can't be captured.
- (instancetype)initWithViewSize:(CGSize)size
    viewToNative:(CGAffineTransform)viewToNative
    minY:(CGFloat)minY;

// YES if an edge passes under this foot point (a few points of tolerance). The
// bottom of the view counts only while there are no edges, so the cat leaves it
// as soon as there's something to stand on.
- (BOOL)hasEdgeAtFoot:(CGPoint)foot;

// YES if an edge between minY and maxY passes over x (for a ceiling above the cat).
- (BOOL)hasEdgeFromY:(CGFloat)minY toY:(CGFloat)maxY atX:(CGFloat)x;

// Distance from x to a vertical edge (a wall) on one side (direction -1 left,
// +1 right), searched from 2 points inside x out to `reach`, that covers most of
// the rows from minY to maxY. Only the wall's far side has to be one flat color,
// so busy content on the cat's side (an icon's artwork) doesn't matter. NAN if none.
- (CGFloat)wallFromX:(CGFloat)x direction:(NSInteger)direction
    minY:(CGFloat)minY maxY:(CGFloat)maxY reach:(CGFloat)reach;

// The closest point to `point` where a cat of this width can stand on an edge,
// or the bottom of the view if there are none.
- (CGPoint)nearestFootTo:(CGPoint)point width:(CGFloat)width;

// A random place to stand on a random edge, at least `width` away from `point`
// (where the cat is now). The nearest foot if no edge has room that far away.
- (CGPoint)randomFootAwayFrom:(CGPoint)point width:(CGFloat)width;

@property (nonatomic, readonly) NSUInteger edgeCount;

#if DEBUG
// Writes the scaled screenshot with the edges drawn in red, for tuning.
- (void)writeDebugImageToPath:(NSString *)path;
#endif

@end
