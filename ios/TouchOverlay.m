#import "TouchOverlay.h"
#import <QuartzCore/QuartzCore.h>
#include <dlfcn.h>
#include <math.h>
#include <string.h>

// Pads use XInput button masks. The fire pads and ADS are the triggers and carry no mask.
// dx, dy and size place the right-hand pads from the bottom-right corner of the
// safe area on a 430-point-high screen. The others get their defaults in code.
// The layout follows the usual phone shooter: a large fire pad under the right thumb
// with the other actions around it, a second fire pad on the left, and the menu on top.
// PRONE holds the crouch button long enough for the game to go prone; USE is the
// reload button under the name the game gives it at doors and boxes.
//
// The second layout is the on-screen gamepad of CyPort (https://github.com/Thijs2004/CyPort,
// shim/MacShim.m, MIT, Copyright (c) 2026 Thijs Mussig): the same pads under their Xbox names at
// CyPort's positions and sizes. `pad` is that name, `corner` the screen corner px and py are
// measured from, and pr the radius. A pad without a name is not part of that layout.
// The triggers and bumpers sit 22 points lower than CyPort's, clear of this app's frame counter.
enum { kNone, kRightBottom, kRightTop, kLeftTop, kLeftBottom, kCentreTop };
static const struct BO2Pad { const char *title; unsigned mask; CGFloat dx, dy, size;
                             const char *pad; int corner; CGFloat px, py, pr; } kPads[] = {
    {"FIRE", 0, 120, 110, 84, "RT", kRightTop, 40, 62, 30},        {"ADS", 0, 52, 178, 60, "LT", kLeftTop, 40, 62, 30},
    {"JUMP", 0x1000, 44, 96, 58, "A", kRightBottom, 85, 40, 27},   {"CROUCH", 0x2000, 112, 34, 52, "B", kRightBottom, 35, 90, 27},
    {"PRONE", 0x2000, 48, 34, 48},
    {"RELOAD", 0x4000, 196, 50, 52, "X", kRightBottom, 135, 90, 27}, {"USE", 0x4000, 204, 128, 50},
    {"SWAP", 0x8000, 270, 40, 50, "Y", kRightBottom, 85, 140, 27},
    {"KNIFE", 0x80, 190, 196, 50, "R3", kRightBottom, 170, 22, 20},
    {"FRAG", 0x200, 118, 200, 46, "RB", kRightTop, 115, 56, 24},   {"TAC", 0x100, 60, 244, 46, "LB", kLeftTop, 115, 56, 24},
    {"HIP", 0, 0, 0, 54},
    {"MENU", 0x10, 0, 0, 50, "≡", kCentreTop, 55, 20, 17},          {"SCORE", 0x20, 0, 0, 48, "⧉", kCentreTop, -55, 20, 17},
    {"▲", 1, 0, 0, 36, "▲", kLeftTop, 190, 22, 16}, {"▼", 2, 0, 0, 36, "▼", kLeftTop, 190, 86, 16},
    {"◀", 4, 0, 0, 36, "◀", kLeftTop, 158, 54, 16}, {"▶", 8, 0, 0, 36, "▶", kLeftTop, 222, 54, 16},
    // Only in the gamepad layout: the left stick click (sprint) and the Escape key.
    {"L3", 0x40, 0, 0, 40, "L3", kLeftBottom, 24, 24, 20},          {"ESC", 0, 0, 0, 40, "Esc", kCentreTop, -120, 20, 19},
};
enum {
    kFire = 0, kAim = 1, kProne = 4,
    kRightCluster = 11,  // pads below this index also steer the view while they sit on the right
    kHip = 11, kPause = 12, kScore = 13, kUp = 14, kGamepadOnly = 18, kEscape = 19,
    kPadCount = sizeof(kPads) / sizeof(kPads[0]),
    kRoleMove = -1, kRoleLook = -2, kRoleEdit = -3,
    kSprint = 0x40,      // left stick click
};
// The game reads the pad once a frame, so a tap is held at least this long to be seen.
static const CFTimeInterval kMinHold = 0.12, kProneHold = 0.55;
// FIRE raises the sights first; the shots start this long after, and a tap still fires once.
static const CFTimeInterval kAimLead = 0.18, kTapShot = 0.10;
static NSString *const kLayoutKey = @"BO2TouchLayout2", *const kGamepadLayoutKey = @"BO2TouchLayoutPad";

// Two states. "Menu" lets every touch through to the game as a mouse pointer, so
// menus are tapped directly. "Play" shows the controls: the left side is a move
// stick that appears under the thumb, the right side turns the view, and a drag
// that starts on a right-hand pad keeps turning while the pad is held.
// Multiplayer and Zombies switch to Play when the match starts and back when it ends.
// MENU opens the game's own pause menu and hands the screen back to the pointer so
// the menu can be tapped; the Controls button brings the pads back.
@implementation BO2TouchOverlay {
    void (*_pad)(unsigned, bool, bool, float, float, float, float);
    void (*_cursorRead)(double *, double *);
    void (*_cursorSet)(double, double);
    void (*_event)(uint32_t, uint32_t, uint32_t);
    uint8_t **_arena;
    uint32_t _stateAddress, _mapAddress, _clientState;
    char _map[32];
    unsigned _frame;
    BOOL _inMatch;
    NSMutableArray<UILabel *> *_pads;
    NSMutableDictionary<NSString *, NSArray<NSNumber *> *> *_layout;   // title -> x, y (fractions of the safe area), size
    UIView *_stickBase, *_stickKnob, *_panel, *_editBar;
    UIButton *_modeButton, *_gear;
    UISegmentedControl *_lookMode, *_aimMode, *_fireMode, *_menuMode, *_style;
    CFTimeInterval _downAt[kPadCount], _releaseAt[kPadCount], _fireLead, _menuAt, _lookAt;
    BOOL _gamepad;
    UISlider *_speed, *_size;
    NSMapTable<UITouch *, NSNumber *> *_roles;
    CADisplayLink *_link;
    UIImpactFeedbackGenerator *_haptic;
    CGPoint _moveOrigin, _move, _look, _lookDelta, _lookSmooth, _grab;
    CGFloat _stickRadius, _sensitivity;
    NSInteger _selected;
    unsigned _held, _sentButtons;
    float _sentAxes[4];
    BOOL _sentAim, _sentFire, _play, _moving, _sprint, _stickLook, _aimToggle, _aimLatched, _editing, _hipFire, _escMenu;
}
- (instancetype)initWithFrame:(CGRect)frame handle:(void *)handle mode:(NSString *)mode {
    if (!(self = [super initWithFrame:frame])) return nil;
    _pad = dlsym(handle, "ios_touch_pad");
    _cursorRead = dlsym(handle, "ios_cursor_read");
    _cursorSet = dlsym(handle, "ios_cursor_set");
    _event = dlsym(handle, "ios_game_event");
    _arena = dlsym(handle, "bo2_g_base");
    if (!_pad || !_cursorRead || !_cursorSet) return nil;
    // Guest memory the automatic switch reads. The client connection state is 10
    // while a map is running, which includes the menu map of online play. The
    // "mapname" variable names that map; its text pointer sits 0x18 into the record.
    BOOL mp = [mode isEqualToString:@"mps"], zm = [mode isEqualToString:@"zms"];
    _stateAddress = mp ? 0x10e9d88 : zm ? 0x10e7e18 : 0;
    _mapAddress = mp ? 0x281d750 : zm ? 0x281b7d0 : 0x2b962e4;
    self.multipleTouchEnabled = YES;
    _selected = NSNotFound;
    _roles = [NSMapTable strongToStrongObjectsMapTable];
    _haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    NSUserDefaults *saved = NSUserDefaults.standardUserDefaults;
    double speed = [saved doubleForKey:@"BO2LookSensitivity"];
    _sensitivity = speed >= 0.2 && speed <= 5 ? speed : 1;
    _stickLook = [saved boolForKey:@"BO2StickLook"];
    _aimToggle = [saved boolForKey:@"BO2AimToggle"];
    _hipFire = [saved boolForKey:@"BO2HipFire"];
    _escMenu = _event && [saved boolForKey:@"BO2EscMenu"];
    _gamepad = ![saved boolForKey:@"BO2ShooterPads"];
    _layout = [([saved dictionaryForKey:[self layoutKey]] ?: @{}) mutableCopy];
    _pads = [NSMutableArray array];
    for (unsigned i = 0; i < kPadCount; i++) {
        UILabel *pad = [UILabel new];
        pad.text = @(kPads[i].title);
        pad.textAlignment = NSTextAlignmentCenter;
        pad.textColor = [UIColor colorWithWhite:1 alpha:0.9];
        pad.font = [UIFont systemFontOfSize:i == kFire ? 15 : 10 weight:UIFontWeightHeavy];
        pad.adjustsFontSizeToFitWidth = YES;
        pad.layer.borderWidth = 1.5;
        pad.clipsToBounds = YES;
        pad.hidden = YES;
        [self addSubview:pad];
        [_pads addObject:pad];
    }
    _stickBase = [self ring:0.3];
    _stickKnob = [self ring:0.6];
    _modeButton = [self button:nil action:@selector(toggleMode)];
    _gear = [self button:nil action:@selector(togglePanel)];
    [_gear setImage:[UIImage systemImageNamed:@"gearshape.fill"] forState:UIControlStateNormal];
    _gear.tintColor = UIColor.whiteColor;
    [self buildPanel];
    [self buildEditBar];
    [self setPlay:NO];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(resetInput)
        name:UIApplicationWillResignActiveNotification object:nil];
    return self;
}
- (UIButton *)button:(NSString *)title action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
    [button setTitle:title forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont boldSystemFontOfSize:12];
    button.backgroundColor = [UIColor colorWithWhite:0 alpha:0.5];
    button.layer.cornerRadius = 10;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:button];
    return button;
}
- (UIView *)ring:(CGFloat)alpha {
    UIView *ring = [UIView new];
    ring.backgroundColor = [UIColor colorWithWhite:1 alpha:alpha * 0.4];
    ring.layer.borderWidth = 1.5;
    ring.layer.borderColor = [UIColor colorWithWhite:1 alpha:alpha].CGColor;
    ring.userInteractionEnabled = NO;
    ring.hidden = YES;
    [self addSubview:ring];
    return ring;
}
- (UILabel *)caption:(NSString *)text {
    UILabel *label = [UILabel new];
    label.text = text;
    label.textColor = [UIColor colorWithWhite:1 alpha:0.7];
    label.font = [UIFont systemFontOfSize:12];
    return label;
}
- (UIView *)card:(NSArray<UIView *> *)rows axis:(UILayoutConstraintAxis)axis {
    UIView *card = [UIView new];
    card.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.94];
    card.layer.cornerRadius = 14;
    card.hidden = YES;
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:rows];
    stack.axis = axis;
    stack.spacing = axis == UILayoutConstraintAxisVertical ? 6 : 10;
    stack.alignment = axis == UILayoutConstraintAxisVertical ? UIStackViewAlignmentFill : UIStackViewAlignmentCenter;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:12],
        [stack.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-12],
        [stack.topAnchor constraintEqualToAnchor:card.topAnchor constant:8],
        [stack.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-8]
    ]];
    [self addSubview:card];
    return card;
}
// Settings: how the view turns, how fast, how ADS behaves, and the layout editor.
- (void)buildPanel {
    _lookMode = [[UISegmentedControl alloc] initWithItems:@[@"Swipe", @"Stick"]];
    _lookMode.selectedSegmentIndex = _stickLook ? 1 : 0;
    _aimMode = [[UISegmentedControl alloc] initWithItems:@[@"Hold", @"Tap"]];
    _aimMode.selectedSegmentIndex = _aimToggle ? 1 : 0;
    _speed = [UISlider new];
    _speed.minimumValue = 0.2;
    _speed.maximumValue = 3;
    _speed.value = (float)_sensitivity;
    // FIRE either raises the sights and then shoots, or only shoots. The HIP pad always only shoots.
    _fireMode = [[UISegmentedControl alloc] initWithItems:@[@"Aim + fire", @"Hip fire"]];
    _fireMode.selectedSegmentIndex = _hipFire ? 1 : 0;
    // MENU presses the pad's Start button, or the Escape key for a game that ignores Start.
    _menuMode = [[UISegmentedControl alloc] initWithItems:@[@"Start", @"Esc key"]];
    _menuMode.selectedSegmentIndex = _escMenu ? 1 : 0;
    _menuMode.enabled = _event != NULL;
    _style = [[UISegmentedControl alloc] initWithItems:@[@"Gamepad", @"Shooter"]];
    _style.selectedSegmentIndex = _gamepad ? 0 : 1;
    for (UIControl *control in @[_lookMode, _aimMode, _fireMode, _menuMode, _style, _speed])
        [control addTarget:self action:@selector(settingsChanged) forControlEvents:UIControlEventValueChanged];
    UIButton *edit = [self button:@"Edit layout" action:@selector(beginEditing)];
    UIButton *reset = [self button:@"Reset layout" action:@selector(resetLayout)];
    edit.backgroundColor = reset.backgroundColor = [UIColor colorWithWhite:1 alpha:0.14];
    UIStackView *buttons = [[UIStackView alloc] initWithArrangedSubviews:@[edit, reset]];
    buttons.distribution = UIStackViewDistributionFillEqually;
    buttons.spacing = 8;
    [buttons.heightAnchor constraintEqualToConstant:32].active = YES;
    _panel = [self card:@[[self row:@"Layout" control:_style],
                          [self row:@"Look" control:_lookMode], [self row:@"Look speed" control:_speed],
                          [self row:@"FIRE pad" control:_fireMode], [self row:@"ADS pad" control:_aimMode],
                          [self row:@"MENU pad" control:_menuMode], buttons] axis:UILayoutConstraintAxisVertical];
}
- (UIView *)row:(NSString *)title control:(UIView *)control {
    UILabel *caption = [self caption:title];
    [caption.widthAnchor constraintEqualToConstant:76].active = YES;
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[caption, control]];
    row.spacing = 8;
    row.alignment = UIStackViewAlignmentCenter;
    [row.heightAnchor constraintEqualToConstant:32].active = YES;
    return row;
}
// Shown while editing: drag a pad to move it, use the slider to resize the selected one.
- (void)buildEditBar {
    _size = [UISlider new];
    _size.minimumValue = 30;
    _size.maximumValue = 120;
    [_size addTarget:self action:@selector(sizeChanged) forControlEvents:UIControlEventValueChanged];
    [_size.widthAnchor constraintEqualToConstant:170].active = YES;
    UIButton *done = [self button:@"Done" action:@selector(endEditing)];
    done.backgroundColor = [UIColor colorWithRed:0.2 green:0.55 blue:0.3 alpha:1];
    [done.widthAnchor constraintEqualToConstant:64].active = YES;
    [done.heightAnchor constraintEqualToConstant:30].active = YES;
    _editBar = [self card:@[[self caption:@"Drag to move · Size"], _size, done] axis:UILayoutConstraintAxisHorizontal];
}
- (void)settingsChanged {
    _stickLook = _lookMode.selectedSegmentIndex == 1;
    _aimToggle = _aimMode.selectedSegmentIndex == 1;
    _hipFire = _fireMode.selectedSegmentIndex == 1;
    _escMenu = _event && _menuMode.selectedSegmentIndex == 1;
    _sensitivity = _speed.value;
    BOOL gamepad = _style.selectedSegmentIndex == 0;
    if (gamepad != _gamepad) {
        // Each layout keeps its own moved pads.
        _gamepad = gamepad;
        [NSUserDefaults.standardUserDefaults setBool:!gamepad forKey:@"BO2ShooterPads"];
        _layout = [([NSUserDefaults.standardUserDefaults dictionaryForKey:[self layoutKey]] ?: @{}) mutableCopy];
        for (NSUInteger i = 0; i < kPadCount; i++) _pads[i].hidden = !_play || ![self shown:i];
        [self setNeedsLayout];
    }
    NSUserDefaults *saved = NSUserDefaults.standardUserDefaults;
    [saved setBool:_stickLook forKey:@"BO2StickLook"];
    [saved setBool:_aimToggle forKey:@"BO2AimToggle"];
    [saved setBool:_hipFire forKey:@"BO2HipFire"];
    [saved setBool:_escMenu forKey:@"BO2EscMenu"];
    [saved setDouble:_sensitivity forKey:@"BO2LookSensitivity"];
    [self resetInput];
}
- (void)togglePanel {
    if (_editing) return;
    _panel.hidden = !_panel.hidden;
    if (!_panel.hidden) [self resetInput];
}
- (void)didMoveToWindow {
    [super didMoveToWindow];
    [_link invalidate];
    _link = nil;
    if (!self.window) { [self resetInput]; return; }
    _link = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick:)];
    _link.preferredFramesPerSecond = 60;
    [_link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
}

#pragma mark Layout

- (CGRect)safe { return UIEdgeInsetsInsetRect(self.bounds, self.safeAreaInsets); }
- (NSString *)layoutKey { return _gamepad ? kGamepadLayoutKey : kLayoutKey; }
- (BOOL)shown:(NSUInteger)i { return _gamepad ? kPads[i].corner != kNone : i < kGamepadOnly; }
// The area CyPort lays its pad out in: the safe area, at least 16 points in from the sides and 8 from top and bottom.
- (CGRect)padArea {
    UIEdgeInsets in = self.safeAreaInsets;
    CGSize size = self.bounds.size;
    CGFloat left = MAX(in.left, 16), top = MAX(in.top, 8);
    return CGRectMake(left, top, size.width - MAX(in.right, 16) - left, size.height - MAX(in.bottom, 8) - top);
}
// Where the move stick rests.
- (CGPoint)stickHome {
    if (_gamepad) { CGRect area = [self padArea]; return CGPointMake(CGRectGetMinX(area) + 115, CGRectGetMaxY(area) - 105); }
    CGRect safe = [self safe];
    return CGPointMake(CGRectGetMinX(safe) + 8 + 112 * [self scale], CGRectGetMaxY(safe) - 4 - 96 * [self scale]);
}
- (CGFloat)scale { return MAX(0.8, MIN(1.2, [self safe].size.height / 430)); }
// Centre and size of a pad before the player moves it.
- (CGRect)defaultFrame:(NSUInteger)i {
    if (_gamepad) {
        const struct BO2Pad *pad = &kPads[i];
        CGRect area = [self padArea];
        CGFloat r = pad->pr, x, y = pad->corner == kRightBottom || pad->corner == kLeftBottom
            ? CGRectGetMaxY(area) - pad->py : CGRectGetMinY(area) + pad->py;
        if (pad->corner == kNone) return CGRectZero;
        if (pad->corner == kCentreTop) x = CGRectGetMidX(self.bounds) + pad->px;
        else if (pad->corner == kLeftTop || pad->corner == kLeftBottom) x = CGRectGetMinX(area) + pad->px;
        else x = CGRectGetMaxX(area) - pad->px;
        return CGRectMake(x - r, y - r, 2 * r, 2 * r);
    }
    CGRect safe = [self safe];
    CGFloat scale = [self scale], size = kPads[i].size * scale;
    CGFloat left = CGRectGetMinX(safe) + 8, top = CGRectGetMinY(safe) + 4;
    CGPoint centre;
    if (i < kRightCluster) {
        centre = CGPointMake(CGRectGetMaxX(safe) - 4 - kPads[i].dx * scale, CGRectGetMaxY(safe) - 4 - kPads[i].dy * scale);
    } else if (i == kHip) {
        // Above the resting move stick, for the left thumb or index finger.
        centre = CGPointMake(left + 34 * scale, CGRectGetMaxY(safe) - 216 * scale);
    } else if (i == kPause) {
        centre = CGPointMake(left + 158, top + size / 2);
    } else if (i == kScore) {
        centre = CGPointMake(left + 218, top + size / 2);
    } else {
        // Scorestreak and menu D-pad, top centre-left, out of the move thumb's way.
        CGFloat cx = left + 290 + size, cy = top + size * 1.5;
        CGPoint offset[4] = {{0, -size}, {0, size}, {-size, 0}, {size, 0}};
        centre = CGPointMake(cx + offset[i - kUp].x, cy + offset[i - kUp].y);
    }
    return CGRectMake(centre.x - size / 2, centre.y - size / 2, size, size);
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect safe = [self safe];
    CGFloat left = CGRectGetMinX(safe) + 8, top = CGRectGetMinY(safe) + 4;
    for (NSUInteger i = 0; i < kPadCount; i++) {
        CGRect frame = [self defaultFrame:i];
        NSArray<NSNumber *> *custom = _layout[@(kPads[i].title)];
        const char *name = _gamepad && kPads[i].pad ? kPads[i].pad : kPads[i].title;
        _pads[i].text = @(name);
        _pads[i].font = [UIFont systemFontOfSize:!_gamepad ? (i == kFire ? 15 : 10) : strlen(name) > 2 ? 9 : 13
                                          weight:_gamepad ? UIFontWeightBold : UIFontWeightHeavy];
        if (custom.count == 3 && [self shown:i]) {
            CGFloat size = MAX(30, MIN(120, custom[2].doubleValue));
            frame = CGRectMake(CGRectGetMinX(safe) + custom[0].doubleValue * safe.size.width - size / 2,
                               CGRectGetMinY(safe) + custom[1].doubleValue * safe.size.height - size / 2, size, size);
        }
        _pads[i].frame = frame;
        _pads[i].layer.cornerRadius = _gamepad || i <= kHip ? frame.size.width / 2 : 10;
    }
    if (_gamepad) {
        // The top corners belong to the triggers, so the two buttons sit in the top centre, where CyPort has its own.
        CGFloat mid = CGRectGetMidX(self.bounds), y = CGRectGetMinY([self padArea]) + 3;
        _gear.frame = CGRectMake(mid - 18, y, 36, 34);
        _modeButton.frame = CGRectMake(mid + 100, y, 72, 34);
        _panel.frame = CGRectMake(mid - 150, y + 40, 300, 282);
    } else {
        _modeButton.frame = CGRectMake(left, top, 72, 34);
        _gear.frame = CGRectMake(left + 80, top, 40, 34);
        _panel.frame = CGRectMake(left, top + 42, 300, 282);
    }
    _editBar.frame = CGRectMake(CGRectGetMidX(safe) - 190, top, 380, 46);
    _stickRadius = 60 * [self scale];
    _stickBase.bounds = CGRectMake(0, 0, _stickRadius * 2, _stickRadius * 2);
    _stickBase.layer.cornerRadius = _stickRadius;
    _stickKnob.bounds = CGRectMake(0, 0, _stickRadius * 0.9, _stickRadius * 0.9);
    _stickKnob.layer.cornerRadius = _stickRadius * 0.45;
    [self restStick];
}
// While no thumb is on it, the move stick waits faintly where the left thumb rests.
- (void)restStick {
    if (_moving) return;
    _stickBase.center = _stickKnob.center = [self stickHome];
    _stickBase.alpha = _stickKnob.alpha = 0.45;
    _stickBase.hidden = _stickKnob.hidden = !_play || _editing;
}
- (void)stylePads {
    for (NSUInteger i = 0; i < kPadCount; i++) {
        UILabel *pad = _pads[i];
        BOOL lit = _editing ? (NSInteger)i == _selected : (i == kAim && _aimLatched) || (_held & (1u << i));
        pad.backgroundColor = _gamepad ? [UIColor colorWithWhite:1 alpha:lit ? 0.45 : 0.12]
            : lit ? [UIColor colorWithRed:1 green:0.55 blue:0.1 alpha:0.5]
            : i == kFire || i == kHip ? [UIColor colorWithRed:0.75 green:0.15 blue:0.1 alpha:0.42] : [UIColor colorWithWhite:0 alpha:0.32];
        pad.layer.borderColor = (_editing ? [UIColor colorWithRed:1 green:0.6 blue:0.2 alpha:0.9]
                                          : [UIColor colorWithWhite:1 alpha:0.5]).CGColor;
    }
}
- (void)beginEditing {
    [self resetInput];
    _editing = YES;
    _selected = NSNotFound;
    _panel.hidden = YES;
    _editBar.hidden = NO;
    _size.enabled = NO;
    [self restStick];
    [self stylePads];
}
- (void)endEditing {
    _editing = NO;
    _editBar.hidden = YES;
    [NSUserDefaults.standardUserDefaults setObject:_layout forKey:[self layoutKey]];
    [self restStick];
    [self stylePads];
}
- (void)resetLayout {
    [_layout removeAllObjects];
    [NSUserDefaults.standardUserDefaults removeObjectForKey:[self layoutKey]];
    [self setNeedsLayout];
}
// Record a pad's frame as fractions of the safe area, so it survives rotation and other screens.
- (void)storePad:(NSUInteger)i {
    CGRect safe = [self safe], frame = _pads[i].frame;
    _layout[@(kPads[i].title)] = @[@((CGRectGetMidX(frame) - CGRectGetMinX(safe)) / safe.size.width),
                                   @((CGRectGetMidY(frame) - CGRectGetMinY(safe)) / safe.size.height), @(frame.size.width)];
}
- (void)sizeChanged {
    if (_selected == NSNotFound) return;
    CGPoint centre = _pads[_selected].center;
    CGFloat size = _size.value;
    _pads[_selected].frame = CGRectMake(centre.x - size / 2, centre.y - size / 2, size, size);
    [self storePad:_selected];
    [self setNeedsLayout];
}

#pragma mark Touches

// In Menu, only the mode button takes touches; the rest reaches the game as a pointer.
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (_editing) {
        UIView *hit = [_editBar hitTest:[self convertPoint:point toView:_editBar] withEvent:event];
        return hit ?: self;
    }
    if (CGRectContainsPoint(_modeButton.frame, point)) return _modeButton;
    if (!_play) return nil;
    if (CGRectContainsPoint(_gear.frame, point)) return _gear;
    if (!_panel.hidden) {
        UIView *hit = [_panel hitTest:[self convertPoint:point toView:_panel] withEvent:event];
        if (hit) return hit;
        _panel.hidden = YES;   // a touch outside closes the panel
    }
    return [self pointInside:point withEvent:event] ? self : nil;
}
- (void)setPlay:(BOOL)play {
    if (_editing) [self endEditing];
    _play = play;
    [_modeButton setTitle:play ? @"Pointer" : @"Controls" forState:UIControlStateNormal];
    for (NSUInteger i = 0; i < kPadCount; i++) _pads[i].hidden = !play || ![self shown:i];
    _gear.hidden = !play;
    _panel.hidden = YES;
    [self resetInput];
}
- (void)toggleMode { [self setPlay:!_play]; }
// A pad counts as pressed while a finger is on it and until its minimum hold has run out.
- (BOOL)pressed:(unsigned)i at:(CFTimeInterval)now { return (_held & (1u << i)) || now < _releaseAt[i]; }
- (void)publish {
    CFTimeInterval now = CACurrentMediaTime();
    unsigned buttons = _sprint ? kSprint : 0;
    for (unsigned i = 0; i < kPadCount; i++)
        if ([self pressed:i at:now] && !(i == kPause && _escMenu)) buttons |= kPads[i].mask;
    BOOL firing = [self pressed:kFire at:now];
    BOOL aim = (_aimToggle ? _aimLatched : [self pressed:kAim at:now]) || (firing && !_hipFire);
    BOOL fire = (firing && now >= _downAt[kFire] + _fireLead) || [self pressed:kHip at:now];
    float axes[4] = {(float)_move.x, (float)_move.y, (float)_look.x, (float)_look.y};
    // The link ticks every frame, so only forward real changes to the game.
    if (buttons == _sentButtons && aim == _sentAim && fire == _sentFire && !memcmp(axes, _sentAxes, sizeof(axes))) return;
    _sentButtons = buttons; _sentAim = aim; _sentFire = fire;
    memcpy(_sentAxes, axes, sizeof(axes));
    _pad(buttons, aim, fire, axes[0], axes[1], axes[2], axes[3]);
}
- (void)showStickAt:(CGPoint)knob {
    _stickBase.center = _moveOrigin;
    _stickKnob.center = knob;
    _stickBase.alpha = _stickKnob.alpha = 1;
    _stickBase.hidden = _stickKnob.hidden = NO;
}
// The closest pad whose enlarged outline contains the point.
- (NSInteger)padAt:(CGPoint)p {
    NSInteger found = NSNotFound;
    CGFloat nearest = CGFLOAT_MAX;
    for (NSUInteger i = 0; i < _pads.count; i++) {
        CGRect frame = _pads[i].frame;
        if (_pads[i].hidden) continue;
        CGFloat distance = hypot(p.x - CGRectGetMidX(frame), p.y - CGRectGetMidY(frame));
        if (CGRectContainsPoint(CGRectInset(frame, -8, -8), p) && distance < nearest) { nearest = distance; found = (NSInteger)i; }
    }
    return found;
}
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    for (UITouch *touch in touches) {
        CGPoint p = [touch locationInView:self];
        NSInteger role = [self padAt:p];
        if (_editing) {
            if (role == NSNotFound || _roles.count) continue;   // one pad at a time
            _selected = role;
            _grab = CGPointMake(p.x - _pads[role].center.x, p.y - _pads[role].center.y);
            _size.enabled = YES;
            _size.value = (float)_pads[role].frame.size.width;
            [_roles setObject:@(kRoleEdit) forKey:touch];
            continue;
        }
        if (role != NSNotFound) {
            CFTimeInterval now = CACurrentMediaTime();
            if (role == kFire) {
                // No wait when the sights are already up.
                BOOL aimed = _aimToggle ? _aimLatched : [self pressed:kAim at:now];
                _fireLead = _hipFire || aimed ? 0 : kAimLead;
            }
            if (_event && ((role == kPause && _escMenu) || role == kEscape)) {
                _event(0x100, 0x1B, 1);            // key down, character, key up
                _event(0x102, 0x1B, 1);
                _event(0x101, 0x1B, 0xC0000001u);
            }
            _held |= 1u << role;
            _downAt[role] = now;
            _releaseAt[role] = 0;
            if (role == kAim && _aimToggle) _aimLatched = !_aimLatched;
            [_haptic impactOccurred];
        } else if (p.x < CGRectGetWidth(self.bounds) * 0.45) {
            if (_moving) continue;   // one move stick; extra fingers on the left do nothing
            role = kRoleMove;
            _moving = YES;
            // On the resting stick the stick stays put; anywhere else it starts under the thumb.
            CGPoint home = [self stickHome];
            _moveOrigin = hypot(p.x - home.x, p.y - home.y) <= 85 ? home : p;
            [self showStickAt:p];
        } else {
            role = kRoleLook;
        }
        [_roles setObject:@(role) forKey:touch];
    }
    [self stylePads];
    if (!_editing) [self publish];
}
- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    for (UITouch *touch in touches) {
        NSNumber *entry = [_roles objectForKey:touch];
        if (!entry) continue;
        NSInteger role = entry.integerValue;
        CGPoint p = [touch locationInView:self];
        if (role == kRoleEdit) {
            CGRect bounds = self.bounds;
            _pads[_selected].center = CGPointMake(MAX(20, MIN(CGRectGetMaxX(bounds) - 20, p.x - _grab.x)),
                                                  MAX(20, MIN(CGRectGetMaxY(bounds) - 20, p.y - _grab.y)));
            [self storePad:_selected];
        } else if (role == kRoleMove) {
            CGFloat dx = p.x - _moveOrigin.x, dy = p.y - _moveOrigin.y, length = hypot(dx, dy);
            if (length > _stickRadius && _gamepad) {
                // The gamepad's stick stays where it is and the knob stops at its rim.
                p = CGPointMake(_moveOrigin.x + dx / length * _stickRadius, _moveOrigin.y + dy / length * _stickRadius);
                dx = p.x - _moveOrigin.x; dy = p.y - _moveOrigin.y;
            } else if (length > _stickRadius) {
                // Drag the base along so the thumb never runs off the stick.
                _moveOrigin.x = p.x - dx / length * _stickRadius;
                _moveOrigin.y = p.y - dy / length * _stickRadius;
                dx = p.x - _moveOrigin.x; dy = p.y - _moveOrigin.y;
            }
            // A small dead zone keeps a resting thumb from creeping.
            CGFloat tilt = hypot(dx, dy) / _stickRadius;
            CGFloat gain = tilt < 0.12 ? 0 : (tilt - 0.12) / 0.88 / tilt;
            _move = CGPointMake(dx / _stickRadius * gain, -dy / _stickRadius * gain);
            _sprint = tilt > 0.94 && _move.y > 0.75;
            [self showStickAt:p];
        } else if (role == kRoleLook || (role < kRightCluster && _pads[role].center.x > CGRectGetWidth(self.bounds) * 0.45)) {
            CGPoint before = [touch previousLocationInView:self];
            CGFloat dx = p.x - before.x, dy = p.y - before.y;
            if (_stickLook) {
                _lookDelta.x += dx;
                _lookDelta.y += dy;
                _lookAt = CACurrentMediaTime();
            } else {
                // Swipe look: the game reads pointer travel exactly as it reads a mouse.
                // Faster swipes turn a little further, as mouse acceleration does.
                CGFloat boost = 1 + MIN(1.0, hypot(dx, dy) / 40);
                double x, y;
                _cursorRead(&x, &y);
                _cursorSet(x + dx * 3.2 * _sensitivity * boost, y + dy * 3.2 * _sensitivity * boost);
            }
        }
    }
    if (!_editing) [self publish];
}
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    for (UITouch *touch in touches) {
        NSNumber *entry = [_roles objectForKey:touch];
        if (!entry) continue;
        [_roles removeObjectForKey:touch];
        NSInteger role = entry.integerValue;
        if (role == kRoleMove) {
            _moving = _sprint = NO;
            _move = CGPointZero;
            [self restStick];
        } else if (role >= 0 && (_held & (1u << role))) {
            _held &= ~(1u << role);
            CFTimeInterval hold = role == kProne ? kProneHold : role == kFire ? _fireLead + kTapShot : kMinHold;
            _releaseAt[role] = _downAt[role] + hold;
            // Once the game has seen the press, give the screen to the pointer for its menu.
            if (role == kPause) _menuAt = MAX(CACurrentMediaTime(), _releaseAt[role]) + 0.05;
        }
    }
    [self stylePads];
    if (!_editing) [self publish];
}
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self touchesEnded:touches withEvent:event];
}
- (void)tick:(CADisplayLink *)link {
    // Show the controls when a match starts and give the pointer back when it ends.
    if (++_frame % 6 == 0 && _arena && *_arena) [self followGame:*_arena];
    if (!_play || _editing) return;
    if (_menuAt && CACurrentMediaTime() >= _menuAt) { [self setPlay:NO]; return; }
    // Timed presses end between touches, so the pad state is refreshed every frame.
    if (!_stickLook) { [self publish]; return; }
    // Stick look, after CyPort's MSLookFlushStick: finger speed over the last frame becomes the right stick,
    // full at about 650 points a second at speed 1, lightly smoothed, with a curve so slow swipes still turn
    // and a quick ease back to centre once the finger rests or lifts.
    CFTimeInterval dt = MAX(1 / 240.0, MIN(0.1, link.targetTimestamp - link.timestamp));
    CGFloat full = 650 / _sensitivity, rx = _lookDelta.x / dt / full, ry = -_lookDelta.y / dt / full;
    BOOL fingerMoving = _lookAt && CACurrentMediaTime() - _lookAt < 0.06;
    if (fingerMoving || _lookDelta.x || _lookDelta.y) {
        _lookSmooth = CGPointMake(_lookSmooth.x * 0.2 + rx * 0.8, _lookSmooth.y * 0.2 + ry * 0.8);
    } else {
        _lookSmooth = CGPointMake(_lookSmooth.x * 0.35, _lookSmooth.y * 0.35);
        if (fabs(_lookSmooth.x) < 0.03 && fabs(_lookSmooth.y) < 0.03) _lookSmooth = CGPointZero;
    }
    _lookDelta = CGPointZero;
    CGFloat length = hypot(_lookSmooth.x, _lookSmooth.y);
    if (length < 0.001) {
        _look = CGPointZero;
    } else {
        // The curve starts above the game's own stick dead zone.
        CGFloat out = 0.2 + 0.8 * pow(MIN(1.0, length), 0.6);
        _look = CGPointMake(_lookSmooth.x / length * out, _lookSmooth.y / length * out);
    }
    [self publish];
}
// A match is a running map that is not the menu map. Campaign has no known
// state address, so its map name alone decides.
- (void)followGame:(const uint8_t *)base {
    uint32_t state = 10, record = 0, text = 0;
    char map[sizeof(_map)] = {0};
    if (_stateAddress) memcpy(&state, base + _stateAddress, sizeof(state));
    memcpy(&record, base + _mapAddress, sizeof(record));
    if (record >= 0x10000 && record < 0xfff00000) memcpy(&text, base + record + 0x18, sizeof(text));
    if (text >= 0x10000 && text < 0xfff00000) memcpy(map, base + text, sizeof(map) - 1);
    BOOL inMatch = state == 10 && map[0] && !strstr(map, "frontend");
    if (state != _clientState || strcmp(map, _map)) {
        // One line per change, for the saved run log.
        fprintf(stderr, "[touch] state=%u map=%s match=%d\n", state, map, inMatch);
        _clientState = state;
        memcpy(_map, map, sizeof(_map));
    }
    if (inMatch != _inMatch) {
        _inMatch = inMatch;
        [self setPlay:inMatch];
    }
}
- (void)resetInput {
    [_roles removeAllObjects];
    _held = 0;
    _moving = _sprint = _aimLatched = NO;
    _move = _look = _lookDelta = _lookSmooth = CGPointZero;
    memset(_downAt, 0, sizeof(_downAt));
    memset(_releaseAt, 0, sizeof(_releaseAt));
    _fireLead = _menuAt = _lookAt = 0;
    [self restStick];
    [self stylePads];
    _sentButtons = ~0u;   // force one publish so the game always sees the release
    [self publish];
}
@end
