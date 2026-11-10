#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface BO2SteamSignIn : NSObject
+ (void)presentFromViewController:(UIViewController *)presenter;
+ (nullable NSString *)accountName;
@end

NS_ASSUME_NONNULL_END
