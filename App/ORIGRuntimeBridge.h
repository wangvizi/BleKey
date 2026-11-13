#import <Foundation/Foundation.h>
#import "ORIGTypes.h"

NS_ASSUME_NONNULL_BEGIN

/**
 * 可选链路：直接加载原包自带的动态 framework，用 ObjC runtime 调原包的登录/蓝牙类。
 * 只有 bridge_mode=runtime 且 runtime.enabled=YES 时启用；
 * 默认走 ORIGAuthService 的 HTTP 链路（复用原包后端接口），不依赖 framework 能否 dlopen。
 */
@interface ORIGRuntimeBridge : NSObject

+ (instancetype)shared;

@property (nonatomic, assign, readonly) BOOL available;
@property (nonatomic, copy, readonly) NSString *loadError;

- (void)invokeClass:(NSString *)className
           selector:(NSString *)selectorName
                arg:(id _Nullable)arg
         completion:(ORIGCompletion)completion;

@end

NS_ASSUME_NONNULL_END
