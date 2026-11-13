#import "ORIGFrameCodec.h"
#import "ORIGConfig.h"
#import <CommonCrypto/CommonCryptor.h>

#pragma mark - hex 工具

static NSData * ORIGDataFromHex(NSString *hex) {
    if (!hex.length) return [NSData data];
    NSString *s = [[hex componentsSeparatedByCharactersInSet:
                    [NSCharacterSet whitespaceAndNewlineCharacterSet]] componentsJoinedByString:@""];
    s = [s stringByReplacingOccurrencesOfString:@"0x" withString:@""];
    if (s.length % 2 != 0) s = [@"0" stringByAppendingString:s];
    NSMutableData *out = [NSMutableData dataWithCapacity:s.length / 2];
    for (NSUInteger i = 0; i + 1 < s.length; i += 2) {
        unsigned int v = 0;
        NSString *pair = [s substringWithRange:NSMakeRange(i, 2)];
        if (![[NSScanner scannerWithString:pair] scanHexInt:&v]) return [NSData data];
        uint8_t b = (uint8_t)(v & 0xFF);
        [out appendBytes:&b length:1];
    }
    return out;
}

static NSString * ORIGHexFromData(NSData *data) {
    const uint8_t *p = data.bytes;
    NSMutableString *s = [NSMutableString stringWithCapacity:data.length * 2];
    for (NSUInteger i = 0; i < data.length; i++) [s appendFormat:@"%02X", p[i]];
    return [s uppercaseString];
}

static uint16_t ORIGCrc16Ccitt(NSData *data) {
    const uint8_t *p = data.bytes;
    uint16_t crc = 0xFFFF;
    for (NSUInteger i = 0; i < data.length; i++) {
        crc ^= (uint16_t)p[i] << 8;
        for (int b = 0; b < 8; b++) {
            crc = (crc & 0x8000) ? (uint16_t)((crc << 1) ^ 0x1021) : (uint16_t)(crc << 1);
        }
    }
    return crc;
}

static uint8_t ORIGXor8(NSData *data) {
    const uint8_t *p = data.bytes;
    uint8_t v = 0;
    for (NSUInteger i = 0; i < data.length; i++) v ^= p[i];
    return v;
}

@implementation ORIGFrameCodec {
    ORIGConfig *_cfg;
}

- (instancetype)initWithConfig:(id)config {
    self = [super init];
    if (self) _cfg = config ?: [ORIGConfig shared];
    return self;
}

- (NSString *)hexStringFromData:(NSData *)data { return ORIGHexFromData(data); }

#pragma mark - 配置读取

- (NSData *)headerData { return ORIGDataFromHex([_cfg stringForPath:@"ble.frame.header_hex" default:@"5AA5"]); }
- (NSData *)trailerData { return ORIGDataFromHex([_cfg stringForPath:@"ble.frame.trailer_hex" default:@""]); }
- (BOOL)hasLengthByte { return [_cfg boolForPath:@"ble.frame.has_length_byte" default:YES]; }
- (NSInteger)seqByteCount {
    NSInteger n = [_cfg integerForPath:@"ble.frame.seq_bytes" default:2];
    return MIN(4, MAX(1, n));
}
- (NSString *)crcMode { return [[_cfg stringForPath:@"ble.frame.crc" default:@"xor8"] lowercaseString]; }
- (NSInteger)crcByteCount {
    NSString *m = self.crcMode;
    if ([m isEqualToString:@"crc16"] || [m isEqualToString:@"crc16_ccitt"]) return 2;
    if ([m isEqualToString:@"xor8"]) return 1;
    return 0;  // none
}

- (NSData *)commandByteForName:(NSString *)name {
    NSString *hex = [[_cfg dictionaryForPath:@"ble.commands"][name] description];
    if (!hex.length) return nil;
    NSData *d = ORIGDataFromHex(hex);
    return d.length == 1 ? d : nil;
}

- (NSString *)commandNameForByte:(uint8_t)byte {
    NSDictionary *cmds = [_cfg dictionaryForPath:@"ble.commands"];
    for (NSString *k in cmds) {
        NSData *d = ORIGDataFromHex([cmds[k] description]);
        if (d.length == 1 && ((const uint8_t *)d.bytes)[0] == byte) return k;
    }
    return [NSString stringWithFormat:@"0x%02X", byte];
}

#pragma mark - payload 变换

- (NSData * _Nullable)transformPayload:(NSData *)payload encrypt:(BOOL)encrypt
                                 error:(NSString * _Nullable * _Nullable)error {
    NSData *src = payload ?: [NSData data];
    NSString *mode = [[_cfg stringForPath:@"ble.frame.crypto" default:@"none"] lowercaseString];

    if ([mode isEqualToString:@"none"] || src.length == 0) return src;

    NSData *key = ORIGDataFromHex([_cfg stringForPath:@"ble.frame.key_hex" default:@""]);
    if ([mode isEqualToString:@"xor"]) {
        if (!key.length) { if (error) *error = @"crypto=xor 但未配置 ble.frame.key_hex"; return nil; }
        NSMutableData *out = [NSMutableData dataWithLength:src.length];
        const uint8_t *sp = src.bytes, *kp = key.bytes;
        uint8_t *dp = out.mutableBytes;
        for (NSUInteger i = 0; i < src.length; i++) dp[i] = sp[i] ^ kp[i % key.length];
        return out;
    }

    if ([mode isEqualToString:@"aes128_ecb"] || [mode isEqualToString:@"aes128_cbc"]) {
        if (key.length < kCCKeySizeAES128) {
            if (error) *error = @"AES128 需要 ble.frame.key_hex 至少 16 字节";
            return nil;
        }
        NSData *key16 = [key subdataWithRange:NSMakeRange(0, kCCKeySizeAES128)];
        NSData *iv = ORIGDataFromHex([_cfg stringForPath:@"ble.frame.iv_hex"
                                                  default:@"00000000000000000000000000000000"]);
        if (iv.length < kCCBlockSizeAES128) {
            NSMutableData *pad = [NSMutableData dataWithData:iv];
            [pad increaseLengthBy:kCCBlockSizeAES128 - iv.length];
            iv = pad;
        }
        CCOptions opts = kCCOptionPKCS7Padding;
        if ([mode isEqualToString:@"aes128_ecb"]) opts |= kCCOptionECBMode;

        size_t bufLen = src.length + kCCBlockSizeAES128 + 16;
        NSMutableData *out = [NSMutableData dataWithLength:bufLen];
        size_t moved = 0;
        CCCryptorStatus st = CCCrypt(encrypt ? kCCEncrypt : kCCDecrypt,
                                     kCCAlgorithmAES128, opts,
                                     key16.bytes, key16.length,
                                     iv.bytes,
                                     src.bytes, src.length,
                                     out.mutableBytes, bufLen, &moved);
        if (st != kCCSuccess) {
            if (error) *error = [NSString stringWithFormat:@"CCCrypt 失败 status=%d", st];
            return nil;
        }
        out.length = moved;
        return out;
    }

    if (error) *error = [NSString stringWithFormat:@"未知 ble.frame.crypto=%@", mode];
    return nil;
}

#pragma mark - 组帧

- (NSData *)buildFrameForCommand:(NSString *)command
                        payload:(NSData *)payload
                            seq:(uint16_t)seq
                          error:(NSString * _Nullable * _Nullable)error {
    NSData *cmd = [self commandByteForName:command];
    if (!cmd) {
        if (error) *error = [NSString stringWithFormat:@"ble.commands 里没有 %@ 或值不是单字节 hex", command];
        return nil;
    }
    NSData *enc = [self transformPayload:payload encrypt:YES error:error];
    if (!enc) return nil;

    NSMutableData *body = [NSMutableData dataWithData:cmd];
    NSInteger seqN = self.seqByteCount;
    for (NSInteger i = seqN - 1; i >= 0; i--) {
        uint8_t b = (uint8_t)((seq >> (8 * i)) & 0xFF);
        [body appendBytes:&b length:1];
    }
    [body appendData:enc];
    if (body.length > 255) {
        if (error) *error = @"帧体超过 255 字节，需按 MTU 分片（当前实现单帧上限 255）";
        return nil;
    }

    NSMutableData *frame = [NSMutableData dataWithData:self.headerData];
    if (self.hasLengthByte) {
        uint8_t len = (uint8_t)body.length;
        [frame appendBytes:&len length:1];
    }
    [frame appendData:body];

    NSInteger crcN = self.crcByteCount;
    if (crcN == 1) {
        uint8_t c = ORIGXor8(frame);
        [frame appendBytes:&c length:1];
    } else if (crcN == 2) {
        uint16_t c = ORIGCrc16Ccitt(frame);
        uint8_t hi = (uint8_t)(c >> 8), lo = (uint8_t)(c & 0xFF);
        [frame appendBytes:&hi length:1];
        [frame appendBytes:&lo length:1];
    }
    [frame appendData:self.trailerData];
    return frame;
}

#pragma mark - 解帧

- (BOOL)parseFrame:(NSData *)frame
        outCommand:(NSString * _Nullable * _Nullable)command
        outPayload:(NSData * _Nullable * _Nullable)payload
            outSeq:(uint16_t * _Nullable)seq
             error:(NSString * _Nullable * _Nullable)error {
    NSData *header = self.headerData;
    NSData *trailer = self.trailerData;
    NSInteger crcN = self.crcByteCount;
    NSUInteger pos = header.length;

    if (frame.length < pos + 1) {
        if (error) *error = @"帧长不足";
        return NO;
    }
    if (header.length && ![[frame subdataWithRange:NSMakeRange(0, header.length)] isEqualToData:header]) {
        if (error) *error = [NSString stringWithFormat:@"帧头不匹配，期望 %@", ORIGHexFromData(header)];
        return NO;
    }

    NSUInteger bodyLen = 0;
    if (self.hasLengthByte) {
        const uint8_t *p = frame.bytes;
        bodyLen = p[pos];
        pos += 1;
    } else {
        // 无长度字节时，帧体 = 总长 - 帧头 - CRC - 帧尾（cmd/seq/payload 都算帧体）
        NSUInteger tail = (NSUInteger)crcN + trailer.length;
        bodyLen = frame.length > pos + tail ? frame.length - pos - tail : 0;
    }
    NSUInteger need = pos + bodyLen + (NSUInteger)crcN + trailer.length;
    if (bodyLen == 0 || frame.length < need) {
        if (error) *error = [NSString stringWithFormat:@"帧不完整: 需要 %lu 字节，实收 %lu",
                             (unsigned long)need, (unsigned long)frame.length];
        return NO;
    }

    // CRC 覆盖范围：帧头 + 长度 + 帧体
    NSUInteger crcPos = pos + bodyLen;
    if (crcN == 1) {
        uint8_t expect = ORIGXor8([frame subdataWithRange:NSMakeRange(0, crcPos)]);
        uint8_t actual = ((const uint8_t *)frame.bytes)[crcPos];
        if (expect != actual) {
            if (error) *error = [NSString stringWithFormat:@"xor8 校验失败 %02X != %02X", actual, expect];
            return NO;
        }
    } else if (crcN == 2) {
        uint16_t expect = ORIGCrc16Ccitt([frame subdataWithRange:NSMakeRange(0, crcPos)]);
        const uint8_t *p = frame.bytes;
        uint16_t actual = (uint16_t)((p[crcPos] << 8) | p[crcPos + 1]);
        if (expect != actual) {
            if (error) *error = [NSString stringWithFormat:@"crc16 校验失败 %04X != %04X", actual, expect];
            return NO;
        }
    }

    NSData *body = [frame subdataWithRange:NSMakeRange(pos, bodyLen)];
    NSInteger seqN = self.seqByteCount;
    if (body.length < 1 + (NSUInteger)seqN) {
        if (error) *error = @"帧体短于 cmd+seq";
        return NO;
    }
    const uint8_t *bp = body.bytes;
    uint8_t cmdByte = bp[0];
    uint16_t seqVal = 0;
    for (NSInteger i = 0; i < seqN; i++) seqVal = (uint16_t)((seqVal << 8) | bp[1 + i]);
    NSData *enc = [body subdataWithRange:NSMakeRange(1 + seqN, body.length - 1 - seqN)];
    NSData *plain = [self transformPayload:enc encrypt:NO error:error];
    if (!plain) return NO;

    if (command) *command = [self commandNameForByte:cmdByte];
    if (seq) *seq = seqVal;
    if (payload) *payload = plain;
    return YES;
}

@end
