#import "ORIGConfig.h"

@implementation ORIGConfig {
    NSDictionary *_raw;
    NSString *_hint;
}

+ (instancetype)shared {
    static ORIGConfig *inst;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ inst = [[ORIGConfig alloc] init]; });
    return inst;
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;

    NSString *path = [[NSBundle mainBundle] pathForResource:@"BridgeConfig" ofType:@"json"];
    NSDictionary *dict = nil;
    if (path) {
        NSData *data = [NSData dataWithContentsOfFile:path];
        if (data) {
            id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
            if ([obj isKindOfClass:NSDictionary.class]) dict = obj;
        }
    }
    _raw = dict ?: @{};

    NSString *base = [self stringForPath:@"api.base" default:@""];
    NSString *src  = [self stringForPath:@"source_bundle_id" default:@""];
    NSString *from = [self stringForPath:@"generated_from" default:@""];
    BOOL placeholder = ([base rangeOfString:@"example.invalid"].location != NSNotFound);
    _configured = (src.length > 0 && base.length > 0 && !placeholder &&
                   ([base hasPrefix:@"http://"] || [base hasPrefix:@"https://"]));

    if (!path) {
        _hint = @"Bundle 内缺少 BridgeConfig.json：打包脚本未把配置文件放进 .app。";
    } else if (_configured == NO) {
        _hint = [NSString stringWithFormat:
                 @"当前是模板配置（generated_from=%@）。请先用 Tools/extract_ipa.py 解析原包 ipa，"
                 @"再用生成的 BridgeConfig.json 覆盖 Generated/BridgeConfig.json 并重新编译。",
                 from.length ? from : @"TEMPLATE"];
    } else {
        NSArray *review = [self arrayForPath:@"needs_review"];
        _hint = [NSString stringWithFormat:
                 @"来源：%@ %@｜待人工核对字段 %lu 项（域名、路径、UUID、指令码需用抓包结果确认）",
                 src, [self stringForPath:@"source_version" default:@""],
                 (unsigned long)review.count];
    }
    return self;
}

- (NSDictionary *)raw { return _raw; }
- (NSString *)configurationHint { return _hint; }
- (NSString *)bridgeMode  { return [self stringForPath:@"bridge_mode" default:@"http"]; }
- (NSString *)sourceBundleId { return [self stringForPath:@"source_bundle_id" default:@""]; }

- (id)objectForPath:(NSString *)dotPath {
    id cur = _raw;
    for (NSString *part in [dotPath componentsSeparatedByString:@"."]) {
        if (![cur isKindOfClass:NSDictionary.class]) return nil;
        cur = ((NSDictionary *)cur)[part];
        if (!cur || cur == NSNull.null) return nil;
    }
    return cur;
}

- (NSString *)stringForPath:(NSString *)dotPath default:(NSString *)fallback {
    id v = [self objectForPath:dotPath];
    if ([v isKindOfClass:NSString.class] && [v length]) return v;
    if ([v isKindOfClass:NSNumber.class]) return [v stringValue];
    return fallback;
}

- (NSDictionary *)dictionaryForPath:(NSString *)dotPath {
    id v = [self objectForPath:dotPath];
    return [v isKindOfClass:NSDictionary.class] ? v : @{};
}

- (NSArray *)arrayForPath:(NSString *)dotPath {
    id v = [self objectForPath:dotPath];
    return [v isKindOfClass:NSArray.class] ? v : @[];
}

- (NSInteger)integerForPath:(NSString *)dotPath default:(NSInteger)fallback {
    id v = [self objectForPath:dotPath];
    if ([v respondsToSelector:@selector(integerValue)]) return [v integerValue];
    return fallback;
}

- (double)doubleForPath:(NSString *)dotPath default:(double)fallback {
    id v = [self objectForPath:dotPath];
    if ([v respondsToSelector:@selector(doubleValue)]) return [v doubleValue];
    return fallback;
}

- (BOOL)boolForPath:(NSString *)dotPath default:(BOOL)fallback {
    id v = [self objectForPath:dotPath];
    if ([v isKindOfClass:NSNumber.class]) return [v boolValue];
    if ([v isKindOfClass:NSString.class]) {
        NSString *s = [(NSString *)v lowercaseString];
        if ([s isEqualToString:@"true"] || [s isEqualToString:@"yes"] || [s isEqualToString:@"1"]) return YES;
        if ([s isEqualToString:@"false"] || [s isEqualToString:@"no"] || [s isEqualToString:@"0"]) return NO;
    }
    return fallback;
}

- (NSURL *)urlForPathKey:(NSString *)pathKey {
    NSString *base = [self stringForPath:@"api.base" default:@""];
    NSString *path = [self stringForPath:[@"api." stringByAppendingString:pathKey] default:@""];
    if (!base.length) return nil;
    if ([path hasPrefix:@"http://"] || [path hasPrefix:@"https://"]) {
        return [NSURL URLWithString:path];
    }
    if (![base hasSuffix:@"/"]) base = [base stringByAppendingString:@"/"];
    if ([path hasPrefix:@"/"]) path = [path substringFromIndex:1];
    return [NSURL URLWithString:[base stringByAppendingString:path]];
}

@end
