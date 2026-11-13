#import <Foundation/Foundation.h>
#import "ORIGTypes.h"

NS_ASSUME_NONNULL_BEGIN

/**
 * 登录 + 钥匙下发。所有 URL / 字段名 / header 均来自 BridgeConfig.json，
 * 即原包后端接口；bridge_mode=runtime 时改走原包 framework 的 ObjC 类。
 */
@interface ORIGAuthService : NSObject

+ (instancetype)shared;

- (void)sendSmsTo:(NSString *)phone completion:(ORIGCompletion)completion;
- (void)loginWithPhone:(NSString *)phone secret:(NSString *)secret completion:(ORIGCompletion)completion;
- (void)fetchBleKeysWithCompletion:(ORIGCompletion)completion;
- (void)logout;

/** 按 "data.accessToken" 这类点路径取值，兼容数组下标 "data.0.key" */
+ (id _Nullable)valueForDotPath:(NSString *)dotPath inObject:(id)object;

@end

NS_ASSUME_NONNULL_END
