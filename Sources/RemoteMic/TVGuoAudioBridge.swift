import Foundation
import CoreBluetooth

protocol TVGuoAudioBridgeDelegate: AnyObject {
    func tvguoBridgeDidStartVoice(_ bridge: TVGuoAudioBridge)
    func tvguoBridgeDidStopVoice(_ bridge: TVGuoAudioBridge)
    func tvguoBridge(_ bridge: TVGuoAudioBridge, didDecode samples: [Int16])
    func tvguoBridge(_ bridge: TVGuoAudioBridge, didUpdateBatteryLevel level: Int?)
}

final class TVGuoAudioBridge: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    static let shared = TVGuoAudioBridge()
    
    weak var delegate: TVGuoAudioBridgeDelegate?
    
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var audioCharacteristic: CBCharacteristic?
    
    // IMA-ADPCM state
    private var predictedSample: Int32 = 0
    private var stepIndex: Int = 0
    private var isStreaming = false
    private var streamEndTimer: Timer?
    
    private let stepTable: [Int32] = [
        7, 8, 9, 10, 11, 12, 13, 14, 16, 17,
        19, 21, 23, 25, 28, 31, 34, 37, 41, 45,
        50, 55, 60, 66, 73, 80, 88, 97, 107, 118,
        130, 143, 157, 173, 190, 209, 230, 253, 279, 307,
        337, 371, 408, 449, 494, 544, 598, 658, 724, 796,
        876, 963, 1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066,
        2272, 2499, 2749, 3024, 3327, 3660, 4026, 4428, 4871, 5358,
        5894, 6484, 7132, 7845, 8630, 9493, 10442, 11487, 12635, 13899,
        15289, 16818, 18500, 20350, 22385, 24623, 27086, 29794, 32767
    ]
    
    private let indexTable: [Int] = [
        -1, -1, -1, -1, 2, 4, 6, 8,
        -1, -1, -1, -1, 2, 4, 6, 8
    ]
    
    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }
    
    func start() {
        if central.state == .poweredOn {
            scanOrRetrieve()
        }
    }
    
    func stop() {
        if let p = peripheral {
            central.cancelPeripheralConnection(p)
        }
        peripheral = nil
    }
    
    private func scanOrRetrieve() {
        let connected = central.retrieveConnectedPeripherals(withServices: [
            CBUUID(string: "1812"), // HID Service
            CBUUID(string: "180A"), // Device Info
            CBUUID(string: "180F"), // Battery
            CBUUID(string: "F000FFC0-0451-4000-B000-000000000000")
        ])
        for p in connected where isTVGuoPeripheral(p) {
            connect(p)
            return
        }
        central.scanForPeripherals(withServices: nil, options: nil)
    }
    
    private func isTVGuoPeripheral(_ p: CBPeripheral) -> Bool {
        let name = (p.name ?? "").lowercased()
        return name.contains("qiyi") || name.contains("电视果") || name.contains("b713")
    }
    
    private func connect(_ p: CBPeripheral) {
        peripheral = p
        p.delegate = self
        central.connect(p, options: nil)
    }
    
    // MARK: - CBCentralManagerDelegate
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            scanOrRetrieve()
        }
    }
    
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        let name = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? ""
        if name.lowercased().contains("qiyi") || name.contains("电视果") || name.lowercased().contains("b713") {
            central.stopScan()
            connect(peripheral)
        }
    }
    
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        AppLogger.shared.write("TVGuoAudioBridge connected to \(peripheral.name ?? "remote")")
        peripheral.discoverServices(nil)
    }
    
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        AppLogger.shared.write("TVGuoAudioBridge disconnected, reconnecting...")
        if isStreaming {
            isStreaming = false
            delegate?.tvguoBridgeDidStopVoice(self)
        }
        scanOrRetrieve()
    }
    
    // MARK: - CBPeripheralDelegate
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        for s in peripheral.services ?? [] {
            peripheral.discoverCharacteristics(nil, for: s)
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for c in service.characteristics ?? [] {
            // Report 0x5A or notification characteristics
            if c.properties.contains(.notify) {
                peripheral.setNotifyValue(true, for: c)
            }
            peripheral.discoverDescriptors(for: c)
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverDescriptorsFor characteristic: CBCharacteristic, error: Error?) {
        for d in characteristic.descriptors ?? [] {
            // Client Characteristic Configuration Descriptor
            if d.uuid.uuidString == "2902" {
                // Actively write 01 00 to turn on notifications (Unlocks Report 0x5A Audio Stream!)
                peripheral.writeValue(Data([0x01, 0x00]), for: d)
            }
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value else { return }
        
        // Handle Battery
        if characteristic.uuid == CBUUID(string: "2A19"), let first = data.first {
            delegate?.tvguoBridge(self, didUpdateBatteryLevel: Int(first))
            return
        }
        
        // Handle 19-byte audio frames from Report 0x5A
        if data.count == 19 {
            handleAudioPacket(data)
        }
    }
    
    private func handleAudioPacket(_ data: Data) {
        if !isStreaming {
            isStreaming = true
            predictedSample = 0
            stepIndex = 0
            delegate?.tvguoBridgeDidStartVoice(self)
        }
        
        // Reset watchdog timer
        streamEndTimer?.invalidate()
        streamEndTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { [weak self] _ in
            guard let self, self.isStreaming else { return }
            self.isStreaming = false
            self.delegate?.tvguoBridgeDidStopVoice(self)
        }
        
        // Byte 0 is packet counter/flags
        // Bytes 1..18 are 36 IMA-ADPCM nibbles (Low nibble first)
        var decodedSamples = [Int16]()
        decodedSamples.reserveCapacity(36)
        
        for i in 1..<data.count {
            let byte = data[i]
            let lowNibble = Int(byte & 0x0F)
            let highNibble = Int((byte >> 4) & 0x0F)
            
            decodeNibble(lowNibble, into: &decodedSamples)
            decodeNibble(highNibble, into: &decodedSamples)
        }
        
        delegate?.tvguoBridge(self, didDecode: decodedSamples)
    }
    
    private func decodeNibble(_ nibble: Int, into output: inout [Int16]) {
        let step = stepTable[stepIndex]
        var diff = step >> 3
        if (nibble & 4) != 0 { diff += step }
        if (nibble & 2) != 0 { diff += (step >> 1) }
        if (nibble & 1) != 0 { diff += (step >> 2) }
        
        if (nibble & 8) != 0 {
            predictedSample -= diff
        } else {
            predictedSample += diff
        }
        
        if predictedSample > 32767 { predictedSample = 32767 }
        else if predictedSample < -32768 { predictedSample = -32768 }
        
        stepIndex += indexTable[nibble]
        if stepIndex < 0 { stepIndex = 0 }
        else if stepIndex > 88 { stepIndex = 88 }
        
        output.append(Int16(predictedSample))
    }
}
