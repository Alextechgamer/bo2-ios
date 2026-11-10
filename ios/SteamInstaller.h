#import <AuthenticationServices/AuthenticationServices.h>
#import <CommonCrypto/CommonDigest.h>



static NSString *HexDigest(const unsigned char *digest) {
    NSMutableString *hex = [NSMutableString stringWithCapacity:64];
    for (int i=0;i<CC_SHA256_DIGEST_LENGTH;i++) [hex appendFormat:@"%02x",digest[i]];
    return hex;
}

static NSString *FileDigest(NSURL *url) {
    NSInputStream *input = [NSInputStream inputStreamWithURL:url];
    [input open];
    CC_SHA256_CTX hash;
    CC_SHA256_Init(&hash);
    uint8_t buffer[65536];
    NSInteger n;
    while ((n=[input read:buffer maxLength:sizeof(buffer)])>0) CC_SHA256_Update(&hash,buffer,(CC_LONG)n);
    [input close];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(digest,&hash);
    return n<0 ? nil : HexDigest(digest);
}

@interface SteamInstaller : NSObject <ASWebAuthenticationPresentationContextProviding>
@property(nonatomic,weak) UIWindow *window;
@property(nonatomic,copy) NSString *libraryOrigin;
@property(nonatomic,strong) ASWebAuthenticationSession *login;
@property(nonatomic,strong) NSURLSession *session;
@property(nonatomic,copy) void (^status)(NSString *,BOOL);
- (void)begin;
@end

@implementation SteamInstaller
- (UIWindow *)presentationAnchorForWebAuthenticationSession:(ASWebAuthenticationSession *)session { return self.window; }
- (void)report:(NSString *)message done:(BOOL)done {
    dispatch_async(dispatch_get_main_queue(), ^{
        if(done){[self.session finishTasksAndInvalidate];self.session=nil;self.login=nil;}
        self.status(message,done);
    });
}
- (NSMutableURLRequest *)request:(NSString *)path token:(NSString *)token {
    NSURL *url=[NSURL URLWithString:[self.libraryOrigin stringByAppendingString:path]];
    NSMutableURLRequest *request=[NSMutableURLRequest requestWithURL:url];
    if(token) [request setValue:[@"Bearer " stringByAppendingString:token] forHTTPHeaderField:@"Authorization"];
    return request;
}
- (void)begin {
    NSString *origin = [NSBundle.mainBundle objectForInfoDictionaryKey:@"GameLibraryOrigin"];
    NSURLComponents *url = [origin isKindOfClass:NSString.class] ? [NSURLComponents componentsWithString:origin] : nil;
    if (![url.scheme.lowercaseString isEqualToString:@"https"] || !url.host.length || url.user || url.password ||
        url.query || url.fragment || (url.path.length && ![url.path isEqualToString:@"/"])) {
        [self report:@"Configure an HTTPS game library origin to use Steam installation." done:YES];
        return;
    }
    url.path = @"";
    self.libraryOrigin = url.string;
    self.session=[NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.ephemeralSessionConfiguration];
    NSString *verifier=[NSString stringWithFormat:@"%@%@", NSUUID.UUID.UUIDString,NSUUID.UUID.UUIDString];
    NSData *bytes=[verifier dataUsingEncoding:NSASCIIStringEncoding];
    unsigned char hash[CC_SHA256_DIGEST_LENGTH];CC_SHA256(bytes.bytes,(CC_LONG)bytes.length,hash);
    [self report:@"Connecting to your private game library…" done:NO];
    NSMutableURLRequest *setup=[self request:[@"/login-url?challenge=" stringByAppendingString:HexDigest(hash)] token:nil];
    setup.timeoutInterval=10;
    [[self.session dataTaskWithRequest:setup completionHandler:^(NSData *data,NSURLResponse *response,NSError *failure){
        NSDictionary *json=data?[NSJSONSerialization JSONObjectWithData:data options:0 error:nil]:nil;
        NSString *value=[json isKindOfClass:NSDictionary.class]?json[@"url"]:nil;
        NSURL *url=[value isKindOfClass:NSString.class]?[NSURL URLWithString:value]:nil;
        if([(NSHTTPURLResponse *)response statusCode]!=200 || ![url.scheme isEqual:@"https"] ||
           ![url.host isEqual:@"steamcommunity.com"] || ![url.path isEqual:@"/openid/login"]){
            [self report:@"Could not reach your private game library. Check the connection and try again." done:YES];return;
        }
        dispatch_async(dispatch_get_main_queue(), ^{[self showSteam:url verifier:verifier];});
    }] resume];
}
- (void)showSteam:(NSURL *)loginURL verifier:(NSString *)verifier {
    self.login=[[ASWebAuthenticationSession alloc] initWithURL:loginURL callbackURLScheme:@"bo2library"
        completionHandler:^(NSURL *url,NSError *error){
            if(error || ![url.host isEqual:@"signed-in"]){[self report:@"Steam sign-in did not finish." done:YES];return;}
            NSString *code=nil;
            for(NSURLQueryItem *item in [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO].queryItems)
                if([item.name isEqual:@"code"]) code=item.value;
            if(!code.length){[self report:@"Missing Steam sign-in response." done:YES];return;}
            NSMutableURLRequest *req=[self request:@"/session" token:nil];
            req.HTTPMethod=@"POST";
            req.HTTPBody=[NSJSONSerialization dataWithJSONObject:@{@"code":code,@"verifier":verifier} options:0 error:nil];
            [[self.session dataTaskWithRequest:req completionHandler:^(NSData *data,NSURLResponse *resp,NSError *err){
                NSDictionary *obj=data?[NSJSONSerialization JSONObjectWithData:data options:0 error:nil]:nil;
                NSString *token=[obj isKindOfClass:NSDictionary.class]?obj[@"token"]:nil;
                if([(NSHTTPURLResponse *)resp statusCode]!=200 || !token.length){[self report:@"Steam authorization failed." done:YES];return;}
                [self install:token];
            }] resume];
        }];
    self.login.presentationContextProvider=self;
    if(![self.login start]) [self report:@"Could not open Steam sign-in." done:YES];
}
- (void)install:(NSString *)token {
    [[self.session dataTaskWithRequest:[self request:@"/manifest" token:token] completionHandler:^(NSData *data,NSURLResponse *resp,NSError *err){
        NSArray *files=data?[NSJSONSerialization JSONObjectWithData:data options:0 error:nil]:nil;
        if([(NSHTTPURLResponse *)resp statusCode]!=200 || ![files isKindOfClass:NSArray.class] || !files.count){
            [self report:@"Could not read your game library." done:YES];return;
        }
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0), ^{
            NSFileManager *fm=NSFileManager.defaultManager;
            NSURL *support=[fm URLForDirectory:NSApplicationSupportDirectory inDomain:NSUserDomainMask appropriateForURL:nil create:YES error:nil];
            NSURL *installed=[support URLByAppendingPathComponent:@"BO2GameFiles"];
            BOOL existing=[fm fileExistsAtPath:installed.path];
            NSURL *root=existing?installed:[support URLByAppendingPathComponent:@"BO2GameFiles.partial"];
            NSUInteger idx=0;
            for(NSDictionary *row in files) { @autoreleasepool {
                NSString *name=row[@"name"];
                if(![name isKindOfClass:NSString.class] || name.isAbsolutePath || [name.pathComponents containsObject:@".."]){
                    [self report:@"Invalid library file name." done:YES];return;
                }
                NSURL *target=[root URLByAppendingPathComponent:name];
                [self report:[NSString stringWithFormat:@"Checking %lu of %lu · %@",(unsigned long)++idx,(unsigned long)files.count,name.lastPathComponent] done:NO];
                if([fm fileExistsAtPath:target.path] && [FileDigest(target) isEqual:row[@"sha256"]]) continue;
                NSError *directoryError=nil;
                if(![fm createDirectoryAtURL:target.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:&directoryError]){
                    [self report:directoryError.localizedDescription done:YES];return;
                }
                dispatch_semaphore_t finished=dispatch_semaphore_create(0);
                __block BOOL saved=NO;
                NSMutableURLRequest *req=[self request:[NSString stringWithFormat:@"/files/%@",row[@"id"]] token:token];
                [[self.session downloadTaskWithRequest:req completionHandler:^(NSURL *tmp,NSURLResponse *reply,NSError *failure){
                    if(tmp && [(NSHTTPURLResponse *)reply statusCode]==200 && [FileDigest(tmp) isEqual:row[@"sha256"]]){
                        if([fm fileExistsAtPath:target.path]) saved=[fm replaceItemAtURL:target withItemAtURL:tmp backupItemName:nil options:0 resultingItemURL:nil error:nil];
                        else saved=[fm moveItemAtURL:tmp toURL:target error:nil];
                    }
                    dispatch_semaphore_signal(finished);
                }] resume];
                dispatch_semaphore_wait(finished,DISPATCH_TIME_FOREVER);
                if(!saved){[self report:[NSString stringWithFormat:@"Could not install %@. Sign in again to resume.",name] done:YES];return;}
            }}
            NSError *error=nil;
            if(!existing && ![fm moveItemAtURL:root toURL:installed error:&error]){[self report:error.localizedDescription done:YES];return;}
            [self report:@"Game files verified. Choose a mode to play." done:YES];
        });
    }] resume];
}
@end
