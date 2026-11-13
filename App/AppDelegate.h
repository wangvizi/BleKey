#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface AppDelegate : UIResponder <UIApplicationDelegate>

@property (nonatomic, strong) UIWindow *window;

- (void)showLoginAnimated:(BOOL)animated;
- (void)showCarAnimated:(BOOL)animated;

@end

NS_ASSUME_NONNULL_END
