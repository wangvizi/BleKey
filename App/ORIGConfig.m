#import "ORIGConfig.h"

@implementation ORIGConfig {
    NSDictionary *_raw;
    NSDictionary *_bundleRaw;
    NSString *_hint;
    NSString *_source;
    NSString *_bundlePath;
    BOOL _overrideActive;
}

static NSString *const kOverrideFileName = @"BridgeConfig.json";

+ (NSString *)documentsConfigPath {
    NSString *dir = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    return [dir stringByAppendingPathComponent:kOverrideFileName];
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
    _bundlePath = path;
    _bundleRaw = dict ?: @{};
    _raw = _bundleRaw;

    // Documents 里的覆盖文件优先于 bundle 内置配置；重启 app 后依然生效。
    NSData *overData = [NSData dataWithContentsOfFile:[ORIGConfig documentsConfigPath]];
    if (overData) {
        id over = [NSJSONSerialization JSONObjectWithData:overData options:0 error:NULL];
        if ([over isKindOfClass:NSDictionary.class] &&
            [over[@"api"] isKindOfClass:NSDictionary.class]) {
            _raw = over;
            _overrideActive = YES;
        }
    }
    [self recompute];
    return self;
}

- (void)recompute {
    NSString *base = [self stringForPath:@"api.base" default:@""];
    NSString *src  = [self stringForPath:@"source_bundle_id" default:@""];
    NSString *from = [self stringForPath:@"generated_from" default:@""];
    BOOL placeholder = ([base rangeOfString:@"example.invalid"].location != NSNotFound);
    _configured = (src.length > 0 && base.length > 0 && !placeholder &&
                   ([base hasPrefix:@"http://"] || [base hasPrefix:@"https://"]));
    _source = _overrideActive ? @"Documents / 已导入" : @"Bundle / 内置";

    if (!_bundlePath) {
        _hint = @"Bundle 内缺少 BridgeConfig.json：打包脚本未把配置文件放进 .app。";
    } else if (_configured == NO) {
        _hint = [NSString stringWithFormat:
                 @"当前是模板配置（generated_from=%@，来源 %@）。点下方「配置」导入填好 api.base 与 "
                 @"source_bundle_id 的 BridgeConfig.json，导入后立即生效，无需重装。",
                 from.length ? from : @"TEMPLATE", _source];
    } else {
        NSArray *review = [self arrayForPath:@"needs_review"];
        _hint = [NSString stringWithFormat:
                 @"来源：%@ %@｜配置 %@｜待人工核对字段 %lu 项（域名、路径、UUID、指令码需用抓包结果确认）",
                 src, [self stringForPath:@"source_version" default:@""], _source,
                 (unsigned long)review.count];
    }
}

- (BOOL)applyConfigFromURL:(NSURL *)url error:(NSError * _Nullable * _Nullable)error {
    BOOL scoped = [url startAccessingSecurityScopedResource];
    NSData *data = [NSData dataWithContentsOfURL:url options:0 error:error];
    if (scoped) [url stopAccessingSecurityScopedResource];
    if (!data) return NO;

    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:error];
    if (![obj isKindOfClass:NSDictionary.class] ||
        ![obj[@"api"] isKindOfClass:NSDictionary.class]) {
        if (error) *error = [NSError errorWithDomain:@"ORIGConfig" code:1 userInfo:@{
            NSLocalizedDescriptionKey: @"不是有效的 BridgeConfig.json：顶层需为字典且含 api 段"}];
        return NO;
    }
    // 原子写：写一半失败不会毁掉上一份可用配置
    if (![data writeToURL:[NSURL fileURLWithPath:[ORIGConfig documentsConfigPath]]
                   options:NSDataWritingAtomic error:error]) return NO;
    _raw = obj;
    _overrideActive = YES;
    [self recompute];
    return YES;
}

- (BOOL)clearOverrideWithError:(NSError * _Nullable * _Nullable)error {
    NSString *dst = [ORIGConfig documentsConfigPath];
    NSFileManager *fm = NSFileManager.defaultManager;
    if ([fm fileExistsAtPath:dst] && ![fm removeItemAtPath:dst error:error]) return NO;
    _raw = _bundleRaw;
    _overrideActive = NO;
    [self recompute];
    return YES;
}

- (NSDictionary *)raw { return _raw; }
- (NSString *)configurationHint { return _hint; }
- (NSString *)configSource { return _source; }
- (BOOL)hasOverride { return _overrideActive; }
- (NSString *)overridePath { return [ORIGConfig documentsConfigPath]; }
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
