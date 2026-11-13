#import "LoginViewController.h"
#import "AppDelegate.h"
#import "ORIGConfig.h"
#import "ORIGAuthService.h"
#import "ORIGSession.h"
#import "CarViewController.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

@interface LoginViewController () <UITextFieldDelegate, UIDocumentPickerDelegate>
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *subtitleLabel;
@property (nonatomic, strong) UILabel *hintLabel;
@property (nonatomic, strong) UITextField *phoneField;
@property (nonatomic, strong) UITextField *secretField;
@property (nonatomic, strong) UIButton *codeButton;
@property (nonatomic, strong) UIButton *loginButton;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) UIButton *configButton;
@property (nonatomic, strong) NSTimer *countdownTimer;
@property (nonatomic, assign) NSInteger remaining;
@end

@implementation LoginViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.title = @"登录";

    ORIGConfig *cfg = [ORIGConfig shared];
    BOOL isPassword = [[[cfg stringForPath:@"api.login_type" default:@"sms"] lowercaseString]
                       isEqualToString:@"password"];

    _titleLabel = [[UILabel alloc] init];
    _titleLabel.text = @"蓝牙钥匙";
    _titleLabel.font = [UIFont systemFontOfSize:30 weight:UIFontWeightBold];
    _titleLabel.textColor = [UIColor labelColor];
    _titleLabel.textAlignment = NSTextAlignmentCenter;
    _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;

    _subtitleLabel = [[UILabel alloc] init];
    _subtitleLabel.text = [NSString stringWithFormat:@"登录原车厂账号 · 接口来源 %@",
                           cfg.sourceBundleId.length ? cfg.sourceBundleId : @"未配置"];
    _subtitleLabel.font = [UIFont systemFontOfSize:13];
    _subtitleLabel.textColor = [UIColor secondaryLabelColor];
    _subtitleLabel.textAlignment = NSTextAlignmentCenter;
    _subtitleLabel.numberOfLines = 2;
    _subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;

    _hintLabel = [[UILabel alloc] init];
    _hintLabel.text = cfg.configurationHint;
    _hintLabel.font = [UIFont systemFontOfSize:12];
    _hintLabel.textColor = cfg.configured ? [UIColor secondaryLabelColor] : [UIColor systemRedColor];
    _hintLabel.numberOfLines = 0;
    _hintLabel.textAlignment = NSTextAlignmentCenter;
    _hintLabel.translatesAutoresizingMaskIntoConstraints = NO;

    _phoneField = [self makeFieldPlaceholder:@"手机号" keyboard:UIKeyboardTypePhonePad secure:NO];
    _secretField = [self makeFieldPlaceholder:isPassword ? @"密码" : @"验证码"
                                     keyboard:isPassword ? UIKeyboardTypeDefault : UIKeyboardTypeNumberPad
                                       secure:isPassword];
    _phoneField.text = [ORIGSession shared].phone ?: @"";

    _codeButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [_codeButton setTitle:isPassword ? @"忘记密码" : @"获取验证码" forState:UIControlStateNormal];
    _codeButton.titleLabel.font = [UIFont systemFontOfSize:14];
    [_codeButton addTarget:self action:@selector(onCodeTapped) forControlEvents:UIControlEventTouchUpInside];
    _codeButton.translatesAutoresizingMaskIntoConstraints = NO;
    if (isPassword) _codeButton.enabled = NO;

    _loginButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _loginButton.backgroundColor = [UIColor systemBlueColor];
    [_loginButton setTitle:@"登 录" forState:UIControlStateNormal];
    [_loginButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    _loginButton.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    _loginButton.layer.cornerRadius = 12;
    [_loginButton addTarget:self action:@selector(onLoginTapped) forControlEvents:UIControlEventTouchUpInside];
    _loginButton.translatesAutoresizingMaskIntoConstraints = NO;

    _statusLabel = [[UILabel alloc] init];
    _statusLabel.font = [UIFont systemFontOfSize:13];
    _statusLabel.textColor = [UIColor secondaryLabelColor];
    _statusLabel.numberOfLines = 0;
    _statusLabel.textAlignment = NSTextAlignmentCenter;
    _statusLabel.translatesAutoresizingMaskIntoConstraints = NO;

    _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    _spinner.hidesWhenStopped = YES;
    _spinner.translatesAutoresizingMaskIntoConstraints = NO;

    _configButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [_configButton setTitle:@"配置 · 导入 / 导出 / 恢复" forState:UIControlStateNormal];
    _configButton.titleLabel.font = [UIFont systemFontOfSize:13];
    [_configButton addTarget:self action:@selector(onConfigTapped)
            forControlEvents:UIControlEventTouchUpInside];
    _configButton.translatesAutoresizingMaskIntoConstraints = NO;

    UIView *card = [[UIView alloc] init];
    card.backgroundColor = [UIColor secondarySystemBackgroundColor];
    card.layer.cornerRadius = 14;
    card.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:card];
    [card addSubview:_phoneField];
    [card addSubview:_secretField];
    [card addSubview:_codeButton];

    [self.view addSubview:_titleLabel];
    [self.view addSubview:_subtitleLabel];
    [self.view addSubview:_hintLabel];
    [self.view addSubview:_loginButton];
    [self.view addSubview:_statusLabel];
    [self.view addSubview:_spinner];
    [self.view addSubview:_configButton];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self
                                                                          action:@selector(dismissKeyboard)];
    [self.view addGestureRecognizer:tap];

    CGFloat pad = 24;
    [NSLayoutConstraint activateConstraints:@[
        [_titleLabel.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:36],
        [_titleLabel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:pad],
        [_titleLabel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-pad],

        [_subtitleLabel.topAnchor constraintEqualToAnchor:_titleLabel.bottomAnchor constant:8],
        [_subtitleLabel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:pad],
        [_subtitleLabel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-pad],

        [_hintLabel.topAnchor constraintEqualToAnchor:_subtitleLabel.bottomAnchor constant:18],
        [_hintLabel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:pad],
        [_hintLabel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-pad],

        [card.topAnchor constraintEqualToAnchor:_hintLabel.bottomAnchor constant:24],
        [card.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:pad],
        [card.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-pad],

        [_phoneField.topAnchor constraintEqualToAnchor:card.topAnchor constant:8],
        [_phoneField.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:14],
        [_phoneField.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-14],
        [_phoneField.heightAnchor constraintEqualToConstant:46],

        [_secretField.topAnchor constraintEqualToAnchor:_phoneField.bottomAnchor constant:2],
        [_secretField.leadingAnchor constraintEqualToAnchor:_phoneField.leadingAnchor],
        [_secretField.trailingAnchor constraintEqualToAnchor:_codeButton.leadingAnchor constant:-8],
        [_secretField.heightAnchor constraintEqualToConstant:46],

        [_codeButton.centerYAnchor constraintEqualToAnchor:_secretField.centerYAnchor],
        [_codeButton.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-14],
        [_codeButton.widthAnchor constraintEqualToConstant:96],
        [card.bottomAnchor constraintEqualToAnchor:_secretField.bottomAnchor constant:8],

        [_loginButton.topAnchor constraintEqualToAnchor:card.bottomAnchor constant:24],
        [_loginButton.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:pad],
        [_loginButton.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-pad],
        [_loginButton.heightAnchor constraintEqualToConstant:50],

        [_spinner.topAnchor constraintEqualToAnchor:_loginButton.bottomAnchor constant:16],
        [_spinner.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],

        [_statusLabel.topAnchor constraintEqualToAnchor:_spinner.bottomAnchor constant:10],
        [_statusLabel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:pad],
        [_statusLabel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-pad],

        [_configButton.topAnchor constraintEqualToAnchor:_statusLabel.bottomAnchor constant:18],
        [_configButton.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [_configButton.heightAnchor constraintEqualToConstant:32],
    ]];

    [self refreshConfigUI];
}

- (UITextField *)makeFieldPlaceholder:(NSString *)ph keyboard:(UIKeyboardType)kb secure:(BOOL)secure {
    UITextField *f = [[UITextField alloc] init];
    f.placeholder = ph;
    f.font = [UIFont systemFontOfSize:16];
    f.textColor = [UIColor labelColor];
    f.keyboardType = kb;
    f.secureTextEntry = secure;
    f.autocorrectionType = UITextAutocorrectionTypeNo;
    f.clearButtonMode = UITextFieldViewModeWhileEditing;
    f.borderStyle = UITextBorderStyleNone;
    f.delegate = self;
    f.translatesAutoresizingMaskIntoConstraints = NO;
    return f;
}

- (void)dismissKeyboard { [self.view endEditing:YES]; }

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    if (textField == _secretField) [self onLoginTapped];
    return YES;
}

#pragma mark - 动作

- (void)onCodeTapped {
    [self dismissKeyboard];
    NSString *phone = _phoneField.text ?: @"";
    if (phone.length < 6) { [self setStatus:@"请输入完整手机号" error:YES]; return; }
    [self setBusy:YES];
    [self setStatus:@"正在请求验证码…" error:NO];
    __weak typeof(self) ws = self;
    [[ORIGAuthService shared] sendSmsTo:phone completion:^(BOOL ok, id payload, NSString *err) {
        [ws setBusy:NO];
        if (!ok) { [ws setStatus:err ?: @"验证码发送失败" error:YES]; return; }
        [ws setStatus:@"验证码已发送" error:NO];
        [ws startCountdown];
    }];
}

- (void)onLoginTapped {
    [self dismissKeyboard];
    NSString *phone = _phoneField.text ?: @"";
    NSString *secret = _secretField.text ?: @"";
    ORIGConfig *cfg = [ORIGConfig shared];
    BOOL isPassword = [[[cfg stringForPath:@"api.login_type" default:@"sms"] lowercaseString]
                       isEqualToString:@"password"];
    if (phone.length < 6) { [self setStatus:@"请输入完整手机号" error:YES]; return; }
    if (secret.length < (isPassword ? 1 : 4)) {
        [self setStatus:isPassword ? @"请输入密码" : @"请输入验证码" error:YES]; return;
    }
    if (!cfg.configured) { [self setStatus:cfg.configurationHint error:YES]; return; }

    [self setBusy:YES];
    [self setStatus:@"正在登录…" error:NO];
    __weak typeof(self) ws = self;
    [[ORIGAuthService shared] loginWithPhone:phone secret:secret completion:^(BOOL ok, id payload, NSString *err) {
        if (!ok) {
            [ws setBusy:NO];
            [ws setStatus:err ?: @"登录失败" error:YES];
            return;
        }
        [ws setStatus:@"登录成功，正在拉取蓝牙钥匙…" error:NO];
        [[ORIGAuthService shared] fetchBleKeysWithCompletion:^(BOOL keyOk, id keyPayload, NSString *keyErr) {
            [ws setBusy:NO];
            NSString *note = keyOk ? @"" : [NSString stringWithFormat:@"（钥匙下发失败：%@）", keyErr ?: @"unknown"];
            [ws setStatus:[NSString stringWithFormat:@"登录成功%@", note] error:NO];
            AppDelegate *app = (AppDelegate *)[UIApplication sharedApplication].delegate;
            [app showCarAnimated:YES];
        }];
    }];
}

#pragma mark - 配置导入 / 导出（真机上直接换接口，不重编译）

- (void)refreshConfigUI {
    ORIGConfig *cfg = [ORIGConfig shared];
    _hintLabel.text = cfg.configurationHint;
    _hintLabel.textColor = cfg.configured ? [UIColor secondaryLabelColor] : [UIColor systemRedColor];
    _subtitleLabel.text = [NSString stringWithFormat:@"登录原车厂账号 · %@ · 接口来源 %@",
                           cfg.configSource,
                           cfg.sourceBundleId.length ? cfg.sourceBundleId : @"未配置"];

    BOOL isPassword = [[[cfg stringForPath:@"api.login_type" default:@"sms"] lowercaseString]
                       isEqualToString:@"password"];
    _secretField.placeholder = isPassword ? @"密码" : @"验证码";
    _secretField.keyboardType = isPassword ? UIKeyboardTypeDefault : UIKeyboardTypeNumberPad;
    _secretField.secureTextEntry = isPassword;
    [_codeButton setTitle:isPassword ? @"忘记密码" : @"获取验证码" forState:UIControlStateNormal];
    [_configButton setTitle:cfg.hasOverride ? @"配置 · 已导入（点此管理）" : @"配置 · 导入 / 导出 / 恢复"
                  forState:UIControlStateNormal];
    [self setBusy:NO];
}

- (void)onConfigTapped {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"接口配置"
                                                                  message:[ORIGConfig shared].configSource
                                                           preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) ws = self;
    [sheet addAction:[UIAlertAction actionWithTitle:@"导入 BridgeConfig.json"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) { [ws pickConfig]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"导出当前配置（改完再导回）"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) { [ws exportConfig]; }]];
    if ([ORIGConfig shared].hasOverride) {
        [sheet addAction:[UIAlertAction actionWithTitle:@"恢复内置配置"
                                                  style:UIAlertActionStyleDestructive
                                                handler:^(UIAlertAction *a) { [ws resetConfig]; }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = _configButton;
    sheet.popoverPresentationController.sourceRect = _configButton.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)pickConfig {
    UTType *jsonType = [UTType typeWithIdentifier:@"public.json"] ?: UTTypeJSON;
    UIDocumentPickerViewController *picker =
        [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[jsonType]];
    picker.allowsMultipleSelection = NO;
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller
  didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *url = urls.firstObject;
    if (!url) return;
    NSError *err = nil;
    BOOL ok = [[ORIGConfig shared] applyConfigFromURL:url error:&err];
    [self refreshConfigUI];
    [self setStatus:ok ? @"配置已导入，登录与蓝牙指令立即生效"
                       : [NSString stringWithFormat:@"导入失败：%@", err.localizedDescription ?: @"unknown"]
              error:!ok];
}

- (void)exportConfig {
    NSData *data = [NSJSONSerialization dataWithJSONObject:[ORIGConfig shared].raw
                                                   options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys
                                                     error:NULL];
    if (!data) { [self setStatus:@"导出失败：当前配置无法序列化" error:YES]; return; }
    NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:@"BridgeConfig.json"];
    if (![data writeToFile:tmp atomically:YES]) {
        [self setStatus:@"导出失败：临时文件写入失败" error:YES]; return;
    }
    UIActivityViewController *avc = [[UIActivityViewController alloc]
        initWithActivityItems:@[[NSURL fileURLWithPath:tmp]] applicationActivities:nil];
    avc.popoverPresentationController.sourceView = _configButton;
    avc.popoverPresentationController.sourceRect = _configButton.bounds;
    [self presentViewController:avc animated:YES completion:nil];
    [self setStatus:@"已导出 BridgeConfig.json，改完用「导入」放回" error:NO];
}

- (void)resetConfig {
    NSError *err = nil;
    BOOL ok = [[ORIGConfig shared] clearOverrideWithError:&err];
    [self refreshConfigUI];
    [self setStatus:ok ? @"已恢复 Bundle 内置配置"
                       : [NSString stringWithFormat:@"恢复失败：%@", err.localizedDescription ?: @"unknown"]
              error:!ok];
}

- (void)setStatus:(NSString *)text error:(BOOL)isError {
    _statusLabel.text = text;
    _statusLabel.textColor = isError ? [UIColor systemRedColor] : [UIColor secondaryLabelColor];
}

- (void)setBusy:(BOOL)busy {
    ORIGConfig *cfg = [ORIGConfig shared];
    BOOL isPassword = [[[cfg stringForPath:@"api.login_type" default:@"sms"] lowercaseString]
                       isEqualToString:@"password"];
    _loginButton.enabled = !busy;
    _loginButton.alpha = busy ? 0.6 : 1.0;
    _codeButton.enabled = (!isPassword) && !busy && _remaining == 0;
    busy ? [_spinner startAnimating] : [_spinner stopAnimating];
}

- (void)startCountdown {
    _remaining = 60;
    _countdownTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self
                                                     selector:@selector(countdownTick) userInfo:nil repeats:YES];
    [self updateCodeButton];
}

- (void)countdownTick {
    _remaining -= 1;
    if (_remaining <= 0) {
        [_countdownTimer invalidate];
        _countdownTimer = nil;
        _remaining = 0;
    }
    [self updateCodeButton];
}

- (void)updateCodeButton {
    ORIGConfig *cfg = [ORIGConfig shared];
    BOOL isPassword = [[[cfg stringForPath:@"api.login_type" default:@"sms"] lowercaseString]
                       isEqualToString:@"password"];
    if (isPassword) return;
    if (_remaining > 0) {
        _codeButton.enabled = NO;
        [_codeButton setTitle:[NSString stringWithFormat:@"%lds", (long)_remaining]
                     forState:UIControlStateDisabled];
    } else {
        _codeButton.enabled = YES;
        [_codeButton setTitle:@"获取验证码" forState:UIControlStateNormal];
    }
}

- (void)dealloc { [_countdownTimer invalidate]; }

@end
