#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface BO2SteamSignIn : NSObject
+ (void)presentFromViewController:(UIViewController *)presenter;
+ (void)presentLibraryFromViewController:(UIViewController *)presenter;
+ (nullable NSString *)accountName;
@end

@interface BO2SteamLaunch : NSObject
@property(nonatomic, readonly) NSString *gameDirectory;
- (BOOL)installInHandle:(void *)handle;
- (void)finish;
@end

@interface BO2SteamRuntime : NSObject
+ (void)prepareMode:(NSString *)mode assets:(NSURL *)assets legacySteamID:(uint64_t)legacySteamID
        completion:(void (^)(BO2SteamLaunch * _Nullable, NSError * _Nullable))completion;
@end

NS_ASSUME_NONNULL_END
