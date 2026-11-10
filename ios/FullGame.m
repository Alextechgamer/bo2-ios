#import <UIKit/UIKit.h>
#import "SteamInstaller.h"
#import "SteamSignInBridge.h"
#include <dlfcn.h>
#include <unistd.h>
#include <arpa/inet.h>
#include <sys/socket.h>
#include <poll.h>
#include <ifaddrs.h>

static NSDictionary<NSString *,NSString *> *Modes(void) {
    return @{@"sps":@"Campaign", @"mps":@"Multiplayer", @"zms":@"Zombies"};
}

static NSDictionary *ServerInfo(const void *bytes, size_t length, NSString *nonce) {
    if (length<4 || memcmp(bytes,"\xff\xff\xff\xff",4)) return nil;
    NSString *reply=[[NSString alloc] initWithBytes:(const char *)bytes+4 length:length-4 encoding:NSISOLatin1StringEncoding];
    NSArray *fields=[reply componentsSeparatedByString:@"\\"];
    if (![fields.firstObject hasPrefix:@"infoResponse"]) return nil;
    NSMutableDictionary *info=[NSMutableDictionary new];
    for (NSUInteger j=1; j+1<fields.count; j+=2) info[fields[j]]=fields[j+1];
    return [info[@"challenge"] isEqual:nonce] ? info : nil;
}

static NSDictionary *WiredServerInfo(uint16_t port, NSString *nonce) {
    int listener=socket(AF_INET,SOCK_STREAM,0);
    if (listener<0) return nil;
    int one=1;
    setsockopt(listener,SOL_SOCKET,SO_REUSEADDR,&one,sizeof(one));
    struct sockaddr_in local={.sin_len=sizeof(local),.sin_family=AF_INET,
                              .sin_port=htons(19469),.sin_addr={htonl(INADDR_LOOPBACK)}};
    struct pollfd pfd={.fd=listener,.events=POLLIN};
    int client=-1;
    if (!bind(listener,(struct sockaddr *)&local,sizeof(local)) && !listen(listener,1) && poll(&pfd,1,10000)>0)
        client=accept(listener,NULL,NULL);
    close(listener);
    if (client<0) return nil;
    struct timeval timeout={.tv_sec=3};
    setsockopt(client,SOL_SOCKET,SO_RCVTIMEO,&timeout,sizeof(timeout));
    setsockopt(client,SOL_SOCKET,SO_NOSIGPIPE,&one,sizeof(one));
    NSData *request=[[NSString stringWithFormat:@"%u %@\n",(unsigned)port,nonce] dataUsingEncoding:NSASCIIStringEncoding];
    NSMutableData *reply=[NSMutableData new];
    if (send(client,request.bytes,request.length,0)==(ssize_t)request.length) {
        char buffer[2048];
        while (reply.length<8192) {
            ssize_t n=recv(client,buffer,sizeof(buffer),0);
            if (n<=0) break;
            [reply appendBytes:buffer length:n];
        }
    }
    close(client);
    return ServerInfo(reply.bytes,reply.length,nonce);
}

// Launch arguments such as "-BO2ConnectDelay 80" override the default waits.
static NSTimeInterval Delay(NSString *key, NSTimeInterval fallback) {
    double value=[NSUserDefaults.standardUserDefaults doubleForKey:key];
    return value>=5 && value<=600 ? value : fallback;
}

static uint32_t ClientState(void *handle, BOOL mp) {
    uint8_t **arena=dlsym(handle,"bo2_g_base");
    const uint8_t *base=arena ? *arena : NULL;
    if (!base) return UINT32_MAX;
    uint32_t value; memcpy(&value,base+(mp?0x10e9d88:0x10e7e18),sizeof(value));
    return value;
}

// The frontend can still be loading when the first connect is queued. Repeat
// it only while the client connection state has not moved at all.
static void QueueConnect(void *handle, void (*queue)(const char *), NSString *command, BOOL mp, unsigned retries) {
    uint32_t before=ClientState(handle,mp);
    queue(command.UTF8String);
    if (!retries || before==UINT32_MAX) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,15*NSEC_PER_SEC),dispatch_get_main_queue(),^{
        if (ClientState(handle,mp)!=before) return;
        NSLog(@"Private connect left the client state at %u, retrying",before);
        QueueConnect(handle,queue,command,mp,retries-1);
    });
}

static void ConfigureRuntime(NSString *mode) {
    // Keep the upstream play_steam.sh execution settings. The desktop launcher
    // also enables named input pipes; UIKit sends events directly to the queue.
    NSDictionary *settings = @{
        @"BO2_WINDOW":@"1", @"BO2_WINDOW_HOLD":@"0", @"BO2_STALL_ABORT":@"0",
        @"BO2_MAX_IMPORTS":@"0", @"BO2_TR_CACHE":@"0", @"BO2_MUTE":@"0", @"BO2_XAUDIO":@"1",
        @"BO2_DEPTH_BIAS":@"1", @"BO2_DEPTH_DSV":@"1", @"BO2_SV_INLINE":@"1",
        @"BO2_NO_FORCE_MAP":@"1", @"BO2_MSGB":@"150", @"BO2_VB_RESIDENT":@"1",
        @"BO2_VPX_NATIVE":@"1", @"BO2_VPX_REPLACE":@"1", @"BO2_W32_FAST":@"1",
        @"BO2_PREEMPT_W":@"20000", @"BO2_CS_COOP":@"1", @"BO2_RR_FAIR":@"1",
        @"BO2_REAL_MUTEX":@"1", @"BO2_HOST_THREADS":@"jq,snd,snddec,srv,backend", @"BO2_HW_ATOMICS":@"2"
    };
    for (NSString *key in settings) setenv(key.UTF8String, [settings[key] UTF8String], 1);
    if ([mode isEqualToString:@"sps"]) {
        setenv("BO2_MIP_CIBLES", "0", 1);
    } else {
        setenv("BO2_SHADER_CREE", "1", 1);
        setenv("BO2_FFOTD_TU", [mode isEqualToString:@"zms"] ? "13" : "17", 1);
    }
}

// Keep game assets in the sealed bundle, with a writable players directory
// beside links to the immutable files. The guest sees a normal install tree.
static NSURL *GameDirectory(NSError **error) {
    NSFileManager *files = NSFileManager.defaultManager;
    NSURL *assets = [NSBundle.mainBundle.resourceURL URLByAppendingPathComponent:@"Game"];
    NSURL *support = [files URLForDirectory:NSApplicationSupportDirectory inDomain:NSUserDomainMask
                           appropriateForURL:nil create:YES error:error];
    if (!support) return nil;
    if (![assets checkResourceIsReachableAndReturnError:nil]) {
        assets = [support URLByAppendingPathComponent:@"BO2GameFiles"];
        if (![assets checkResourceIsReachableAndReturnError:nil]) {
            if (error) *error = [NSError errorWithDomain:@"BO2" code:1 userInfo:@{
                NSLocalizedDescriptionKey:@"Sign in with Steam to install your game files."
            }];
            return nil;
        }
    }
    NSArray<NSURL *> *entries = [files contentsOfDirectoryAtURL:assets includingPropertiesForKeys:nil options:0 error:error];
    if (!entries) return nil;
    NSURL *root = [support URLByAppendingPathComponent:@"BO2"];
    if (![files createDirectoryAtURL:[root URLByAppendingPathComponent:@"players"] withIntermediateDirectories:YES
                           attributes:nil error:error]) return nil;
    for (NSURL *entry in entries) {
        if ([entry.lastPathComponent.lowercaseString isEqualToString:@"players"]) continue;
        NSURL *link = [root URLByAppendingPathComponent:entry.lastPathComponent];
        // iOS may assign a fresh bundle path on update. Replace stale links only.
        NSString *old = [files destinationOfSymbolicLinkAtPath:link.path error:nil];
        if ([old isEqualToString:entry.path]) continue;
        if (old && ![files removeItemAtURL:link error:error]) return nil;
        if (![files createSymbolicLinkAtURL:link withDestinationURL:entry error:error]) return nil;
    }
    return root;
}

@interface ModePicker : UIViewController
@end
@implementation ModePicker {
    UIStackView *_menu;
    UILabel *_status;
    SteamInstaller *_installer;
    UIButton *_steamAccount;
    BO2SteamLaunch *_steamLaunch;
    BOOL _started;
    BOOL _checking;
    NSString *_server;
    uint16_t _port;
    BOOL _wired;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.blackColor;
    _menu = [UIStackView new];
    _menu.axis = UILayoutConstraintAxisVertical;
    _menu.spacing = 8;
    _menu.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_menu];
    UILabel *title = [UILabel new];
    title.text = @"Black Ops II";
    title.textColor = UIColor.whiteColor;
    title.font = [UIFont preferredFontForTextStyle:UIFontTextStyleLargeTitle];
    [_menu addArrangedSubview:title];
    for (NSString *mode in @[@"sps",@"mps",@"zms"]) {
        UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
        button.configuration = UIButtonConfiguration.tintedButtonConfiguration;
        [button setTitle:Modes()[mode] forState:UIControlStateNormal];
        button.accessibilityIdentifier = mode;
        [button addTarget:self action:@selector(choose:) forControlEvents:UIControlEventTouchUpInside];
        [_menu addArrangedSubview:button];
    }
    UIButton *join = [UIButton buttonWithType:UIButtonTypeSystem];
    join.configuration = UIButtonConfiguration.filledButtonConfiguration;
    [join setTitle:@"Join Private Server" forState:UIControlStateNormal];
    [join addTarget:self action:@selector(pickServer) forControlEvents:UIControlEventTouchUpInside];
    [_menu addArrangedSubview:join];
    _steamAccount=[UIButton buttonWithType:UIButtonTypeSystem];
    _steamAccount.accessibilityIdentifier=@"steam-account";
    [_steamAccount addTarget:self action:@selector(steamAccount) forControlEvents:UIControlEventTouchUpInside];
    [_menu addArrangedSubview:_steamAccount];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(updateSteamAccount:)
        name:@"BO2SteamSignInDidChange" object:nil];
    [self updateSteamAccount:nil];
    UIButton *steam=[UIButton buttonWithType:UIButtonTypeSystem];
    [steam setTitle:@"Install or verify game files" forState:UIControlStateNormal];
    [steam addTarget:self action:@selector(steamInstall) forControlEvents:UIControlEventTouchUpInside];
    [_menu addArrangedSubview:steam];
    _status = [UILabel new];
    _status.textColor = UIColor.whiteColor;
    _status.numberOfLines = 0;
    [_menu addArrangedSubview:_status];
    [NSLayoutConstraint activateConstraints:@[
        [_menu.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [_menu.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [_menu.widthAnchor constraintLessThanOrEqualToAnchor:self.view.safeAreaLayoutGuide.widthAnchor multiplier:.85]
    ]];
}
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    NSString *steamMode = [NSUserDefaults.standardUserDefaults stringForKey:@"BO2RequestedSteamMode"];
    if (Modes()[steamMode ?: @""] && !_started && !_checking) {
        [NSUserDefaults.standardUserDefaults removeObjectForKey:@"BO2RequestedSteamMode"];
        [self startSteam:steamMode];
        return;
    }
    NSString *requested = [NSUserDefaults.standardUserDefaults stringForKey:@"BO2RequestedMode"];
    if (Modes()[requested ?: @""] && !_started) {
        [NSUserDefaults.standardUserDefaults removeObjectForKey:@"BO2RequestedMode"];
        [self start:requested];
    }
}
- (NSString *)savedAddress:(NSString *)mode {
    NSString *key = [@"BO2Server." stringByAppendingString:mode];
    NSString *saved = [NSUserDefaults.standardUserDefaults stringForKey:key];
    NSString *host = [NSBundle.mainBundle objectForInfoDictionaryKey:@"BO2PrivateServer"];
    return saved ?: (host.length ? [NSString stringWithFormat:@"%@:%d",host,
                                        [mode isEqualToString:@"mps"] ? 24985 : 24988] : @"");
}
- (void)pickServer {
    if (_checking || _started || _installer) return;
    UIAlertController *list = [UIAlertController alertControllerWithTitle:@"Join Private Server"
        message:nil preferredStyle:UIAlertControllerStyleAlert];
    for (NSString *mode in @[@"mps", @"zms"]) {
        NSString *title = [mode isEqualToString:@"mps"] ? @"Aftermath · Multiplayer" : @"TranZit · Zombies";
        [list addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){
            UIAlertController *edit = [UIAlertController alertControllerWithTitle:title
                message:@"Enter the private server’s IPv4 address and port." preferredStyle:UIAlertControllerStyleAlert];
            [edit addTextFieldWithConfigurationHandler:^(UITextField *field){
                field.text = [self savedAddress:mode];
                field.placeholder = @"address:port";
                field.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
                field.autocorrectionType = UITextAutocorrectionTypeNo;
            }];
            [edit addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
            [edit addAction:[UIAlertAction actionWithTitle:@"Join" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){
                [self join:mode address:edit.textFields.firstObject.text];
            }]];
            [self presentViewController:edit animated:YES completion:nil];
        }]];
    }
    [list addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:list animated:YES completion:nil];
}
- (void)join:(NSString *)mode address:(NSString *)input {
    if (_checking || _started || _installer) return;
    NSArray<NSString *> *parts = [[input stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet] componentsSeparatedByString:@":"];
    struct in_addr ip;
    NSString *portText = parts.lastObject;
    NSInteger port = portText.integerValue;
    if (parts.count != 2 || inet_pton(AF_INET,parts.firstObject.UTF8String,&ip) != 1 ||
        port < 1 || port > 65535 || ![[NSString stringWithFormat:@"%ld",(long)port] isEqual:portText]) {
        _status.text = @"Enter an IPv4 address and a port from 1 to 65535.";
        return;
    }
    _checking = YES;
    _status.text = @"Checking the private server…";
    NSLog(@"Checking private %@ server",Modes()[mode]);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0), ^{
        int fd = socket(AF_INET,SOCK_DGRAM,0);
        struct sockaddr_in peer = {.sin_len=sizeof(peer),.sin_family=AF_INET,.sin_addr=ip,.sin_port=htons((uint16_t)port)};
        NSString *nonce = NSUUID.UUID.UUIDString;
        NSMutableData *query = [NSMutableData dataWithBytes:"\xff\xff\xff\xff" length:4];
        [query appendData:[[NSString stringWithFormat:@"getinfo %@",nonce] dataUsingEncoding:NSASCIIStringEncoding]];
        NSDictionary *info=nil;
        BOOL wired=NO;
        if (fd >= 0 && !connect(fd,(struct sockaddr *)&peer,sizeof(peer))) {
            struct timeval timeout = {.tv_sec=1};
            setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,&timeout,sizeof(timeout));
            for (int i=0; i<6 && !info; i++) {
                if (send(fd,query.bytes,query.length,0)<0) { usleep(250000); continue; }
                char buffer[8192];
                ssize_t n=recv(fd,buffer,sizeof(buffer),0);
                if (n>0) info=ServerInfo(buffer,(size_t)n,nonce);
            }
        }
        if (!info) {
            int netError=errno;
            struct ifaddrs *list=NULL;
            BOOL wifi=NO;
            if (!getifaddrs(&list)) {
                for (struct ifaddrs *it=list; it; it=it->ifa_next)
                    if (it->ifa_addr && it->ifa_addr->sa_family==AF_INET && !strcmp(it->ifa_name,"en0")) wifi=YES;
                freeifaddrs(list);
            }
            NSLog(@"Private UDP query failed: error %d, Wi-Fi IPv4 available=%d",netError,wifi);
        }
        if (fd>=0) close(fd);
        if (!info && [parts.firstObject isEqual:[NSBundle.mainBundle objectForInfoDictionaryKey:@"BO2PrivateServer"]]
            && (port==24985 || port==24988)) {
            dispatch_async(dispatch_get_main_queue(),^{self->_status.text=@"Checking the Mac USB connection…";});
            info=WiredServerInfo((uint16_t)port,nonce);
            wired=info!=nil;
        }
        BOOL mp=[mode isEqualToString:@"mps"];
        BOOL compatible=[info[@"sessionmode"] isEqual:mp?@"0":@"1"] && [info[@"protocol"] isEqual:mp?@"2091":@"2089"] &&
                        [info[@"isInGame"] isEqual:@"1"];
        if (info) NSLog(@"Private server answered over %@, compatible=%d",wired?@"USB":@"Wi-Fi",compatible);
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_checking = NO;
            if (!info) { self->_status.text=@"Server did not answer. Check Wi-Fi and Local Network access, or connect to the Mac with USB and try again."; return; }
            if (!compatible) { self->_status.text=@"The server is not running a compatible match for this mode."; return; }
            [NSUserDefaults.standardUserDefaults setObject:[parts componentsJoinedByString:@":"] forKey:[@"BO2Server." stringByAppendingString:mode]];
            self->_server=parts.firstObject;
            self->_port=(uint16_t)port;
            self->_wired=wired;
            [self start:mode];
        });
    });
}
- (void)choose:(UIButton *)sender {
    if (_checking) return;
    _server=nil;
    [self start:sender.accessibilityIdentifier];
}
- (void)steamInstall {
    if(_installer || _started || _checking) return;
    _installer=[SteamInstaller new];
    _installer.window=self.view.window;
    __weak ModePicker *weakSelf=self;
    _installer.status=^(NSString *text,BOOL done){
        ModePicker *picker=weakSelf;
        if(!picker)return;
        picker->_status.text=text;
        if(done)picker->_installer=nil;
    };
    [_installer begin];
}
- (void)updateSteamAccount:(NSNotification *)notification {
    NSString *account=[BO2SteamSignIn accountName];
    [_steamAccount setTitle:account.length ? [@"Steam account · " stringByAppendingString:account] : @"Sign in to Steam"
        forState:UIControlStateNormal];
}
- (void)steamAccount {
    if (_installer || _started || _checking) return;
    [BO2SteamSignIn presentFromViewController:self];
}
- (void)finishSteamLaunch {
    [_steamLaunch finish];
    _steamLaunch = nil;
}
- (void)startSteam:(NSString *)mode {
    if (_installer || _started || _checking || !Modes()[mode]) return;
    NSError *error = nil;
    NSURL *assets = GameDirectory(&error);
    if (!assets) { _status.text = error.localizedDescription; return; }
    NSURL *receiptURL = [NSBundle.mainBundle URLForResource:@"SteamOwnership" withExtension:@"plist"];
    NSDictionary *receipt = receiptURL ? [NSDictionary dictionaryWithContentsOfURL:receiptURL] : nil;
    _checking = YES;
    _server = nil;
    _status.text = @"Connecting to Steam…";
    [BO2SteamRuntime prepareMode:mode assets:assets legacySteamID:[receipt[@"account"] unsignedLongLongValue]
        completion:^(BO2SteamLaunch *launch, NSError *failure) {
            self->_checking = NO;
            if (!launch) {
                self->_status.text = failure.localizedDescription;
                NSLog(@"[steam-runtime] preparation failed");
                return;
            }
            self->_steamLaunch = launch;
            [self start:mode];
            if (!self->_started) [self finishSteamLaunch];
        }];
}
- (void)start:(NSString *)mode {
    if (_installer || _started || !Modes()[mode]) return;
    NSError *error = nil;
    NSURL *game = _steamLaunch ? [NSURL fileURLWithPath:_steamLaunch.gameDirectory isDirectory:YES] : GameDirectory(&error);
    if (!game) { _status.text = error.localizedDescription; return; }
    NSURL *sections = [NSBundle.mainBundle.resourceURL URLByAppendingPathComponent:
        [NSString stringWithFormat:@"Modes/%@/%@",mode,_server ? @"pluto_pe_sections.bin" : @"pe_sections.bin"]];
    if (![sections checkResourceIsReachableAndReturnError:&error]) { _status.text = error.localizedDescription; return; }
    setenv("BO2_GAME_DIR",game.fileSystemRepresentation,1);
    ConfigureRuntime(mode);
    if (chdir(game.fileSystemRepresentation)) { _status.text=@"Could not open the game directory."; return; }
    NSURL *library = [NSBundle.mainBundle.privateFrameworksURL URLByAppendingPathComponent:
        [NSString stringWithFormat:@"%@.framework/%@",mode,mode]];
    void *handle = dlopen(library.fileSystemRepresentation, RTLD_NOW|RTLD_LOCAL);
    if (!handle) { _status.text = [NSString stringWithUTF8String:dlerror()]; return; }
    UIView *(*makeSurface)(CGRect) = (UIView *(*)(CGRect))dlsym(handle,"bo2_ios_create_surface");
    int (*entry)(const char *) = (int (*)(const char *))dlsym(handle,"bo2_ios_start");
    if (!makeSurface || !entry) { _status.text=@"Game entry point missing."; return; }
    if (_steamLaunch && ![_steamLaunch installInHandle:handle]) {
        _status.text = @"This game build does not support Steam sessions yet.";
        NSLog(@"[steam-runtime] provider ABI unavailable");
        return;
    }
    if (_steamLaunch) NSLog(@"[steam-runtime] provider installed before guest entry");
    if (_server) {
        bool (*transport)(const char*,uint16_t,bool)=dlsym(handle,"bo2_pluto_start");
        void (*queue)(const char*)=dlsym(handle,"bo2_cmd_queue");
        void (*post)(uint32_t,uint32_t,uint32_t)=dlsym(handle,"ios_game_event");
        if (!queue || !post || !transport || !transport(_server.UTF8String,_port,_wired)) {
            _status.text=@"Could not start the private server connection."; return;
        }
        BOOL mp=[mode isEqualToString:@"mps"];
        NSTimeInterval connectDelay=Delay(@"BO2ConnectDelay",65);
        NSTimeInterval keyDelay=MIN(Delay(@"BO2MenuKeyDelay",30),connectDelay-5);
        if (mp) dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(keyDelay*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
            post(0x100,13,1);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,120*NSEC_PER_MSEC),dispatch_get_main_queue(),^{post(0x101,13,0xc0000001);});
        });
        NSString *command=[NSString stringWithFormat:@"connect %@:%u",_server,(unsigned)_port];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(connectDelay*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
            QueueConnect(handle,queue,command,mp,2);
        });
    }
    _started = YES;
    UIView *surface = makeSurface(self.view.bounds);
    [self.view addSubview:surface];
    if (_server) {
        UILabel *notice=[UILabel new];
        notice.text=_wired ? @"Loading private match over USB…" : @"Loading private match over Wi-Fi…";
        notice.textColor=UIColor.whiteColor;
        notice.backgroundColor=[UIColor.blackColor colorWithAlphaComponent:0.75];
        notice.font=[UIFont preferredFontForTextStyle:UIFontTextStyleCallout];
        notice.translatesAutoresizingMaskIntoConstraints=NO;
        [self.view addSubview:notice];
        [NSLayoutConstraint activateConstraints:@[
            [notice.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
            [notice.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:8]
        ]];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(Delay(@"BO2ConnectDelay",65)*NSEC_PER_SEC)),dispatch_get_main_queue(),^{ [notice removeFromSuperview]; });
    }
    _menu.hidden = YES;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0), ^{
        int result = entry(sections.fileSystemRepresentation);
        dispatch_async(dispatch_get_main_queue(), ^{
            [self finishSteamLaunch];
            [surface removeFromSuperview];
            self->_menu.hidden = NO;
            self->_status.text = [NSString stringWithFormat:@"%@ exited (%d). Reopen the app to start again.", Modes()[mode],result];
        });
    });
}
@end

@interface GameApp : UIResponder <UIApplicationDelegate>
@property(nonatomic,strong) UIWindow *window;
@end
@implementation GameApp
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)options {
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [ModePicker new];
    [self.window makeKeyAndVisible];
    return YES;
}
@end
int main(int argc,char **argv) {
    @autoreleasepool { return UIApplicationMain(argc,argv,nil,NSStringFromClass(GameApp.class)); }
}
