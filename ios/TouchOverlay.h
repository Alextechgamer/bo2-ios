#import <UIKit/UIKit.h>

// On-screen controls for every game mode. The launcher owns them and reaches the
// loaded mode framework through its exported input functions, so the controls
// can change without relinking a framework.
@interface BO2TouchOverlay : UIView
// Returns nil when the framework does not export the input functions.
- (instancetype)initWithFrame:(CGRect)frame handle:(void *)handle mode:(NSString *)mode;
- (void)resetInput;
@end
