#ifndef ORIGTypes_h
#define ORIGTypes_h

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/** 所有网络 / 蓝牙异步操作的统一回调：ok=是否成功，payload=原始返回，err=可读错误 */
typedef void (^ORIGCompletion)(BOOL ok, id _Nullable payload, NSString * _Nullable err);

typedef NS_ENUM(NSInteger, ORIGBleState) {
    ORIGBleStateIdle = 0,
    ORIGBleStatePoweredOff,
    ORIGBleStateScanning,
    ORIGBleStateConnecting,
    ORIGBleStateReady,
    ORIGBleStateFailed,
};

static inline NSString * ORIGBleStateName(ORIGBleState s) {
    switch (s) {
        case ORIGBleStateIdle:         return @"未连接";
        case ORIGBleStatePoweredOff:   return @"蓝牙未开启";
        case ORIGBleStateScanning:     return @"扫描中";
        case ORIGBleStateConnecting:   return @"连接中";
        case ORIGBleStateReady:        return @"已连接";
        case ORIGBleStateFailed:       return @"失败";
    }
    return @"未知";
}

NS_ASSUME_NONNULL_END
#endif /* ORIGTypes_h */
