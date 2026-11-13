#import <Foundation/Foundation.h>
#import "ORIGTypes.h"

NS_ASSUME_NONNULL_BEGIN

@protocol ORIGBleKeyManagerDelegate <NSObject>
- (void)bleManagerDidUpdateState:(ORIGBleState)state info:(NSString *)info;
- (void)bleManagerDidLog:(NSString *)line;
@end

/**
 * 蓝牙钥匙链路：扫描 -> 连接 -> 服务/特征发现 -> 鉴权 -> 指令收发。
 * CBCentralManager 固定跑在主队列，所有状态与 pending 回调都在主线程，
 * 省掉锁；代价是 BLE 回调不能做重活，这里只做帧编解码，量级为字节级。
 */
@interface ORIGBleKeyManager : NSObject

+ (instancetype)shared;

@property (nonatomic, weak, nullable) id<ORIGBleKeyManagerDelegate> delegate;
@property (nonatomic, assign, readonly) ORIGBleState state;
@property (nonatomic, copy, readonly) NSString *connectedName;

/** 上电后按 ble.service_uuid 扫描；重复调用会重新开始扫描 */
- (void)startScan;
- (void)stopScan;
- (void)disconnect;

/** command 名必须是 ble.commands 里的键，例如 unlock / lock / trunk */
- (void)sendCommand:(NSString *)command completion:(ORIGCompletion)completion;

@end

NS_ASSUME_NONNULL_END
