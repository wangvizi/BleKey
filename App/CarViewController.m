#import "CarViewController.h"
#import "AppDelegate.h"
#import "ORIGConfig.h"
#import "ORIGSession.h"
#import "ORIGAuthService.h"
#import "ORIGBleKeyManager.h"

@interface CarViewController () <ORIGBleKeyManagerDelegate>
@property (nonatomic, strong) UILabel *stateLabel;
@property (nonatomic, strong) UILabel *deviceLabel;
@property (nonatomic, strong) UILabel *accountLabel;
@property (nonatomic, strong) UIButton *scanButton;
@property (nonatomic, strong) UIButton *disconnectButton;
@property (nonatomic, strong) UITextView *logView;
@property (nonatomic, strong) NSMutableArray<UIButton *> *commandButtons;
@property (nonatomic, strong) NSArray<NSString *> *commandNames;
@property (nonatomic, assign) NSInteger logLines;
@end

@implementation CarViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.title = @"蓝牙控车";
    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"退出登录" style:UIBarButtonItemStylePlain
                                       target:self action:@selector(onLogout)];

    ORIGConfig *cfg = [ORIGConfig shared];
    NSMutableArray *names = [NSMutableArray array];
    for (NSString *k in [[cfg dictionaryForPath:@"ble.commands"] allKeys]) {
        if (![k isEqualToString:@"auth"]) [names addObject:k];
    }
    [names sortUsingSelector:@selector(compare:)];
    _commandNames = names;
    _commandButtons = [NSMutableArray array];
    _logLines = 0;

    UIView *card = [[UIView alloc] init];
    card.backgroundColor = [UIColor secondarySystemBackgroundColor];
    card.layer.cornerRadius = 14;
    card.translatesAutoresizingMaskIntoConstraints = NO;

    _stateLabel = [[UILabel alloc] init];
    _stateLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    _stateLabel.textColor = [UIColor labelColor];
    _stateLabel.translatesAutoresizingMaskIntoConstraints = NO;

    _deviceLabel = [[UILabel alloc] init];
    _deviceLabel.font = [UIFont systemFontOfSize:13];
    _deviceLabel.textColor = [UIColor secondaryLabelColor];
    _deviceLabel.numberOfLines = 2;
    _deviceLabel.translatesAutoresizingMaskIntoConstraints = NO;

    _accountLabel = [[UILabel alloc] init];
    _accountLabel.font = [UIFont systemFontOfSize:12];
    _accountLabel.textColor = [UIColor tertiaryLabelColor];
    _accountLabel.numberOfLines = 2;
    _accountLabel.translatesAutoresizingMaskIntoConstraints = NO;

    [card addSubview:_stateLabel];
    [card addSubview:_deviceLabel];
    [card addSubview:_accountLabel];

    _scanButton = [self makeActionButton:@"扫描连接" filled:YES];
    [_scanButton addTarget:self action:@selector(onScan) forControlEvents:UIControlEventTouchUpInside];
    _disconnectButton = [self makeActionButton:@"断开" filled:NO];
    [_disconnectButton addTarget:self action:@selector(onDisconnect) forControlEvents:UIControlEventTouchUpInside];

    UIStackView *actions = [[UIStackView alloc] initWithArrangedSubviews:@[_scanButton, _disconnectButton]];
    actions.axis = UILayoutConstraintAxisHorizontal;
    actions.spacing = 10;
    actions.distribution = UIStackViewDistributionFillEqually;
    actions.translatesAutoresizingMaskIntoConstraints = NO;

    UIStackView *grid = [[UIStackView alloc] init];
    grid.axis = UILayoutConstraintAxisVertical;
    grid.spacing = 10;
    grid.distribution = UIStackViewDistributionFillEqually;
    grid.translatesAutoresizingMaskIntoConstraints = NO;
    NSDictionary *labels = [cfg dictionaryForPath:@"ble.command_labels"];
    NSInteger idx = 0;
    while (idx < (NSInteger)_commandNames.count) {
        UIStackView *row = [[UIStackView alloc] init];
        row.axis = UILayoutConstraintAxisHorizontal;
        row.spacing = 10;
        row.distribution = UIStackViewDistributionFillEqually;
        for (NSInteger col = 0; col < 3 && idx < (NSInteger)_commandNames.count; col++, idx++) {
            NSString *name = _commandNames[idx];
            NSString *title = [labels[name] description] ?: name;
            if (!title.length) title = name;
            UIButton *b = [self makeCommandButton:title tag:idx];
            [_commandButtons addObject:b];
            [row addArrangedSubview:b];
        }
        // 最后一行不足 3 个时用透明占位补齐，保持等宽
        while (row.arrangedSubviews.count < 3) {
            UIView *spacer = [[UIView alloc] init];
            spacer.backgroundColor = [UIColor clearColor];
            [row addArrangedSubview:spacer];
        }
        [grid addArrangedSubview:row];
    }
    NSInteger rows = ((NSInteger)_commandNames.count + 2) / 3;

    UILabel *logTitle = [[UILabel alloc] init];
    logTitle.text = @"通信日志";
    logTitle.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    logTitle.textColor = [UIColor secondaryLabelColor];
    logTitle.translatesAutoresizingMaskIntoConstraints = NO;

    _logView = [[UITextView alloc] init];
    _logView.editable = NO;
    _logView.selectable = YES;
    _logView.backgroundColor = [UIColor tertiarySystemBackgroundColor];
    _logView.textColor = [UIColor labelColor];
    _logView.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    _logView.layer.cornerRadius = 10;
    _logView.translatesAutoresizingMaskIntoConstraints = NO;

    [self.view addSubview:card];
    [self.view addSubview:actions];
    [self.view addSubview:grid];
    [self.view addSubview:logTitle];
    [self.view addSubview:_logView];

    CGFloat pad = 16;
    [NSLayoutConstraint activateConstraints:@[
        [card.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:12],
        [card.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:pad],
        [card.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-pad],

        [_stateLabel.topAnchor constraintEqualToAnchor:card.topAnchor constant:14],
        [_stateLabel.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:14],
        [_stateLabel.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-14],
        [_deviceLabel.topAnchor constraintEqualToAnchor:_stateLabel.bottomAnchor constant:6],
        [_deviceLabel.leadingAnchor constraintEqualToAnchor:_stateLabel.leadingAnchor],
        [_deviceLabel.trailingAnchor constraintEqualToAnchor:_stateLabel.trailingAnchor],
        [_accountLabel.topAnchor constraintEqualToAnchor:_deviceLabel.bottomAnchor constant:4],
        [_accountLabel.leadingAnchor constraintEqualToAnchor:_stateLabel.leadingAnchor],
        [_accountLabel.trailingAnchor constraintEqualToAnchor:_stateLabel.trailingAnchor],
        [card.bottomAnchor constraintEqualToAnchor:_accountLabel.bottomAnchor constant:14],

        [actions.topAnchor constraintEqualToAnchor:card.bottomAnchor constant:14],
        [actions.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:pad],
        [actions.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-pad],
        [_scanButton.heightAnchor constraintEqualToConstant:44],

        [grid.topAnchor constraintEqualToAnchor:actions.bottomAnchor constant:14],
        [grid.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:pad],
        [grid.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-pad],
        [grid.heightAnchor constraintEqualToConstant:MAX(1, rows) * 46 + (MAX(1, rows) - 1) * 10],

        [logTitle.topAnchor constraintEqualToAnchor:grid.bottomAnchor constant:16],
        [logTitle.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:pad],

        [_logView.topAnchor constraintEqualToAnchor:logTitle.bottomAnchor constant:6],
        [_logView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:pad],
        [_logView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-pad],
        [_logView.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-12],
    ]];

    [self refreshInfo];
    [self appendLog:[NSString stringWithFormat:@"配置：%@", [ORIGConfig shared].configurationHint]];
    [self appendLog:[NSString stringWithFormat:@"接口：%@", [[ORIGConfig shared] stringForPath:@"api.base" default:@""]]];
}

- (UIButton *)makeActionButton:(NSString *)title filled:(BOOL)filled {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    b.layer.cornerRadius = 10;
    b.translatesAutoresizingMaskIntoConstraints = NO;
    if (filled) {
        b.backgroundColor = [UIColor systemBlueColor];
        [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    } else {
        b.backgroundColor = [UIColor secondarySystemFillColor];
        [b setTitleColor:[UIColor labelColor] forState:UIControlStateNormal];
    }
    return b;
}

- (UIButton *)makeCommandButton:(NSString *)title tag:(NSInteger)tag {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    b.backgroundColor = [UIColor tertiarySystemBackgroundColor];
    [b setTitleColor:[UIColor labelColor] forState:UIControlStateNormal];
    b.layer.cornerRadius = 10;
    b.tag = tag;
    [b addTarget:self action:@selector(onCommand:) forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [ORIGBleKeyManager shared].delegate = self;
    [self bleManagerDidUpdateState:[ORIGBleKeyManager shared].state info:@""];
    [self refreshInfo];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    if ([ORIGBleKeyManager shared].delegate == self) [ORIGBleKeyManager shared].delegate = nil;
}

- (void)refreshInfo {
    ORIGSession *s = [ORIGSession shared];
    _deviceLabel.text = [NSString stringWithFormat:@"设备：%@   车辆：%@",
                         s.deviceName.length ? s.deviceName : @"未记录",
                         s.vehicleId.length ? s.vehicleId : @"未记录"];
    _accountLabel.text = [NSString stringWithFormat:@"账号：%@   钥匙密钥：%@   手机号：%@",
                          [ORIGConfig shared].sourceBundleId.length ? [ORIGConfig shared].sourceBundleId : @"未配置",
                          s.bleKeyHex.length ? @"已下发" : @"未取到",
                          s.phone.length ? s.phone : @"-"];
}

#pragma mark - 动作

- (void)onScan {
    [self appendLog:@"--- 开始扫描 ---"];
    [[ORIGBleKeyManager shared] startScan];
}

- (void)onDisconnect {
    [self appendLog:@"--- 主动断开 ---"];
    [[ORIGBleKeyManager shared] disconnect];
}

- (void)onCommand:(UIButton *)sender {
    NSInteger idx = sender.tag;
    if (idx < 0 || idx >= (NSInteger)_commandNames.count) return;
    NSString *cmd = _commandNames[idx];
    [self setCommandsEnabled:NO];
    [self appendLog:[NSString stringWithFormat:@"--- 下发 %@ ---", cmd]];
    __weak typeof(self) ws = self;
    [[ORIGBleKeyManager shared] sendCommand:cmd completion:^(BOOL ok, id payload, NSString *err) {
        [ws setCommandsEnabled:YES];
        if (ok) {
            NSDictionary *d = [payload isKindOfClass:NSDictionary.class] ? payload : @{};
            [ws appendLog:[NSString stringWithFormat:@"%@ 成功，应答 cmd=%@ seq=%@",
                           cmd, d[@"command"] ?: @"-", d[@"seq"] ?: @"-"]];
        } else {
            [ws appendLog:[NSString stringWithFormat:@"%@ 失败：%@", cmd, err ?: @"unknown"]];
        }
    }];
}

- (void)setCommandsEnabled:(BOOL)enabled {
    for (UIButton *b in _commandButtons) { b.enabled = enabled; b.alpha = enabled ? 1.0 : 0.5; }
}

- (void)onLogout {
    [[ORIGBleKeyManager shared] disconnect];
    [[ORIGAuthService shared] logout];
    AppDelegate *app = (AppDelegate *)[UIApplication sharedApplication].delegate;
    [app showLoginAnimated:YES];
}

#pragma mark - ORIGBleKeyManagerDelegate

- (void)bleManagerDidUpdateState:(ORIGBleState)state info:(NSString *)info {
    _stateLabel.text = ORIGBleStateName(state);
    _stateLabel.textColor = (state == ORIGBleStateReady) ? [UIColor systemGreenColor]
                          : (state == ORIGBleStateFailed) ? [UIColor systemRedColor]
                          : [UIColor labelColor];
    _scanButton.enabled = (state != ORIGBleStateConnecting);
    // 状态变化的文字日志由 bleManagerDidLog: 统一输出，这里只刷新 UI，避免重复
}

- (void)bleManagerDidLog:(NSString *)line { [self appendLog:line]; }

- (void)appendLog:(NSString *)line {
    if (!line.length) return;
    // BLE 回调与 UI 事件都在主队列，这里同步追加，保证日志顺序且不需要 block 捕获 ivar
    NSDateFormatter *f = [[NSDateFormatter alloc] init];
    f.dateFormat = @"HH:mm:ss.SSS";
    NSString *entry = [NSString stringWithFormat:@"%@ %@\n", [f stringFromDate:[NSDate date]], line];
    NSString *text = [_logView.text stringByAppendingString:entry] ?: entry;
    _logLines += 1;
    if (_logLines > 300) {
        NSMutableArray *parts = [[text componentsSeparatedByString:@"\n"] mutableCopy];
        while (parts.count > 250) [parts removeObjectAtIndex:0];
        text = [parts componentsJoinedByString:@"\n"];
        _logLines = parts.count;
    }
    _logView.text = text;
    [_logView scrollRangeToVisible:NSMakeRange(_logView.text.length, 0)];
}

@end
