#import <UIKit/UIKit.h>
#import <QuartzCore/CAMetalLayer.h>
#import <mach/mach.h>
#include <atomic>
#include <cmath>
#import "TouchControls.h"

// Each mode framework owns its input queue and renderer. Install on the main
// thread before starting that mode's guest entry point on its worker thread.
extern "C" void ios_game_event(uint32_t message, uint32_t buttons, uint32_t location);
static std::atomic<double> cursorX{0}, cursorY{0};
static __weak UIView *surface;
static std::atomic<uint64_t> freshFrames{0};
extern "C" void ios_count_game_frame() {
    freshFrames.fetch_add(1, std::memory_order_relaxed);
}

static NSDictionary *SteamReceipt(void) {
    static NSDictionary *receipt;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSURL *file = [NSBundle.mainBundle URLForResource:@"SteamOwnership" withExtension:@"plist"];
        if (file) receipt = [NSDictionary dictionaryWithContentsOfURL:file];
    });
    return receipt;
}
extern "C" uint64_t ios_steam_account(void) {
    return [SteamReceipt()[@"account"] unsignedLongLongValue];
}
extern "C" bool ios_steam_owns(void *, uint32_t app) {
    return [SteamReceipt()[@"owned"] containsObject:@(app)];
}
extern "C" bool ios_steam_dlc(void *, uint32_t app) {
    return [SteamReceipt()[@"installed"] containsObject:@(app)];
}

extern "C" UIView *ios_game_view() { return surface; }
extern "C" void ios_cursor_read(double *x, double *y) {
    *x = cursorX.load();
    *y = cursorY.load();
}
extern "C" void ios_cursor_set(double x, double y) {
    cursorX.store(x);
    cursorY.store(y);
}

@interface BO2GameSurface : UIView
@end
@implementation BO2GameSurface {
    UILabel *_stats;
    NSTimer *_timer;
    uint64_t _lastFrames;
    CFTimeInterval _lastTime;
    BO2TouchControls *_controls;
}
+ (Class)layerClass { return CAMetalLayer.class; }
- (void)didMoveToWindow {
    [super didMoveToWindow];
    [_timer invalidate];
    _timer = nil;
    if (!self.window) {
        [_controls resetInput];
        return;
    }
    if (!_controls) {
        _controls = [[BO2TouchControls alloc] initWithFrame:self.bounds];
        _controls.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [self addSubview:_controls];
    }
    if (!_stats) {
        _stats = [UILabel new];
        _stats.font = [UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightSemibold];
        _stats.textColor = UIColor.whiteColor;
        _stats.backgroundColor = [UIColor.blackColor colorWithAlphaComponent:0.7];
        _stats.userInteractionEnabled = NO;
        _stats.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:_stats];
        [NSLayoutConstraint activateConstraints:@[
            [_stats.trailingAnchor constraintEqualToAnchor:self.safeAreaLayoutGuide.trailingAnchor constant:-8],
            [_stats.topAnchor constraintEqualToAnchor:self.safeAreaLayoutGuide.topAnchor constant:6]
        ]];
    }
    _lastTime = CACurrentMediaTime();
    _lastFrames = freshFrames.load(std::memory_order_relaxed);
    __weak BO2GameSurface *weakSelf = self;
    _timer = [NSTimer timerWithTimeInterval:1 repeats:YES block:^(NSTimer *timer) {
        [weakSelf refreshStats];
    }];
    [NSRunLoop.mainRunLoop addTimer:_timer forMode:NSRunLoopCommonModes];
}
- (void)refreshStats {
    CFTimeInterval now = CACurrentMediaTime();
    uint64_t frames = freshFrames.load(std::memory_order_relaxed);
    double fps = (frames - _lastFrames) / (now - _lastTime);
    _lastTime = now;
    _lastFrames = frames;
    task_vm_info_data_t info = {};
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    kern_return_t result = task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count);
    NSString *ram = result == KERN_SUCCESS ? [NSString stringWithFormat:@"%.0f MB", info.phys_footprint / 1e6] : @"—";
    _stats.text = [NSString stringWithFormat:@"  %.0f FPS   RAM %@  ", fps, ram];
}
- (void)sendTouch:(UITouch *)touch message:(uint32_t)message pressed:(BOOL)pressed {
    CGPoint point = [touch locationInView:self];
    ios_cursor_set(point.x, point.y);
    uint32_t x = (uint16_t)lrint(point.x), y = (uint16_t)lrint(point.y);
    ios_game_event(message, pressed ? 1 : 0, x | (y << 16));
}
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self sendTouch:touches.anyObject message:0x201 pressed:YES];
}
- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self sendTouch:touches.anyObject message:0x200 pressed:YES];
}
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self sendTouch:touches.anyObject message:0x202 pressed:NO];
}
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self touchesEnded:touches withEvent:event];
}
@end

extern "C" UIView *bo2_ios_create_surface(CGRect frame) {
    BO2GameSurface *view = [[BO2GameSurface alloc] initWithFrame:frame];
    view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    surface = view;
    return view;
}

extern "C" bool ios_request_mode(const char *mode) {
    NSString *next = [@{@"campagne":@"sps", @"zombies":@"zms", @"multi":@"mps"}
                      objectForKey:[NSString stringWithUTF8String:mode]];
    if (!next) return false;
    [NSUserDefaults.standardUserDefaults setObject:next forKey:@"BO2RequestedMode"];
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *notice = [UIAlertController alertControllerWithTitle:@"Change game mode"
            message:@"Reopen the app to start the selected mode." preferredStyle:UIAlertControllerStyleAlert];
        [notice addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [surface.window.rootViewController presentViewController:notice animated:YES completion:nil];
    });
    return true;
}
