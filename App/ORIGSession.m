#import "ORIGSession.h"
#import <Security/Security.h>

static NSString * const kService = @"com.blekey.standalone.keychain";
static NSString * const kAcctToken = @"access_token";
static NSString * const kAcctBleKey = @"ble_key_hex";

@implementation ORIGSession

+ (instancetype)shared {
    static ORIGSession *inst;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ inst = [[ORIGSession alloc] init]; });
    return inst;
}

#pragma mark - Keychain 原语

+ (NSMutableDictionary *)baseQueryForAccount:(NSString *)account {
    return [@{
        (__bridge id)kSecClass       : (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService : kService,
        (__bridge id)kSecAttrAccount : account,
    } mutableCopy];
}

+ (NSString *)readAccount:(NSString *)account {
    NSMutableDictionary *q = [self baseQueryForAccount:account];
    q[(__bridge id)kSecReturnData] = @YES;
    q[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;
    CFTypeRef ref = NULL;
    OSStatus st = SecItemCopyMatching((__bridge CFDictionaryRef)q, &ref);
    if (st != errSecSuccess || !ref) return nil;
    NSData *d = (__bridge_transfer NSData *)ref;
    return [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] ?: nil;
}

+ (void)writeAccount:(NSString *)account value:(NSString * _Nullable)value {
    NSMutableDictionary *q = [self baseQueryForAccount:account];
    if (!value.length) {
        SecItemDelete((__bridge CFDictionaryRef)q);
        return;
    }
    NSData *data = [value dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *attrs = @{
        (__bridge id)kSecValueData : data,
        (__bridge id)kSecAttrAccessible : (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    };
    OSStatus st = SecItemUpdate((__bridge CFDictionaryRef)q, (__bridge CFDictionaryRef)attrs);
    if (st == errSecItemNotFound) {
        NSMutableDictionary *add = [q mutableCopy];
        [add addEntriesFromDictionary:attrs];
        SecItemAdd((__bridge CFDictionaryRef)add, NULL);
    }
}

#pragma mark - 属性

- (NSString *)token     { return [ORIGSession readAccount:kAcctToken]; }
- (void)setToken:(NSString *)t { [ORIGSession writeAccount:kAcctToken value:t]; }

- (NSString *)bleKeyHex { return [ORIGSession readAccount:kAcctBleKey]; }
- (void)setBleKeyHex:(NSString *)k { [ORIGSession writeAccount:kAcctBleKey value:k]; }

static NSString * UDRead(NSString *key) {
    return [[NSUserDefaults standardUserDefaults] stringForKey:key];
}
static void UDWrite(NSString *key, NSString * _Nullable value) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if (value.length) [d setObject:value forKey:key];
    else [d removeObjectForKey:key];
    [d synchronize];
}

- (NSString *)phone { return UDRead(@"blekey.phone"); }
- (void)setPhone:(NSString *)v { UDWrite(@"blekey.phone", v); }

- (NSString *)vehicleId { return UDRead(@"blekey.vehicleId"); }
- (void)setVehicleId:(NSString *)v { UDWrite(@"blekey.vehicleId", v); }

- (NSString *)deviceName { return UDRead(@"blekey.deviceName"); }
- (void)setDeviceName:(NSString *)v { UDWrite(@"blekey.deviceName", v); }

- (NSString *)keyPayloadJSON { return UDRead(@"blekey.keyPayloadJSON"); }
- (void)setKeyPayloadJSON:(NSString *)v { UDWrite(@"blekey.keyPayloadJSON", v); }

- (BOOL)isLoggedIn { return self.token.length > 0; }

- (void)clearAll {
    self.token = nil;
    self.bleKeyHex = nil;
    self.phone = nil;
    self.vehicleId = nil;
    self.deviceName = nil;
    self.keyPayloadJSON = nil;
}

@end
