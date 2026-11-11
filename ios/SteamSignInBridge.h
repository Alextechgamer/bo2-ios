#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface BO2SteamSignIn : NSObject
+ (void)presentFromViewController:(UIViewController *)presenter;
+ (void)presentLibraryFromViewController:(UIViewController *)presenter;
+ (nullable NSString *)accountName;
@end

// Downloads the signed-in account's own game files from Steam's content servers.
@interface BO2GameDownload : NSObject
@property(class, nonatomic, readonly, getter=isRunning) BOOL running;
// The block runs on the main queue; done is YES for the last message of a run.
+ (void)startWithStatus:(void (^)(NSString *text, BOOL done))status;
+ (void)cancel;
@end

@interface BO2SteamLaunch : NSObject
@property(nonatomic, readonly) NSString *gameDirectory;
@property(nonatomic, readonly) NSString *personaName;
- (BOOL)installInHandle:(void *)handle;
- (void)finish;
@end

@interface BO2SteamRuntime : NSObject
+ (void)prepareMode:(NSString *)mode assets:(NSURL *)assets legacySteamID:(uint64_t)legacySteamID
        completion:(void (^)(BO2SteamLaunch * _Nullable, NSError * _Nullable))completion;
@end

NS_ASSUME_NONNULL_END
