import CoreBluetooth
import Foundation

/// The latest values from the desk thermometer.
struct DeskReading {
    var temperature: Double
    var humidity: Double?
    var battery: Int?
    var time: Date
}

/// A Bluetooth thermometer on the desk (a Xiaomi MJWSD06MMC running pvvx's
/// firmware), read from the BTHome v2 broadcasts it sends every few seconds:
/// no pairing, no connection, no key. The first one heard is remembered, so a
/// neighbour's never replaces it.
final class DeskThermometer: NSObject, CBCentralManagerDelegate {
    var onReading: ((DeskReading) -> Void)?

    private var central: CBCentralManager?
    private var reading: DeskReading?
    private static let bthome = CBUUID(string: "FCD2")
    private static let deviceKey = "deskThermometer"

    func start() {
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else { return }
        // Duplicates on: each broadcast carries new values from the same device.
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi: NSNumber) {
        guard let data = (advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data])?[Self.bthome],
              let values = Self.parse(data) else { return }
        let id = peripheral.identifier.uuidString
        if let known = UserDefaults.standard.string(forKey: Self.deviceKey) {
            guard known == id else { return }
        } else {
            guard values[0x02] != nil || values[0x45] != nil else { return }
            UserDefaults.standard.set(id, forKey: Self.deviceKey)
        }
        // It alternates two broadcasts: temperature and humidity in one,
        // battery in both or the other.
        let now = Date()
        if let temperature = values[0x02] ?? values[0x45] {
            reading = DeskReading(temperature: temperature, humidity: reading?.humidity,
                                  battery: reading?.battery, time: now)
        }
        guard var reading else { return }
        if let humidity = values[0x03] ?? values[0x2E] { reading.humidity = humidity }
        if let battery = values[0x01] { reading.battery = Int(battery) }
        self.reading = reading
        onReading?(reading)
    }

    /// BTHome v2, unencrypted: object id → value, for the objects whose size
    /// is known (parsing stops at the first unknown one, as sizes vary by id).
    static func parse(_ data: Data) -> [UInt8: Double]? {
        let bytes = [UInt8](data)
        guard let info = bytes.first, info & 0x01 == 0, info >> 5 == 2 else { return nil }
        // Size and scale per object id: packet id, battery %, temperature
        // 0.01°, humidity 0.01 %, voltage, booleans, humidity 1 %, temperature 0.1°.
        let objects: [UInt8: (size: Int, signed: Bool, scale: Double)] = [
            0x00: (1, false, 1), 0x01: (1, false, 1), 0x02: (2, true, 0.01), 0x03: (2, false, 0.01),
            0x0C: (2, false, 0.001), 0x0F: (1, false, 1), 0x10: (1, false, 1), 0x11: (1, false, 1),
            0x2D: (1, false, 1), 0x2E: (1, false, 1), 0x45: (2, true, 0.1),
        ]
        var values: [UInt8: Double] = [:]
        var index = 1
        while index < bytes.count, let object = objects[bytes[index]], index + object.size < bytes.count {
            let id = bytes[index]
            let raw = object.size == 1 ? Int(bytes[index + 1]) : Int(bytes[index + 1]) | Int(bytes[index + 2]) << 8
            let value = object.signed && object.size == 2 ? Int(Int16(truncatingIfNeeded: raw)) : raw
            values[id] = Double(value) * object.scale
            index += 1 + object.size
        }
        return values
    }
}
