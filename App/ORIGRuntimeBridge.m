#import "ORIGRuntimeBridge.h"
#import "ORIGConfig.h"
#import <dlfcn.h>
#import <objc/runtime.h>

@implementation ORIGRuntimeBridge {
    void *_handle;
    NSString *_loadError;
    BOOL _tried;
}

+ (instancetype)shared {
    static ORIGRuntimeBridge *inst;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ inst = [[ORIGRuntimeBridge alloc] init]; });
    return inst;
}

- (instancetype)init {
    self = [super init];
    if (self) _loadError = @"未初始化";
    return self;
}

- (BOOL)available {
    [self ensureLoaded];
    return _handle != NULL;
}

- (NSString *)loadError {
    [self ensureLoaded];
    return _loadError;
}

- (void)ensureLoaded {
    if (_tried) return;
    _tried = YES;

    ORIGConfig *cfg = [ORIGConfig shared];
    BOOL enabled = [cfg boolForPath:@"runtime.enabled" default:NO];
    NSString *fw = [cfg stringForPath:@"runtime.framework" default:@""];
    if (!enabled) {
        _loadError = @"runtime.enabled=false，当前走 HTTP 接口链路";
        return;
    }
    if (!fw.length) {
        _loadError = @"runtime.framework 为空：原包没有可抽取的动态 framework";
        return;
    }

    NSString *stem = [fw stringByDeletingPathExtension];
    NSString *rel = [NSString stringWithFormat:@"Frameworks/%@/%@", fw, stem];
    NSString *abs = [[[NSBundle mainBundle] bundlePath] stringByAppendingPathComponent:rel];
    if (![[NSFileManager defaultManager] fileExistsAtPath:abs]) {
        _loadError = [NSString stringWithFormat:@"bundle 内找不到 %@", rel];
        return;
    }

    // RTLD_LAZY：framework 里若引用主程序符号，只在实际调用时才解析，避免加载即失败
    _handle = dlopen([abs fileSystemRepresentation], RTLD_LAZY | RTLD_LOCAL);
    if (!_handle) {
        const char *e = dlerror();
        _loadError = [NSString stringWithFormat:@"dlopen 失败: %s", e ? e : "unknown"];
    } else {
        _loadError = @"";
    }
}

- (void)invokeClass:(NSString *)className
           selector:(NSString *)selectorName
                arg:(id)arg
         completion:(ORIGCompletion)completion {
    [self ensureLoaded];
    if (!_handle) {
        completion(NO, nil, [NSString stringWithFormat:@"原包 framework 未加载：%@", _loadError]);
        return;
    }
    if (!className.length || !selectorName.length) {
        completion(NO, nil, @"runtime.class_* / runtime.selector_* 未配置");
        return;
    }

    Class cls = NSClassFromString(className);
    if (!cls) {
        completion(NO, nil, [NSString stringWithFormat:@"NSClassFromString(%@) 返回 nil：类名需从 Generated/objc_names.txt 核对", className]);
        return;
    }
    SEL sel = NSSelectorFromString(selectorName);
    NSUInteger colons = [[selectorName componentsSeparatedByString:@":"] count] - 1;

    // 优先类方法；没有则用实例方法。原包 SDK 两种都常见。
    NSMethodSignature *sig = [cls methodSignatureForSelector:sel];
    id target = cls;
    if (!sig) {
        sig = [cls instanceMethodSignatureForSelector:sel];
        target = [[cls alloc] init];
    }
    if (!sig) {
        completion(NO, nil, [NSString stringWithFormat:@"%@ 不响应 %@", className, selectorName]);
        return;
    }
    if (colons > 1 || sig.numberOfArguments != 2 + colons) {
        completion(NO, nil, [NSString stringWithFormat:@"%@ 参数个数不匹配（期望 %lu，签名 %lu）",
                             selectorName, (unsigned long)colons, (unsigned long)(sig.numberOfArguments - 2)]);
        return;
    }

    @try {
        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
        inv.target = target;
        inv.selector = sel;
        if (colons == 1 && arg) {
            __unsafe_unretained id a = arg;
            [inv setArgument:&a atIndex:2];
        }
        [inv invoke];

        id result = nil;
        const char *retType = sig.methodReturnType;
        if (retType && retType[0] == '@') {   // ObjC 对象返回值 'v' 表示 void
            __unsafe_unretained id tmp = nil;
            [inv getReturnValue:&tmp];
            result = tmp;
        }
        completion(YES, result ?: @{@"invoked" : selectorName}, nil);
    } @catch (NSException *ex) {
        completion(NO, nil, [NSString stringWithFormat:@"%@ 抛异常: %@", selectorName, ex.reason]);
    }
}

@end
