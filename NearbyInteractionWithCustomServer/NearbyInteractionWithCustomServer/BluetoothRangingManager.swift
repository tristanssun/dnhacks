import CoreBluetooth
import Foundation

final class BluetoothRangingManager: NSObject {
  static let serviceUUID = CBUUID(string: "D0A1C0DE-4E49-48A1-9B10-0C0DE0000001")
  static let codeUUID = CBUUID(string: "D0A1C0DE-4E49-48A1-9B10-0C0DE0000002")

  var onDistance: ((Float) -> Void)?
  var onStatus: ((String) -> Void)?

  private var central: CBCentralManager?
  private var peripheralManager: CBPeripheralManager?
  private var advertisedService: CBMutableService?
  private var myCode = 0
  private var peerCode = 0
  private var shouldRun = false
  private var peripherals: [UUID: CBPeripheral] = [:]
  private var identifying: Set<UUID> = []
  private var peerPeripheral: CBPeripheral?
  private var rssiTimer: Timer?
  private var smoothedRSSI: Double?

  func start(myCode: Int, peerCode: Int) {
    self.myCode = myCode
    self.peerCode = peerCode
    self.shouldRun = true
    self.smoothedRSSI = nil
    self.prepareManagers()
    self.tryStart()
  }

  func stop() {
    self.shouldRun = false
    self.rssiTimer?.invalidate()
    self.rssiTimer = nil
    self.smoothedRSSI = nil
    self.peerPeripheral = nil
    self.identifying.removeAll()

    if let central = self.central {
      if central.state == .poweredOn {
        central.stopScan()
      }
      for peripheral in self.peripherals.values {
        central.cancelPeripheralConnection(peripheral)
      }
    }
    self.peripherals.removeAll()

    if let peripheralManager = self.peripheralManager, peripheralManager.state == .poweredOn {
      peripheralManager.stopAdvertising()
      peripheralManager.removeAllServices()
    }
    self.advertisedService = nil
  }

  private func prepareManagers() {
    if self.central == nil {
      self.central = CBCentralManager(delegate: self, queue: .main)
    }
    if self.peripheralManager == nil {
      self.peripheralManager = CBPeripheralManager(delegate: self, queue: .main)
    }
  }

  private func tryStart() {
    guard self.shouldRun else { return }
    guard let central = self.central, let peripheralManager = self.peripheralManager else {
      return
    }

    if central.state == .unauthorized || peripheralManager.state == .unauthorized {
      self.onStatus?("Bluetooth permission is denied in Settings.")
      return
    }
    if central.state == .poweredOff || peripheralManager.state == .poweredOff {
      self.onStatus?("Turn on Bluetooth to measure distance.")
      return
    }
    guard central.state == .poweredOn, peripheralManager.state == .poweredOn else {
      self.onStatus?("Waiting for Bluetooth…")
      return
    }

    self.startAdvertising()
    self.startScanning()
    self.onStatus?("Searching for peer \(String(format: "%04d", self.peerCode)) over Bluetooth…")
  }

  private func startAdvertising() {
    guard let peripheralManager = self.peripheralManager else { return }

    let codeData = String(format: "%04d", self.myCode).data(using: .utf8)
    let characteristic = CBMutableCharacteristic(
      type: Self.codeUUID,
      properties: [.read],
      value: codeData,
      permissions: [.readable]
    )
    let service = CBMutableService(type: Self.serviceUUID, primary: true)
    service.characteristics = [characteristic]
    self.advertisedService = service

    peripheralManager.stopAdvertising()
    peripheralManager.removeAllServices()
    peripheralManager.add(service)
  }

  private func startScanning() {
    guard let central = self.central, central.state == .poweredOn else { return }
    central.stopScan()
    central.scanForPeripherals(
      withServices: [Self.serviceUUID],
      options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
    )
  }

  private func applyRSSI(_ rssi: NSNumber) {
    let raw = rssi.doubleValue
    guard raw < 0, raw > -100 else { return }

    if let previous = self.smoothedRSSI {
      self.smoothedRSSI = 0.28 * raw + 0.72 * previous
    } else {
      self.smoothedRSSI = raw
    }

    guard let smoothed = self.smoothedRSSI else { return }
    // Path-loss estimate: d = 10^((TxPower - RSSI) / (10 * n))
    let txPowerAtOneMeter = -59.0
    let pathLossExponent = 2.2
    let meters = pow(10.0, (txPowerAtOneMeter - smoothed) / (10.0 * pathLossExponent))
    let clamped = min(max(meters, 0.1), 40.0)
    self.onDistance?(Float(clamped))
  }

  private func lockOnPeer(_ peripheral: CBPeripheral) {
    self.peerPeripheral = peripheral
    self.startRSSITimer()
    self.onStatus?("Bluetooth peer found. Distance is an RSSI estimate.")
  }

  private func startRSSITimer() {
    self.rssiTimer?.invalidate()
    self.rssiTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
      self?.peerPeripheral?.readRSSI()
    }
  }

  private func identify(_ peripheral: CBPeripheral) {
    if self.identifying.contains(peripheral.identifier) || self.peerPeripheral != nil {
      return
    }
    self.identifying.insert(peripheral.identifier)
    self.peripherals[peripheral.identifier] = peripheral
    self.central?.connect(peripheral, options: nil)
  }

  private func advertisedCode(from advertisementData: [String: Any]) -> Int? {
    if let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String,
      let code = Int(name.filter(\.isNumber))
    {
      return code
    }
    if let manufacturer = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
      manufacturer.count >= 4
    {
      return Int(manufacturer[2]) << 8 | Int(manufacturer[3])
    }
    return nil
  }
}

extension BluetoothRangingManager: CBCentralManagerDelegate {
  func centralManagerDidUpdateState(_ central: CBCentralManager) {
    self.tryStart()
  }

  func centralManager(
    _ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
    advertisementData: [String: Any], rssi RSSI: NSNumber
  ) {
    self.peripherals[peripheral.identifier] = peripheral

    if let code = self.advertisedCode(from: advertisementData), code == self.peerCode {
      self.lockOnPeer(peripheral)
      self.applyRSSI(RSSI)
      return
    }

    if peripheral.identifier == self.peerPeripheral?.identifier {
      self.applyRSSI(RSSI)
      return
    }

    self.identify(peripheral)
  }

  func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
    peripheral.delegate = self
    peripheral.discoverServices([Self.serviceUUID])
  }

  func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
    self.identifying.remove(peripheral.identifier)
  }

  func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
    if peripheral.identifier == self.peerPeripheral?.identifier {
      self.peerPeripheral = nil
      if self.shouldRun {
        self.onStatus?("Lost Bluetooth peer. Searching again…")
        self.startScanning()
      }
    }
    self.identifying.remove(peripheral.identifier)
  }
}

extension BluetoothRangingManager: CBPeripheralDelegate {
  func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
    guard let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else {
      self.central?.cancelPeripheralConnection(peripheral)
      return
    }
    peripheral.discoverCharacteristics([Self.codeUUID], for: service)
  }

  func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
    guard let characteristic = service.characteristics?.first(where: { $0.uuid == Self.codeUUID }) else {
      self.central?.cancelPeripheralConnection(peripheral)
      return
    }
    peripheral.readValue(for: characteristic)
  }

  func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
    guard let data = characteristic.value,
      let string = String(data: data, encoding: .utf8),
      let code = Int(string)
    else {
      self.central?.cancelPeripheralConnection(peripheral)
      return
    }

    if code == self.peerCode {
      self.lockOnPeer(peripheral)
      peripheral.readRSSI()
    } else {
      self.central?.cancelPeripheralConnection(peripheral)
    }
  }

  func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
    guard error == nil, peripheral.identifier == self.peerPeripheral?.identifier else { return }
    self.applyRSSI(RSSI)
  }
}

extension BluetoothRangingManager: CBPeripheralManagerDelegate {
  func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
    self.tryStart()
  }

  func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
    guard error == nil, self.shouldRun, peripheral.state == .poweredOn else { return }
    peripheral.startAdvertising([
      CBAdvertisementDataServiceUUIDsKey: [Self.serviceUUID],
      CBAdvertisementDataLocalNameKey: String(format: "%04d", self.myCode),
    ])
  }

  func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
    if let error = error {
      self.onStatus?("Bluetooth advertising failed: \(error.localizedDescription)")
    }
  }
}
