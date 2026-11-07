#import <Cordova/CDV.h>
#import <CoreBluetooth/CoreBluetooth.h>
@interface BluetoothLePlugin : CDVPlugin <CBCentralManagerDelegate, CBPeripheralDelegate> {
@protected
    CBCentralManager *centralManager;
    NSMutableDictionary *connections;
    NSNumber *statusReceiver;
    BOOL writeQIsRunning;
}
#define COMMAND(name) - (void)name:(CDVInvokedUrlCommand *)command;
COMMAND(initialize) COMMAND(startScan) COMMAND(stopScan) COMMAND(connect) COMMAND(reconnect)
COMMAND(disconnect) COMMAND(close) COMMAND(discover) COMMAND(services) COMMAND(characteristics)
COMMAND(descriptors) COMMAND(read) COMMAND(subscribe) COMMAND(unsubscribe) COMMAND(write) COMMAND(writeQ)
COMMAND(readDescriptor) COMMAND(writeDescriptor) COMMAND(rssi)
#undef COMMAND
- (void)centralManager:(CBCentralManager *)central didConnectPeripheral:(CBPeripheral *)peripheral;
- (void)centralManager:(CBCentralManager *)central didDiscoverPeripheral:(CBPeripheral *)peripheral advertisementData:(NSDictionary *)advertisementData RSSI:(NSNumber *)RSSI;
- (void)centralManager:(CBCentralManager *)central didFailToConnectPeripheral:(CBPeripheral *)peripheral error:(NSError *)error;
- (void)centralManager:(CBCentralManager *)central didDisconnectPeripheral:(CBPeripheral *)peripheral error:(NSError *)error;
- (void)peripheral:(CBPeripheral *)peripheral didDiscoverServices:(NSError *)error;
- (void)peripheral:(CBPeripheral *)peripheral didDiscoverCharacteristicsForService:(CBService *)service error:(NSError *)error;
- (void)peripheral:(CBPeripheral *)peripheral didUpdateNotificationStateForCharacteristic:(CBCharacteristic *)characteristic error:(NSError *)error;
- (void)peripheral:(CBPeripheral *)peripheral didUpdateValueForCharacteristic:(CBCharacteristic *)characteristic error:(NSError *)error;
- (void)peripheral:(CBPeripheral *)peripheral didWriteValueForCharacteristic:(CBCharacteristic *)characteristic error:(NSError *)error;
@end
