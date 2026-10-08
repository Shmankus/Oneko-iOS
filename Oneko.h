#import <UIKit/UIKit.h>

typedef NS_ENUM(NSInteger, OnekoScratch) {
    OnekoScratchNone,
    OnekoScratchUp,
    OnekoScratchDown,
    OnekoScratchLeft,
    OnekoScratchRight,
};

@interface Oneko : UIView
@property (nonatomic, assign) CGPoint mouseLocation;
/* What the cat scratches (togi) after stopping, before washing itself */
@property (nonatomic, assign) OnekoScratch scratchDirection;
/* If set, the yawning cat slides here (a mouse location) before falling asleep */
@property (nonatomic, assign) BOOL hasRestLocation;
@property (nonatomic, assign) CGPoint restLocation;
@property (nonatomic, readonly, getter=isAsleep) BOOL asleep;
- (void)handleTimer:(NSTimer*)timer;
@end