#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * 单一配置入口。所有域名、路径、字段名、UUID、指令码、帧格式都来自
 * Generated/BridgeConfig.json（由 Tools/extract_ipa.py 从原包生成）。
 * 代码里不写死任何原包常量。
 */
@interface ORIGConfig : NSObject

+ (instancetype)shared;

@property (nonatomic, strong, readonly) NSDictionary *raw;
@property (nonatomic, copy, readonly) NSString *bridgeMode;
@property (nonatomic, assign, readonly) BOOL configured;
@property (nonatomic, copy, readonly) NSString *configurationHint;
@property (nonatomic, copy, readonly) NSString *sourceBundleId;

- (id _Nullable)objectForPath:(NSString *)dotPath;
- (NSString *)stringForPath:(NSString *)dotPath default:(NSString *)fallback;
- (NSDictionary *)dictionaryForPath:(NSString *)dotPath;
- (NSArray *)arrayForPath:(NSString *)dotPath;
- (NSInteger)integerForPath:(NSString *)dotPath default:(NSInteger)fallback;
- (double)doubleForPath:(NSString *)dotPath default:(double)fallback;
- (BOOL)boolForPath:(NSString *)dotPath default:(BOOL)fallback;

/** base(api.base) + path(api.<pathKey>) 拼成完整 URL，自动处理首尾斜杠 */
- (NSURL * _Nullable)urlForPathKey:(NSString *)pathKey;

@end

NS_ASSUME_NONNULL_END
