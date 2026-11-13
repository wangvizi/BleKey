#import "ORIGAuthService.h"
#import "ORIGConfig.h"
#import "ORIGSession.h"
#import "ORIGRuntimeBridge.h"

@interface ORIGAuthService ()
- (void)requestPathKey:(NSString *)pathKey
                  body:(NSDictionary * _Nullable)body
              needAuth:(BOOL)needAuth
            completion:(ORIGCompletion)completion;
- (void)absorbKeyPayload:(id)payload;
- (NSString * _Nullable)firstStringIn:(NSDictionary *)flat matchingKey:(NSString *)key;
- (NSDictionary *)flattenedDictionary:(id)obj prefix:(NSString *)prefix depth:(NSInteger)depth;
@end

@implementation ORIGAuthService

+ (instancetype)shared {
    static ORIGAuthService *inst;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ inst = [[ORIGAuthService alloc] init]; });
    return inst;
}

#pragma mark - 点路径取值

+ (id)valueForDotPath:(NSString *)dotPath inObject:(id)object {
    if (!dotPath.length) return object;
    id cur = object;
    for (NSString *part in [dotPath componentsSeparatedByString:@"."]) {
        if ([cur isKindOfClass:NSDictionary.class]) {
            cur = ((NSDictionary *)cur)[part];
        } else if ([cur isKindOfClass:NSArray.class]) {
            NSInteger idx = [part integerValue];
            NSArray *a = (NSArray *)cur;
            cur = (idx >= 0 && idx < (NSInteger)a.count) ? a[idx] : nil;
        } else {
            return nil;
        }
        if (!cur || cur == NSNull.null) return nil;
    }
    return cur;
}

#pragma mark - HTTP 原语

- (void)requestPathKey:(NSString *)pathKey
                  body:(NSDictionary * _Nullable)body
              needAuth:(BOOL)needAuth
            completion:(ORIGCompletion)completion {
    ORIGConfig *cfg = [ORIGConfig shared];
    if (!cfg.configured) {
        completion(NO, nil, cfg.configurationHint);
        return;
    }
    NSURL *url = [cfg urlForPathKey:pathKey];
    if (!url) {
        completion(NO, nil, [NSString stringWithFormat:@"api.%@ 未配置或 URL 非法", pathKey]);
        return;
    }

    NSString *method = [[cfg stringForPath:@"api.method" default:@"POST"] uppercaseString];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url
                                                       cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                   timeoutInterval:15.0];
    req.HTTPMethod = method;
    NSDictionary *headers = [cfg dictionaryForPath:@"api.headers"];
    for (NSString *k in headers) {
        id v = headers[k];
        if ([v isKindOfClass:NSString.class]) [req setValue:v forHTTPHeaderField:k];
    }
    if (needAuth) {
        NSString *token = [ORIGSession shared].token;
        if (token.length) [req setValue:[NSString stringWithFormat:@"Bearer %@", token]
                     forHTTPHeaderField:@"Authorization"];
    }

    NSDictionary *extra = [cfg dictionaryForPath:@"api.extra_body"];
    NSMutableDictionary *finalBody = [NSMutableDictionary dictionaryWithDictionary:extra];
    [finalBody addEntriesFromDictionary:body ?: @{}];

    NSError *jsonErr = nil;
    if ([method isEqualToString:@"GET"]) {
        NSMutableArray *parts = [NSMutableArray array];
        for (NSString *k in finalBody) {
            NSString *v = [NSString stringWithFormat:@"%@", finalBody[k]];
            NSString *enc = [v stringByAddingPercentEncodingWithAllowedCharacters:
                             [NSCharacterSet URLQueryAllowedCharacterSet]] ?: @"";
            [parts addObject:[NSString stringWithFormat:@"%@=%@", k, enc]];
        }
        if (parts.count) {
            NSString *sep = url.query.length ? @"&" : @"?";
            req.URL = [NSURL URLWithString:[NSString stringWithFormat:@"%@%@%@",
                                            url.absoluteString, sep, [parts componentsJoinedByString:@"&"]]];
        }
    } else {
        NSData *data = [NSJSONSerialization dataWithJSONObject:finalBody options:0 error:&jsonErr];
        if (!data) {
            completion(NO, nil, [NSString stringWithFormat:@"请求体序列化失败: %@", jsonErr.localizedDescription]);
            return;
        }
        req.HTTPBody = data;
    }

    NSURLSessionConfiguration *sc = [NSURLSessionConfiguration defaultSessionConfiguration];
    sc.timeoutIntervalForRequest = 15.0;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:sc];
    NSURLSessionDataTask *task = [session dataTaskWithRequest:req
        completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
        if (error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(NO, nil, [NSString stringWithFormat:@"网络错误: %@", error.localizedDescription]);
            });
            return;
        }
        NSInteger code = [(NSHTTPURLResponse *)response statusCode];
        id payload = nil;
        if (data.length) {
            id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
            payload = parsed ?: [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        }
        BOOL ok = (code >= 200 && code < 300);
        NSString *err = ok ? nil : [NSString stringWithFormat:@"HTTP %ld %@", (long)code,
                                    [NSHTTPURLResponse localizedStringForStatusCode:code]];
        dispatch_async(dispatch_get_main_queue(), ^{ completion(ok, payload, err); });
    }];
    [task resume];
    [session finishTasksAndInvalidate];
}

#pragma mark - 业务接口

- (void)sendSmsTo:(NSString *)phone completion:(ORIGCompletion)completion {
    ORIGConfig *cfg = [ORIGConfig shared];
    NSString *field = [cfg stringForPath:@"api.field_phone" default:@"mobile"];
    [self requestPathKey:@"sms_path" body:@{field : phone ?: @""} needAuth:NO completion:completion];
}

- (void)loginWithPhone:(NSString *)phone secret:(NSString *)secret completion:(ORIGCompletion)completion {
    ORIGConfig *cfg = [ORIGConfig shared];

    if ([[cfg.bridgeMode lowercaseString] isEqualToString:@"runtime"]) {
        NSDictionary *arg = @{@"phone" : phone ?: @"", @"secret" : secret ?: @""};
        [[ORIGRuntimeBridge shared] invokeClass:[cfg stringForPath:@"runtime.class_login" default:@""]
                                       selector:[cfg stringForPath:@"runtime.selector_login" default:@""]
                                            arg:arg
                                     completion:^(BOOL ok, id payload, NSString *err) {
            if (!ok) { completion(NO, payload, err); return; }
            NSString *token = [ORIGAuthService valueForDotPath:[cfg stringForPath:@"api.token_json_path"
                                                                         default:@"data.accessToken"]
                                                      inObject:payload];
            if (![token isKindOfClass:NSString.class] || ![token length]) {
                completion(NO, payload, @"runtime 登录返回里取不到 token，请核对 api.token_json_path");
                return;
            }
            [ORIGSession shared].token = token;
            completion(YES, payload, nil);
        }];
        return;
    }

    NSString *type = [[cfg stringForPath:@"api.login_type" default:@"sms"] lowercaseString];
    NSString *secretField = [type isEqualToString:@"password"]
        ? [cfg stringForPath:@"api.field_password" default:@"password"]
        : [cfg stringForPath:@"api.field_code" default:@"code"];
    NSString *phoneField = [cfg stringForPath:@"api.field_phone" default:@"mobile"];

    [self requestPathKey:@"login_path"
                    body:@{phoneField : phone ?: @"", secretField : secret ?: @""}
                needAuth:NO
              completion:^(BOOL ok, id payload, NSString *err) {
        if (!ok) { completion(NO, payload, err); return; }
        NSString *tokenPath = [cfg stringForPath:@"api.token_json_path" default:@"data.accessToken"];
        id token = [ORIGAuthService valueForDotPath:tokenPath inObject:payload];
        if (![token isKindOfClass:NSString.class] || ![token length]) {
            completion(NO, payload,
                       [NSString stringWithFormat:@"登录响应里取不到 token（api.token_json_path=%@）。"
                        @"请按原包实际返回结构修改该字段。", tokenPath]);
            return;
        }
        ORIGSession *s = [ORIGSession shared];
        s.token = token;
        s.phone = phone;
        completion(YES, payload, nil);
    }];
}

- (void)fetchBleKeysWithCompletion:(ORIGCompletion)completion {
    ORIGConfig *cfg = [ORIGConfig shared];
    if ([[cfg.bridgeMode lowercaseString] isEqualToString:@"runtime"]) {
        [[ORIGRuntimeBridge shared] invokeClass:[cfg stringForPath:@"runtime.class_ble" default:@""]
                                       selector:[cfg stringForPath:@"runtime.selector_connect" default:@""]
                                            arg:nil
                                     completion:^(BOOL ok, id payload, NSString *err) {
            if (ok) [self absorbKeyPayload:payload];
            completion(ok, payload, err);
        }];
        return;
    }

    [self requestPathKey:@"key_path" body:@{} needAuth:YES completion:^(BOOL ok, id payload, NSString *err) {
        if (!ok) { completion(NO, payload, err); return; }
        NSString *keyPath = [cfg stringForPath:@"api.key_json_path" default:@"data"];
        id body = [ORIGAuthService valueForDotPath:keyPath inObject:payload] ?: payload;
        [self absorbKeyPayload:body];
        completion(YES, body, nil);
    }];
}

/** 从原包下发的钥匙数据里按常见键名提取蓝牙密钥 / 车辆标识，键名可递归查找 */
- (void)absorbKeyPayload:(id)payload {
    ORIGSession *s = [ORIGSession shared];
    if (!payload) return;
    if ([payload isKindOfClass:NSData.class]) return;

    if ([payload isKindOfClass:NSDictionary.class] || [payload isKindOfClass:NSArray.class]) {
        NSData *json = [NSJSONSerialization dataWithJSONObject:payload options:0 error:NULL];
        if (json) s.keyPayloadJSON = [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
    } else if ([payload isKindOfClass:NSString.class]) {
        s.keyPayloadJSON = payload;
    }

    NSDictionary *flat = [self flattenedDictionary:payload prefix:@"" depth:0];
    NSArray *keyNames = @[@"bleKeyHex", @"bleKey", @"keyHex", @"secretKey", @"secret",
                          @"digitalKey", @"key", @"keyData", @"authKey", @"aesKey"];
    NSArray *vinNames = @[@"vehicleId", @"vin", @"carId", @"vehicleNo", @"carNo"];
    NSArray *nameNames = @[@"bleName", @"deviceName", @"bluetoothName", @"btName", @"mac", @"deviceMac"];

    for (NSString *k in keyNames) {
        NSString *v = [self firstStringIn:flat matchingKey:k];
        if (v.length) { s.bleKeyHex = v; break; }
    }
    for (NSString *k in vinNames) {
        NSString *v = [self firstStringIn:flat matchingKey:k];
        if (v.length) { s.vehicleId = v; break; }
    }
    for (NSString *k in nameNames) {
        NSString *v = [self firstStringIn:flat matchingKey:k];
        if (v.length) { s.deviceName = v; break; }
    }
}

- (NSString *)firstStringIn:(NSDictionary *)flat matchingKey:(NSString *)key {
    for (NSString *path in flat) {
        NSString *last = [path componentsSeparatedByString:@"."].lastObject;
        if ([last caseInsensitiveCompare:key] == NSOrderedSame) {
            id v = flat[path];
            if ([v isKindOfClass:NSString.class] && [v length]) return v;
        }
    }
    return nil;
}

/** 打平嵌套结构，深度上限 6，复杂度 O(节点数) */
- (NSDictionary *)flattenedDictionary:(id)obj prefix:(NSString *)prefix depth:(NSInteger)depth {
    if (depth > 6) return @{};
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    if ([obj isKindOfClass:NSDictionary.class]) {
        for (id k in (NSDictionary *)obj) {
            NSString *p = prefix.length ? [NSString stringWithFormat:@"%@.%@", prefix, k] : [NSString stringWithFormat:@"%@", k];
            id v = ((NSDictionary *)obj)[k];
            if ([v isKindOfClass:NSDictionary.class] || [v isKindOfClass:NSArray.class]) {
                [out addEntriesFromDictionary:[self flattenedDictionary:v prefix:p depth:depth + 1]];
            } else if (v && v != NSNull.null) {
                out[p] = v;
            }
        }
    } else if ([obj isKindOfClass:NSArray.class]) {
        NSInteger i = 0;
        for (id v in (NSArray *)obj) {
            NSString *p = [NSString stringWithFormat:@"%@.%ld", prefix, (long)i++];
            if ([v isKindOfClass:NSDictionary.class] || [v isKindOfClass:NSArray.class]) {
                [out addEntriesFromDictionary:[self flattenedDictionary:v prefix:p depth:depth + 1]];
            } else if (v && v != NSNull.null) {
                out[p] = v;
            }
        }
    }
    return out;
}

- (void)logout {
    [[ORIGSession shared] clearAll];
}

@end
