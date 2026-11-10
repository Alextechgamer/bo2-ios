// UIKit touch input shares the game's XInput slot with a hardware controller.
extern "C" void ios_touch_pad(unsigned buttons, bool aim, bool fire, float lx, float ly, float rx, float ry);

@interface BO2TouchControls : UIView
- (void)resetInput;
@end
@implementation BO2TouchControls {
    NSArray<UIButton *> *_actions;
    NSArray<UILabel *> *_sticks;
    UIButton *_toggle;
    CGPoint _axes[2];
    unsigned _held;
    BOOL _shown;
}
- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    NSMutableArray *actions = [NSMutableArray array];
    for (NSString *name in @[@"A / OK", @"B / Back", @"Reload", @"Swap", @"Aim", @"Fire", @"Pause", @"↑", @"↓", @"←", @"→"]) {
        UIButton *b = [self button:name];
        b.tag = actions.count;
        [b addTarget:self action:@selector(press:) forControlEvents:UIControlEventTouchDown | UIControlEventTouchDragEnter];
        [b addTarget:self action:@selector(releaseButton:) forControlEvents:UIControlEventTouchUpInside |
            UIControlEventTouchUpOutside | UIControlEventTouchCancel | UIControlEventTouchDragExit];
        [actions addObject:b];
    }
    _actions = actions;
    NSMutableArray *sticks = [NSMutableArray array];
    for (NSString *name in @[@"Move", @"Look"]) {
        UILabel *stick = [UILabel new];
        stick.text = name;
        stick.tag = sticks.count;
        stick.textAlignment = NSTextAlignmentCenter;
        stick.textColor = UIColor.whiteColor;
        stick.backgroundColor = [UIColor.blackColor colorWithAlphaComponent:0.42];
        stick.layer.borderWidth = 1;
        stick.layer.borderColor = [UIColor.whiteColor colorWithAlphaComponent:0.5].CGColor;
        stick.userInteractionEnabled = YES;
        UILongPressGestureRecognizer *pan = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(moveStick:)];
        pan.minimumPressDuration = 0;
        [stick addGestureRecognizer:pan];
        [self addSubview:stick];
        [sticks addObject:stick];
    }
    _sticks = sticks;
    _toggle = [self button:@"Controls"];
    [_toggle addTarget:self action:@selector(toggle) forControlEvents:UIControlEventTouchUpInside];
    [self toggle];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(resetInput)
        name:UIApplicationWillResignActiveNotification object:nil];
    return self;
}
- (UIButton *)button:(NSString *)title {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
    [button setTitle:title forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont boldSystemFontOfSize:13];
    button.backgroundColor = [UIColor.blackColor colorWithAlphaComponent:0.48];
    button.layer.cornerRadius = 10;
    [self addSubview:button];
    return button;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect safe = UIEdgeInsetsInsetRect(self.bounds, self.safeAreaInsets);
    CGFloat left=CGRectGetMinX(safe)+8, right=CGRectGetMaxX(safe)-8, bottom=CGRectGetMaxY(safe)-6;
    CGFloat size=MIN(90, safe.size.height*0.27);
    _sticks[0].frame = CGRectMake(left,bottom-size,size,size);
    _sticks[1].frame = CGRectMake(right-size,bottom-size,size,size);
    for (UILabel *stick in _sticks) {
        stick.layer.cornerRadius = size/2;
        stick.clipsToBounds = YES;
    }
    for (NSInteger i=0;i<6;i++) {
        _actions[i].frame = CGRectMake(right-size-8-64*(3-i%3), bottom-44-46*(i/3), 60, 44);
    }
    _actions[6].frame=CGRectMake(left+72,CGRectGetMinY(safe)+3,60,44);
    CGFloat center=left+size+42, y=bottom-76;
    _actions[7].frame=CGRectMake(center-20,y-40,40,40);
    _actions[8].frame=CGRectMake(center-20,y+40,40,40);
    _actions[9].frame=CGRectMake(center-62,y,40,40);
    _actions[10].frame=CGRectMake(center+22,y,40,40);
    _toggle.frame=CGRectMake(left,CGRectGetMinY(safe)+3,68,44);
}
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    return hit == self ? nil : hit;
}
- (void)toggle {
    _shown = !_shown;
    for (UIView *v in _actions) v.hidden = !_shown;
    for (UIView *v in _sticks) v.hidden = !_shown;
    if (!_shown) [self resetInput];
}
- (void)publish {
    static const unsigned masks[] = {0x1000,0x2000,0x4000,0x8000,0,0,0x10,1,2,4,8};
    unsigned buttons=0;
    for (unsigned i=0;i<sizeof(masks)/sizeof(masks[0]);i++) if (_held & (1u<<i)) buttons |= masks[i];
    ios_touch_pad(buttons, (_held & 16)!=0, (_held & 32)!=0, _axes[0].x, _axes[0].y, _axes[1].x, _axes[1].y);
}
- (void)press:(UIButton *)b { _held |= 1u << b.tag; b.alpha=0.65; [self publish]; }
- (void)releaseButton:(UIButton *)b { _held &= ~(1u << b.tag); b.alpha=1; [self publish]; }
- (void)moveStick:(UILongPressGestureRecognizer *)pan {
    UIView *v=pan.view;
    CGPoint pos=CGPointZero;
    if (pan.state==UIGestureRecognizerStateBegan || pan.state==UIGestureRecognizerStateChanged) {
        CGPoint p=[pan locationInView:v];
        CGFloat r=v.bounds.size.width/2;
        pos=CGPointMake((p.x-r)/r,(r-p.y)/r);
        CGFloat length=MAX(1.0,hypot(pos.x,pos.y));
        pos=CGPointMake(pos.x/length,pos.y/length);
    }
    _axes[v.tag]=pos;
    [self publish];
}
- (void)resetInput {
    _held=0; _axes[0]=CGPointZero; _axes[1]=CGPointZero;
    for (UIButton *b in _actions) b.alpha=1;
    [self publish];
}
@end
