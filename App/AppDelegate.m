#import "AppDelegate.h"
#import "LoginViewController.h"
#import "CarViewController.h"
#import "ORIGConfig.h"
#import "ORIGSession.h"

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application
didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    // 提前触发配置与登录态初始化，首屏就能显示正确的配置来源提示
    (void)[ORIGConfig shared];
    (void)[ORIGSession shared];

    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.backgroundColor = [UIColor systemBackgroundColor];
    [self setRootForLoggedIn:[ORIGSession shared].isLoggedIn animated:NO];
    [self.window makeKeyAndVisible];
    return YES;
}

- (void)showLoginAnimated:(BOOL)animated { [self setRootForLoggedIn:NO animated:animated]; }
- (void)showCarAnimated:(BOOL)animated   { [self setRootForLoggedIn:YES animated:animated]; }

- (void)setRootForLoggedIn:(BOOL)loggedIn animated:(BOOL)animated {
    UIViewController *root = loggedIn ? [[CarViewController alloc] init] : [[LoginViewController alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:root];
    nav.navigationBar.prefersLargeTitles = NO;

    if (!animated || !self.window.rootViewController) {
        self.window.rootViewController = nav;
        return;
    }
    [UIView transitionWithView:self.window duration:0.3
                       options:UIViewAnimationOptionTransitionCrossDissolve
                    animations:^{
        self.window.rootViewController = nav;
    } completion:nil];
}

- (void)applicationWillResignActive:(UIApplication *)application {
    // 进后台不主动断开，保留 BLE central 后台模式以便钥匙仍在近场时可用
}

@end
