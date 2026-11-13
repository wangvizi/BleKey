#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * 蓝牙指令帧编解码。帧结构与加密方式全部由 ble.frame 配置驱动：
 *
 *   [header_hex][len:1][cmd:1][seq:seq_bytes][payload][crc][trailer_hex]
 *
 * len = cmd+seq+payload 的长度；crc 覆盖 header..payload；
 * crypto 只作用于 payload（none / xor / aes128_ecb / aes128_cbc）。
 * 不同车厂的帧格式不同，改 BridgeConfig.json 即可，不用改代码。
 */
@interface ORIGFrameCodec : NSObject

- (instancetype)initWithConfig:(id)config;

- (NSData * _Nullable)buildFrameForCommand:(NSString *)command
                                  payload:(NSData * _Nullable)payload
                                      seq:(uint16_t)seq
                                    error:(NSString * _Nullable * _Nullable)error;

- (BOOL)parseFrame:(NSData *)frame
        outCommand:(NSString * _Nullable * _Nullable)command
        outPayload:(NSData * _Nullable * _Nullable)payload
            outSeq:(uint16_t * _Nullable)seq
             error:(NSString * _Nullable * _Nullable)error;

- (NSData * _Nullable)commandByteForName:(NSString *)name;
- (NSString *)hexStringFromData:(NSData *)data;

@end

NS_ASSUME_NONNULL_END
