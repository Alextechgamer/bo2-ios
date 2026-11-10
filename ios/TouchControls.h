// UIKit touch input shares the game's XInput slot with a hardware controller.
#import <QuartzCore/QuartzCore.h>
#include <cmath>
#include <cstring>

extern "C" void ios_touch_pad(unsigned buttons, bool aim, bool fire, float lx, float ly, float rx, float ry);

// Pads use XInput button masks. Fire and Aim are the triggers and carry no mask.
static const struct BO2Pad { const char *title; unsigned mask; } kBO2Pads[] = {
    {"FIRE", 0}, {"AIM", 0}, {"JUMP", 0x1000}, {"CROUCH", 0x2000}, {"USE", 0x4000},
    {"SWAP", 0x8000}, {"MELEE", 0x80}, {"LETHAL", 0x200}, {"TACT", 0x100},
    {"PAUSE", 0x10}, {"SCORE", 0x20}, {"▲", 1}, {"▼", 2}, {"◀", 4}, {"▶", 8},
};
enum {
    kBO2Fire = 0, kBO2Aim = 1,
    kBO2RightCluster = 9,   // pads below this index sit on the right and also steer the view
    kBO2PadCount = sizeof(kBO2Pads) / sizeof(kBO2Pads[0]),
    kBO2RoleMove = -1, kBO2RoleLook = -2,
    kBO2Sprint = 0x40,      // left stick click
};

@interface BO2TouchControls : UIView
- (void)resetInput;
@end

// Left half: a move stick that appears under the thumb and sprints at full forward tilt.
// Right half: swipe to look. A swipe that starts on Fire, Aim or another right-hand
// pad keeps steering, so the player can track a target while shooting.
@implementation BO2TouchControls {
    NSMutableArray<UILabel *> *_pads;
    UIView *_stickBase, *_stickKnob;
    UIButton *_toggle;
    NSMapTable<UITouch *, NSNumber *> *_roles;
    CADisplayLink *_link;
    UIImpactFeedbackGenerator *_haptic;
    CGPoint _moveOrigin, _move, _look, _lookDelta, _lookSmooth;
    CGFloat _stickRadius, _sensitivity;
    unsigned _held, _sentButtons;
    float _sentAxes[4];
    BOOL _sentAim, _sentFire, _shown, _moving, _sprint;
}
- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.multipleTouchEnabled = YES;
    _roles = [NSMapTable strongToStrongObjectsMapTable];
    _haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    // "-BO2LookSensitivity 1.5" as a launch argument, or the saved default, scales swipe speed.
    double saved = [NSUserDefaults.standardUserDefaults doubleForKey:@"BO2LookSensitivity"];
    _sensitivity = saved >= 0.2 && saved <= 5 ? saved : 1;
    _pads = [NSMutableArray array];
    for (unsigned i = 0; i < kBO2PadCount; i++) {
        UILabel *pad = [UILabel new];
        pad.text = @(kBO2Pads[i].title);
        pad.textAlignment = NSTextAlignmentCenter;
        pad.textColor = UIColor.whiteColor;
        pad.font = [UIFont systemFontOfSize:i == kBO2Fire ? 13 : 10 weight:UIFontWeightBold];
        pad.adjustsFontSizeToFitWidth = YES;
        pad.backgroundColor = [UIColor.blackColor colorWithAlphaComponent:i == kBO2Fire ? 0.5 : 0.36];
        pad.layer.borderWidth = 1;
        pad.layer.borderColor = [UIColor.whiteColor colorWithAlphaComponent:0.45].CGColor;
        pad.clipsToBounds = YES;
        [self addSubview:pad];
        [_pads addObject:pad];
    }
    _stickBase = [self ring:0.3];
    _stickKnob = [self ring:0.55];
    _toggle = [UIButton buttonWithType:UIButtonTypeCustom];
    _toggle.titleLabel.font = [UIFont boldSystemFontOfSize:12];
    _toggle.backgroundColor = [UIColor.blackColor colorWithAlphaComponent:0.48];
    _toggle.layer.cornerRadius = 10;
    [_toggle addTarget:self action:@selector(toggle) forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:_toggle];
    [self toggle];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(resetInput)
        name:UIApplicationWillResignActiveNotification object:nil];
    return self;
}
- (UIView *)ring:(CGFloat)alpha {
    UIView *ring = [UIView new];
    ring.backgroundColor = [UIColor.whiteColor colorWithAlphaComponent:alpha * 0.4];
    ring.layer.borderWidth = 1;
    ring.layer.borderColor = [UIColor.whiteColor colorWithAlphaComponent:alpha].CGColor;
    ring.userInteractionEnabled = NO;
    ring.hidden = YES;
    [self addSubview:ring];
    return ring;
}
- (void)didMoveToWindow {
    [super didMoveToWindow];
    [_link invalidate];
    _link = nil;
    if (!self.window) return;
    // The link turns swipe distance per frame into a right-stick deflection.
    _link = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick:)];
    _link.preferredFramesPerSecond = 60;
    _link.paused = !_shown;
    [_link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
}
- (void)place:(NSUInteger)index center:(CGPoint)center size:(CGFloat)size {
    UILabel *pad = _pads[index];
    pad.frame = CGRectMake(center.x - size / 2, center.y - size / 2, size, size);
    pad.layer.cornerRadius = size / 2;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect safe = UIEdgeInsetsInsetRect(self.bounds, self.safeAreaInsets);
    CGFloat left = CGRectGetMinX(safe) + 8, right = CGRectGetMaxX(safe) - 8;
    CGFloat top = CGRectGetMinY(safe) + 4, bottom = CGRectGetMaxY(safe) - 8;
    CGFloat size = MAX(46, MIN(64, safe.size.height * 0.16)), step = size + 8;
    _stickRadius = size;
    // Three columns and rows of pads grow up and left from the bottom-right corner.
    CGFloat col[3] = {right - size / 2, right - size / 2 - step, right - size / 2 - 2 * step};
    CGFloat row[3] = {bottom - size / 2, bottom - size / 2 - step, bottom - size / 2 - 2 * step};
    [self place:2 center:CGPointMake(col[0], row[0]) size:size];                 // Jump
    [self place:3 center:CGPointMake(col[1], row[0]) size:size];                 // Crouch
    [self place:6 center:CGPointMake(col[2], row[0]) size:size];                 // Melee
    [self place:kBO2Aim center:CGPointMake(col[0], row[1]) size:size];
    [self place:kBO2Fire center:CGPointMake(col[1], row[1]) size:size * 1.12];
    [self place:4 center:CGPointMake(col[2], row[1]) size:size];                 // Use / reload
    [self place:5 center:CGPointMake(col[0], row[2]) size:size];                 // Swap
    [self place:7 center:CGPointMake(col[1], row[2]) size:size];                 // Lethal
    [self place:8 center:CGPointMake(col[2], row[2]) size:size];                 // Tactical
    _toggle.frame = CGRectMake(left, top, 78, 34);
    _pads[9].frame = CGRectMake(left + 86, top, 58, 34);                         // Pause
    _pads[10].frame = CGRectMake(left + 152, top, 58, 34);                       // Scoreboard
    _pads[9].layer.cornerRadius = _pads[10].layer.cornerRadius = 10;
    CGFloat cell = 38, cx = left + cell * 1.5, cy = top + 34 + 10 + cell * 1.5;
    [self place:11 center:CGPointMake(cx, cy - cell) size:cell];
    [self place:12 center:CGPointMake(cx, cy + cell) size:cell];
    [self place:13 center:CGPointMake(cx - cell, cy) size:cell];
    [self place:14 center:CGPointMake(cx + cell, cy) size:cell];
    _stickBase.bounds = CGRectMake(0, 0, size * 2, size * 2);
    _stickBase.layer.cornerRadius = size;
    _stickKnob.bounds = CGRectMake(0, 0, size * 0.9, size * 0.9);
    _stickKnob.layer.cornerRadius = size * 0.45;
}
// While the pad is on, every touch is game input. Turn it off to tap menus directly.
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (CGRectContainsPoint(_toggle.frame, point)) return _toggle;
    return _shown && [self pointInside:point withEvent:event] ? self : nil;
}
- (void)toggle {
    _shown = !_shown;
    [_toggle setTitle:_shown ? @"Pad: On" : @"Pad: Off" forState:UIControlStateNormal];
    for (UIView *pad in _pads) pad.hidden = !_shown;
    _link.paused = !_shown;
    if (!_shown) [self resetInput];
}
- (void)publish {
    unsigned buttons = _sprint ? kBO2Sprint : 0;
    for (unsigned i = 0; i < kBO2PadCount; i++) if (_held & (1u << i)) buttons |= kBO2Pads[i].mask;
    BOOL aim = (_held & (1u << kBO2Aim)) != 0, fire = (_held & (1u << kBO2Fire)) != 0;
    float axes[4] = {(float)_move.x, (float)_move.y, (float)_look.x, (float)_look.y};
    // The link ticks every frame, so only forward real changes to the game.
    if (buttons == _sentButtons && aim == _sentAim && fire == _sentFire && !memcmp(axes, _sentAxes, sizeof(axes))) return;
    _sentButtons = buttons; _sentAim = aim; _sentFire = fire;
    memcpy(_sentAxes, axes, sizeof(axes));
    ios_touch_pad(buttons, aim, fire, axes[0], axes[1], axes[2], axes[3]);
}
- (void)showStickAt:(CGPoint)knob {
    _stickBase.center = _moveOrigin;
    _stickKnob.center = knob;
    _stickBase.hidden = _stickKnob.hidden = NO;
}
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    for (UITouch *touch in touches) {
        CGPoint p = [touch locationInView:self];
        NSInteger role = NSNotFound;
        for (NSUInteger i = 0; i < _pads.count; i++)
            if (CGRectContainsPoint(CGRectInset(_pads[i].frame, -5, -5), p)) { role = (NSInteger)i; break; }
        if (role != NSNotFound) {
            _held |= 1u << role;
            _pads[role].alpha = 0.55;
            [_haptic impactOccurred];
        } else if (p.x < CGRectGetMidX(self.bounds)) {
            if (_moving) continue;   // one move stick; extra fingers on the left do nothing
            role = kBO2RoleMove;
            _moving = YES;
            _moveOrigin = p;
            [self showStickAt:p];
        } else {
            role = kBO2RoleLook;
        }
        [_roles setObject:@(role) forKey:touch];
    }
    [self publish];
}
- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    for (UITouch *touch in touches) {
        NSNumber *entry = [_roles objectForKey:touch];
        if (!entry) continue;
        NSInteger role = entry.integerValue;
        CGPoint p = [touch locationInView:self];
        if (role == kBO2RoleMove) {
            CGFloat dx = p.x - _moveOrigin.x, dy = p.y - _moveOrigin.y, length = hypot(dx, dy);
            if (length > _stickRadius) {
                // Drag the base along so the thumb never runs off the stick.
                _moveOrigin.x = p.x - dx / length * _stickRadius;
                _moveOrigin.y = p.y - dy / length * _stickRadius;
                dx = p.x - _moveOrigin.x; dy = p.y - _moveOrigin.y;
            }
            _move = CGPointMake(dx / _stickRadius, -dy / _stickRadius);
            _sprint = hypot(_move.x, _move.y) > 0.94 && _move.y > 0.75;
            [self showStickAt:p];
        } else if (role == kBO2RoleLook || role < kBO2RightCluster) {
            CGPoint before = [touch previousLocationInView:self];
            _lookDelta.x += p.x - before.x;
            _lookDelta.y += p.y - before.y;
        }
    }
    [self publish];
}
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    for (UITouch *touch in touches) {
        NSNumber *entry = [_roles objectForKey:touch];
        if (!entry) continue;
        [_roles removeObjectForKey:touch];
        NSInteger role = entry.integerValue;
        if (role == kBO2RoleMove) {
            _moving = _sprint = NO;
            _move = CGPointZero;
            _stickBase.hidden = _stickKnob.hidden = YES;
        } else if (role >= 0) {
            _held &= ~(1u << role);
            _pads[role].alpha = 1;
        }
    }
    [self publish];
}
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self touchesEnded:touches withEvent:event];
}
- (void)tick:(CADisplayLink *)link {
    // About 18 points of travel per frame is a full deflection at sensitivity 1.
    CGFloat scale = _sensitivity / 18.0;
    _lookSmooth.x = 0.4 * _lookSmooth.x + 0.6 * _lookDelta.x * scale;
    _lookSmooth.y = 0.4 * _lookSmooth.y - 0.6 * _lookDelta.y * scale;
    _lookDelta = CGPointZero;
    CGFloat length = hypot(_lookSmooth.x, _lookSmooth.y);
    if (length < 0.03) {
        _lookSmooth = _look = CGPointZero;
    } else {
        // Start above the game's stick dead zone so slow swipes still turn.
        CGFloat out = 0.22 + 0.78 * MIN(1.0, length);
        _look = CGPointMake(_lookSmooth.x / length * out, _lookSmooth.y / length * out);
    }
    [self publish];
}
- (void)resetInput {
    [_roles removeAllObjects];
    _held = 0;
    _moving = _sprint = NO;
    _move = _look = _lookDelta = _lookSmooth = CGPointZero;
    _stickBase.hidden = _stickKnob.hidden = YES;
    for (UIView *pad in _pads) pad.alpha = 1;
    _sentButtons = ~0u;   // force one publish so the game always sees the release
    [self publish];
}
@end
