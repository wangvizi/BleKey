#import "ORIGBleKeyManager.h"
#import "ORIGConfig.h"
#import "ORIGSession.h"
#import "ORIGFrameCodec.h"
#import <CoreBluetooth/CoreBluetooth.h>

@interface ORIGBleKeyManager () <CBCentralManagerDelegate, CBPeripheralDelegate>
- (CBUUID *)serviceUUID;
- (CBUUID *)writeUUID;
- (CBUUID *)notifyUUID;
- (void)setState:(ORIGBleState)state info:(NSString *)info;
- (void)log:(NSString *)line;
- (void)failPending:(NSNumber *)seq error:(NSString *)err;
- (void)failAllPending:(NSString *)err;
- (void)sendAuthIfNeeded;
- (NSData *)dataFromHexString:(NSString *)hex;
- (void)scanTimedOut;
- (void)connectTimedOut;
- (void)commandTimedOut:(NSTimer *)timer;

@property (nonatomic, strong) CBCentralManager *central;
@property (nonatomic, strong, nullable) CBPeripheral *peripheral;
@property (nonatomic, strong, nullable) CBCharacteristic *writeChar;
@property (nonatomic, strong, nullable) CBCharacteristic *notifyChar;
@property (nonatomic, assign, readwrite) ORIGBleState state;
@property (nonatomic, copy, readwrite) NSString *connectedName;
@end

@implementation ORIGBleKeyManager {
    ORIGFrameCodec *_codec;
    NSMutableDictionary<NSNumber *, ORIGCompletion> *_pending;
    NSMutableDictionary<NSNumber *, NSTimer *> *_timers;
    uint16_t _seq;
    NSTimer *_scanTimer;
    NSTimer *_connectTimer;
    BOOL _wantScan;
}

+ (instancetype)shared {
    static ORIGBleKeyManager *inst;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ inst = [[ORIGBleKeyManager alloc] init]; });
    return inst;
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _codec = [[ORIGFrameCodec alloc] initWithConfig:[ORIGConfig shared]];
    _pending = [NSMutableDictionary dictionary];
    _timers = [NSMutableDictionary dictionary];
    _seq = 1;
    _state = ORIGBleStateIdle;
    _connectedName = @"";
    // 后台恢复标识：TrollStore 装的 app 走标准 BLE central 后台模式
    _central = [[CBCentralManager alloc] initWithDelegate:self
                                                    queue:dispatch_get_main_queue()
                                                  options:@{CBCentralManagerOptionRestoreIdentifierKey :
                                                            @"com.blekey.standalone.central"}];
    return self;
}

#pragma mark - 配置

- (CBUUID *)serviceUUID {
    NSString *s = [[ORIGConfig shared] stringForPath:@"ble.service_uuid"
                                             default:@"0000FFF0-0000-1000-8000-00805F9B34FB"];
    return [CBUUID UUIDWithString:s];
}
- (CBUUID *)writeUUID {
    NSString *s = [[ORIGConfig shared] stringForPath:@"ble.write_uuid"
                                             default:@"0000FFF1-0000-1000-8000-00805F9B34FB"];
    return [CBUUID UUIDWithString:s];
}
- (CBUUID *)notifyUUID {
    NSString *s = [[ORIGConfig shared] stringForPath:@"ble.notify_uuid"
                                             default:@"0000FFF2-0000-1000-8000-00805F9B34FB"];
    return [CBUUID UUIDWithString:s];
}

#pragma mark - 状态 / 日志

- (void)setState:(ORIGBleState)state info:(NSString *)info {
    _state = state;
    id<ORIGBleKeyManagerDelegate> d = self.delegate;
    if ([d respondsToSelector:@selector(bleManagerDidUpdateState:info:)]) {
        [d bleManagerDidUpdateState:state info:info];
    }
    if (info.length) [self log:[NSString stringWithFormat:@"[%@] %@", ORIGBleStateName(state), info]];
}

- (void)log:(NSString *)line {
    id<ORIGBleKeyManagerDelegate> d = self.delegate;
    if ([d respondsToSelector:@selector(bleManagerDidLog:)]) [d bleManagerDidLog:line];
}

- (void)failPending:(NSNumber *)seq error:(NSString *)err {
    ORIGCompletion block = _pending[seq];
    if (!block) return;
    [_pending removeObjectForKey:seq];
    NSTimer *t = _timers[seq];
    [t invalidate];
    [_timers removeObjectForKey:seq];
    block(NO, nil, err);
}

- (void)failAllPending:(NSString *)err {
    for (NSNumber *k in [_pending allKeys]) [self failPending:k error:err];
}

#pragma mark - 扫描 / 连接

- (void)startScan {
    ORIGConfig *cfg = [ORIGConfig shared];
    if (!cfg.configured) {
        [self setState:ORIGBleStateFailed info:cfg.configurationHint];
        return;
    }
    if (_central.state != CBManagerStatePoweredOn) {
        _wantScan = YES;
        [self setState:ORIGBleStatePoweredOff info:@"等待系统蓝牙上电"];
        return;
    }
    _wantScan = NO;
    [_scanTimer invalidate];
    [self setState:ORIGBleStateScanning
              info:[NSString stringWithFormat:@"service=%@", self.serviceUUID.UUIDString]];
    [_central scanForPeripheralsWithServices:@[self.serviceUUID]
                                     options:@{CBCentralManagerScanOptionAllowDuplicatesKey : @NO}];
    NSTimeInterval timeout = [cfg doubleForPath:@"ble.scan_timeout_sec" default:12.0];
    _scanTimer = [NSTimer scheduledTimerWithTimeInterval:MAX(1.0, timeout)
                                                  target:self selector:@selector(scanTimedOut)
                                                userInfo:nil repeats:NO];
}

- (void)scanTimedOut {
    [_central stopScan];
    if (_state == ORIGBleStateScanning) {
        [self setState:ORIGBleStateFailed
                  info:[NSString stringWithFormat:@"扫描超时，未发现设备（RSSI > %ld dBm）",
                        (long)[[ORIGConfig shared] integerForPath:@"ble.rssi_threshold" default:-85]]];
    }
}

- (void)stopScan {
    [_scanTimer invalidate];
    _scanTimer = nil;
    [_central stopScan];
    if (_state == ORIGBleStateScanning) [self setState:ORIGBleStateIdle info:@"已停止扫描"];
}

- (void)disconnect {
    [self stopScan];
    [_connectTimer invalidate];
    _connectTimer = nil;
    [self failAllPending:@"已主动断开"];
    if (_peripheral) [_central cancelPeripheralConnection:_peripheral];
    _peripheral = nil;
    _writeChar = nil;
    _notifyChar = nil;
    _connectedName = @"";
    [self setState:ORIGBleStateIdle info:@"已断开"];
}

#pragma mark - 指令

- (void)sendCommand:(NSString *)command completion:(ORIGCompletion)completion {
    if (_state != ORIGBleStateReady || !_writeChar || !_peripheral) {
        completion(NO, nil, [NSString stringWithFormat:@"蓝牙未就绪（%@），请先扫描连接", ORIGBleStateName(_state)]);
        return;
    }
    NSString *err = nil;
    uint16_t seq = _seq++;
    if (_seq == 0) _seq = 1;   // 0 留给广播帧
    NSData *frame = [_codec buildFrameForCommand:command payload:[NSData data] seq:seq error:&err];
    if (!frame) { completion(NO, nil, err ?: @"组帧失败"); return; }

    ORIGConfig *cfg = [ORIGConfig shared];
    NSInteger mtu = [cfg integerForPath:@"ble.mtu" default:20];
    [self log:[NSString stringWithFormat:@">> %@ seq=%u frame=%@ (%lu bytes, mtu=%ld)",
               command, seq, [_codec hexStringFromData:frame],
               (unsigned long)frame.length, (long)mtu]];

    NSNumber *key = @(seq);
    _pending[key] = [completion copy];
    NSTimeInterval t = [cfg doubleForPath:@"ble.command_timeout_sec" default:6.0];
    _timers[key] = [NSTimer scheduledTimerWithTimeInterval:MAX(1.0, t)
                                                    target:self selector:@selector(commandTimedOut:)
                                                  userInfo:key repeats:NO];
    // iOS 对超 MTU 的 write 会自动做 Prepare Write 长写入，这里不手工分片
    [_peripheral writeValue:frame forCharacteristic:_writeChar
                       type:CBCharacteristicWriteWithResponse];
}

- (void)commandTimedOut:(NSTimer *)timer {
    NSNumber *key = timer.userInfo;
    [self log:[NSString stringWithFormat:@"!! seq=%@ 等待车辆应答超时", key]];
    [self failPending:key error:@"等待车辆应答超时"];
}

/** 连接建立后的鉴权：把服务端下发的钥匙密钥作为 auth 帧 payload 发出 */
- (void)sendAuthIfNeeded {
    NSString *keyHex = [ORIGSession shared].bleKeyHex;
    if (!keyHex.length) {
        [self log:@"!! 未取到 bleKeyHex，跳过鉴权帧；若车门不响应请检查 api.key_json_path"];
        return;
    }
    NSString *err = nil;
    uint16_t seq = _seq++;
    NSData *keyData = [self dataFromHexString:keyHex];
    NSData *frame = [_codec buildFrameForCommand:@"auth" payload:keyData seq:seq error:&err];
    if (!frame) { [self log:[NSString stringWithFormat:@"!! auth 组帧失败: %@", err]]; return; }
    [self log:[NSString stringWithFormat:@">> auth seq=%u keyLen=%lu", seq, (unsigned long)keyData.length]];
    [_peripheral writeValue:frame forCharacteristic:_writeChar
                       type:CBCharacteristicWriteWithResponse];
}

- (NSData *)dataFromHexString:(NSString *)hex {
    NSString *s = [hex stringByReplacingOccurrencesOfString:@" " withString:@""];
    if (s.length % 2) s = [@"0" stringByAppendingString:s];
    NSMutableData *d = [NSMutableData dataWithCapacity:s.length / 2];
    for (NSUInteger i = 0; i + 1 < s.length; i += 2) {
        unsigned v = 0;
        if (![[NSScanner scannerWithString:[s substringWithRange:NSMakeRange(i, 2)]] scanHexInt:&v]) break;
        uint8_t b = (uint8_t)v;
        [d appendBytes:&b length:1];
    }
    return d;
}

#pragma mark - CBCentralManagerDelegate

- (void)centralManagerDidUpdateState:(CBCentralManager *)central {
    switch (central.state) {
        case CBManagerStatePoweredOn:
            [self log:@"CBCentralManager poweredOn"];
            if (_wantScan) [self startScan];
            else if (_state == ORIGBleStatePoweredOff) [self setState:ORIGBleStateIdle info:@"蓝牙已开启"];
            break;
        case CBManagerStatePoweredOff:
            [self setState:ORIGBleStatePoweredOff info:@"系统蓝牙已关闭"];
            break;
        case CBManagerStateUnauthorized:
            [self setState:ORIGBleStateFailed info:@"未授权蓝牙权限，请到 设置 里打开"];
            break;
        case CBManagerStateUnsupported:
            [self setState:ORIGBleStateFailed info:@"设备不支持 BLE Central"];
            break;
        default:
            [self log:[NSString stringWithFormat:@"CBCentralManager state=%ld", (long)central.state]];
            break;
    }
}

- (void)centralManager:(CBCentralManager *)central
 didDiscoverPeripheral:(CBPeripheral *)peripheral
     advertisementData:(NSDictionary<NSString *, id> *)advertisementData
                  RSSI:(NSNumber *)RSSI {
    ORIGConfig *cfg = [ORIGConfig shared];
    NSString *prefix = [cfg stringForPath:@"ble.scan_name_prefix" default:@""];
    NSString *localName = advertisementData[CBAdvertisementDataLocalNameKey] ?: peripheral.name ?: @"";
    if (prefix.length && [localName rangeOfString:prefix].location == NSNotFound) return;
    NSInteger threshold = [cfg integerForPath:@"ble.rssi_threshold" default:-85];
    if (RSSI.integerValue < threshold) return;
    if (_peripheral && _state == ORIGBleStateConnecting) return;

    [self stopScan];
    [self log:[NSString stringWithFormat:@"发现 %@ RSSI=%@，开始连接", localName, RSSI]];
    self.peripheral = peripheral;
    peripheral.delegate = self;
    _connectedName = localName;
    [self setState:ORIGBleStateConnecting info:localName];
    [central connectPeripheral:peripheral options:nil];

    double t = [cfg doubleForPath:@"ble.connect_timeout_sec" default:10.0];
    [_connectTimer invalidate];
    _connectTimer = [NSTimer scheduledTimerWithTimeInterval:MAX(1.0, t)
                                                    target:self selector:@selector(connectTimedOut)
                                                  userInfo:nil repeats:NO];
}

- (void)connectTimedOut {
    if (_state != ORIGBleStateConnecting) return;
    [self log:@"!! 连接超时"];
    if (_peripheral) [_central cancelPeripheralConnection:_peripheral];
    _peripheral = nil;
    [self setState:ORIGBleStateFailed info:@"连接超时，可重新扫描"];
}

- (void)centralManager:(CBCentralManager *)central didConnectPeripheral:(CBPeripheral *)peripheral {
    [_connectTimer invalidate];
    [self log:[NSString stringWithFormat:@"已连接 %@，发现服务", peripheral.name ?: _connectedName]];
    [peripheral discoverServices:@[self.serviceUUID]];
}

- (void)centralManager:(CBCentralManager *)central
didFailToConnectPeripheral:(CBPeripheral *)peripheral error:(NSError *)error {
    [_connectTimer invalidate];
    [self setState:ORIGBleStateFailed
              info:[NSString stringWithFormat:@"连接失败: %@", error.localizedDescription ?: @"unknown"]];
}

- (void)centralManager:(CBCentralManager *)central
didDisconnectPeripheral:(CBPeripheral *)peripheral error:(NSError *)error {
    [self log:[NSString stringWithFormat:@"断开 %@ %@", peripheral.name ?: @"", error.localizedDescription ?: @""]];
    [self failAllPending:@"蓝牙连接已断开"];
    _writeChar = nil;
    _notifyChar = nil;
    [self setState:ORIGBleStateIdle info:@"连接已断开，可重新扫描"];
}

- (void)centralManager:(CBCentralManager *)central willRestoreState:(NSDictionary<NSString *, id> *)dict {
    NSArray *peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey];
    if ([peripherals count]) {
        CBPeripheral *p = peripherals[0];
        self.peripheral = p;
        p.delegate = self;
        [self log:[NSString stringWithFormat:@"后台恢复外设 %@", p.name ?: @""]];
    }
}

#pragma mark - CBPeripheralDelegate

- (void)peripheral:(CBPeripheral *)peripheral didDiscoverServices:(NSError *)error {
    if (error) { [self setState:ORIGBleStateFailed info:error.localizedDescription ?: @"服务发现失败"]; return; }
    CBService *target = nil;
    for (CBService *s in peripheral.services) {
        if ([s.UUID isEqual:self.serviceUUID]) { target = s; break; }
    }
    if (!target) {
        [self log:@"服务列表:"];
        for (CBService *s in peripheral.services) [self log:[NSString stringWithFormat:@"  %@", s.UUID.UUIDString]];
        [self setState:ORIGBleStateFailed info:@"未找到配置的服务 UUID，请按上表修改 ble.service_uuid"];
        return;
    }
    [peripheral discoverCharacteristics:@[self.writeUUID, self.notifyUUID] forService:target];
}

- (void)peripheral:(CBPeripheral *)peripheral
didDiscoverCharacteristicsForService:(CBService *)service error:(NSError *)error {
    if (error) { [self setState:ORIGBleStateFailed info:error.localizedDescription ?: @"特征发现失败"]; return; }
    for (CBCharacteristic *c in service.characteristics) {
        if ([c.UUID.UUIDString isEqualToString:self.writeUUID.UUIDString]) _writeChar = c;
        if ([c.UUID.UUIDString isEqualToString:self.notifyUUID.UUIDString]) _notifyChar = c;
    }
    if (!_writeChar) {
        [self log:@"特征列表:"];
        for (CBCharacteristic *c in service.characteristics) [self log:[NSString stringWithFormat:@"  %@", c.UUID.UUIDString]];
        [self setState:ORIGBleStateFailed info:@"未找到写特征，请按上表修改 ble.write_uuid"];
        return;
    }
    if (_notifyChar) [peripheral setNotifyValue:YES forCharacteristic:_notifyChar];
    [self setState:ORIGBleStateReady info:[NSString stringWithFormat:@"%@ 可下发指令", _connectedName]];
    [self sendAuthIfNeeded];
}

- (void)peripheral:(CBPeripheral *)peripheral
didUpdateNotificationStateForCharacteristic:(CBCharacteristic *)characteristic error:(NSError *)error {
    if (error) [self log:[NSString stringWithFormat:@"!! 订阅 notify 失败: %@", error.localizedDescription]];
    else [self log:@"notify 已订阅"];
}

- (void)peripheral:(CBPeripheral *)peripheral
didWriteValueForCharacteristic:(CBCharacteristic *)characteristic error:(NSError *)error {
    if (error) {
        [self log:[NSString stringWithFormat:@"!! 写入失败: %@", error.localizedDescription]];
        // 无法把写入错误映射到具体 seq，交给响应超时统一收口
    } else {
        [self log:@"<< 写入确认，等待车辆应答"];
    }
}

- (void)peripheral:(CBPeripheral *)peripheral
didUpdateValueForCharacteristic:(CBCharacteristic *)characteristic error:(NSError *)error {
    if (error) { [self log:[NSString stringWithFormat:@"!! 读取失败: %@", error.localizedDescription]]; return; }
    NSData *data = characteristic.value;
    [self log:[NSString stringWithFormat:@"<< %@", [_codec hexStringFromData:data ?: [NSData data]]]];

    NSString *cmd = nil, *err = nil;
    NSData *payload = nil;
    uint16_t seq = 0;
    BOOL ok = [_codec parseFrame:data ?: [NSData data]
                      outCommand:&cmd outPayload:&payload outSeq:&seq error:&err];
    if (!ok) { [self log:[NSString stringWithFormat:@"!! 解帧失败: %@", err]]; return; }

    NSNumber *key = @(seq);
    ORIGCompletion block = _pending[key];
    if (!block) { [self log:[NSString stringWithFormat:@"<< 主动上报 %@ seq=%u", cmd, seq]]; return; }
    [_pending removeObjectForKey:key];
    [_timers[key] invalidate];
    [_timers removeObjectForKey:key];
    block(YES, @{@"command" : cmd ?: @"", @"seq" : @(seq),
                 @"payload" : payload ?: [NSData data],
                 @"raw" : data ?: [NSData data]}, nil);
}

@end
