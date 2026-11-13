#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/** 登录态与蓝牙钥匙凭证：敏感项进 Keychain，非敏感项进 UserDefaults */
@interface ORIGSession : NSObject

+ (instancetype)shared;

@property (nonatomic, copy, nullable) NSString *token;       // Keychain
@property (nonatomic, copy, nullable) NSString *bleKeyHex;   // Keychain
@property (nonatomic, copy, nullable) NSString *phone;       // UserDefaults
@property (nonatomic, copy, nullable) NSString *vehicleId;   // UserDefaults
@property (nonatomic, copy, nullable) NSString *deviceName;  // UserDefaults
@property (nonatomic, copy, nullable) NSString *keyPayloadJSON; // UserDefaults：原包下发的完整钥匙数据

@property (nonatomic, assign, readonly, getter=isLoggedIn) BOOL loggedIn;

- (void)clearAll;

@end

NS_ASSUME_NONNULL_END
