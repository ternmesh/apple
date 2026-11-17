// A node's bootloader over Bluetooth LE, through Core Bluetooth: found by the legacy DFU service it
// advertises once the node has restarted into it, and spoken to through that service's control
// point and packet characteristic (DFU.swift has the protocol).
//
// The bootloader is another peripheral to Core Bluetooth than the node: on iOS its identifier is
// not the node's, and it does not advertise the node's service. So it is looked for by its own
// service, on a central of its own, which leaves the node's link, and its wait to connect to the
// node again once the image runs, alone.
//
// Everything Core Bluetooth is touched on the main queue, as in BluetoothLink: the async calls the
// DFU client makes hop there, and are resumed from its callbacks.

#if canImport(CoreBluetooth)
import CoreBluetooth
import Foundation

// Sendable as BluetoothLink's callbacks are safe: every piece of its state is touched on the main
// queue alone.
public final class BootloaderLink: NSObject, BootloaderFinder, DFUTransport, @unchecked Sendable {
    public static let service = CBUUID(string: DFU.service)
    public static let controlPoint = CBUUID(string: DFU.controlPoint)
    public static let packet = CBUUID(string: DFU.packet)

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var control: CBCharacteristic?
    private var packetCharacteristic: CBCharacteristic?

    /// The find under way, and when it gives up.
    private var finding: CheckedContinuation<DFUTransport?, Never>?
    private var findTimeout: DispatchWorkItem?
    /// The control point write awaiting its response.
    private var controlWrite: CheckedContinuation<Void, Error>?
    /// A packet waiting for the link to take it.
    private var packetWrite: (bytes: [UInt8], then: CheckedContinuation<Void, Error>)?
    /// Notifications not yet asked for, and the ask waiting for one.
    private var notifications: [[UInt8]] = []
    private var notificationWait: (then: CheckedContinuation<[UInt8]?, Error>, timeout: DispatchWorkItem)?

    public override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    // MARK: BootloaderFinder

    public func find(within seconds: Double) async -> DFUTransport? {
        await withCheckedContinuation { c in
            DispatchQueue.main.async { self.startFinding(c, seconds) }
        }
    }

    public func disconnect() {
        DispatchQueue.main.async {
            if let p = self.peripheral { self.central.cancelPeripheralConnection(p) }
            self.lost()
            self.peripheral = nil
        }
    }

    private func startFinding(_ c: CheckedContinuation<DFUTransport?, Never>, _ seconds: Double) {
        if let old = finding {
            finding = nil
            old.resume(returning: nil)
        }
        finding = c
        notifications = []
        let timeout = DispatchWorkItem { [weak self] in self?.found(nil) }
        findTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: timeout)
        // Before Bluetooth is on, its state change starts the scan.
        if central.state == .poweredOn { scan() }
    }

    private func scan() {
        guard finding != nil, peripheral == nil else { return }
        central.scanForPeripherals(withServices: [Self.service], options: nil)
    }

    /// The find is over: with the bootloader connected and subscribed, or with nothing.
    private func found(_ transport: DFUTransport?) {
        guard let c = finding else { return }
        finding = nil
        findTimeout?.cancel()
        findTimeout = nil
        if central.state == .poweredOn { central.stopScan() }
        if transport == nil, let p = peripheral {
            central.cancelPeripheralConnection(p)
            peripheral = nil
        }
        c.resume(returning: transport)
    }

    // MARK: DFUTransport

    public func writeControl(_ bytes: [UInt8]) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            DispatchQueue.main.async {
                guard let p = self.peripheral, p.state == .connected, let control = self.control else {
                    return c.resume(throwing: DFUError.lost)
                }
                self.controlWrite = c
                p.writeValue(Data(bytes), for: control, type: .withResponse)
            }
        }
    }

    public func writePacket(_ bytes: [UInt8]) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            DispatchQueue.main.async {
                guard let p = self.peripheral, p.state == .connected, self.packetCharacteristic != nil else {
                    return c.resume(throwing: DFUError.lost)
                }
                // Without a response, Core Bluetooth drops what it has no room for: a packet waits
                // for the link to be ready for it.
                if p.canSendWriteWithoutResponse {
                    self.sendPacket(bytes)
                    c.resume()
                } else {
                    self.packetWrite = (bytes, c)
                }
            }
        }
    }

    public func notification(within seconds: Double) async throws -> [UInt8]? {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<[UInt8]?, Error>) in
            DispatchQueue.main.async {
                if !self.notifications.isEmpty { return c.resume(returning: self.notifications.removeFirst()) }
                guard self.peripheral?.state == .connected else { return c.resume(throwing: DFUError.lost) }
                let timeout = DispatchWorkItem {
                    guard let wait = self.notificationWait else { return }
                    self.notificationWait = nil
                    wait.then.resume(returning: nil)
                }
                self.notificationWait = (c, timeout)
                DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: timeout)
            }
        }
    }

    public func pause(_ seconds: Double) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private func sendPacket(_ bytes: [UInt8]) {
        guard let p = peripheral, let packet = packetCharacteristic else { return }
        p.writeValue(Data(bytes), for: packet, type: .withoutResponse)
    }

    /// The link went: everything waiting on it fails.
    private func lost() {
        control = nil
        packetCharacteristic = nil
        if let c = controlWrite {
            controlWrite = nil
            c.resume(throwing: DFUError.lost)
        }
        if let w = packetWrite {
            packetWrite = nil
            w.then.resume(throwing: DFUError.lost)
        }
        if let w = notificationWait {
            notificationWait = nil
            w.timeout.cancel()
            w.then.resume(throwing: DFUError.lost)
        }
    }
}

extension BootloaderLink: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            scan()
        } else {
            peripheral = nil
            lost()
        }
    }

    public func centralManager(
        _ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        // The first bootloader seen: one is waiting only when a client that may drive the node
        // asked it to restart into it.
        guard finding != nil, self.peripheral == nil else { return }
        central.stopScan()
        self.peripheral = peripheral
        peripheral.delegate = self
        central.connect(peripheral, options: nil)
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard peripheral == self.peripheral else { return }
        peripheral.discoverServices([Self.service])
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard peripheral == self.peripheral else { return }
        // Not this one: look again while there is time.
        self.peripheral = nil
        scan()
    }

    public func centralManager(
        _ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?
    ) {
        guard peripheral == self.peripheral else { return }
        self.peripheral = nil
        lost()
        if finding != nil { scan() }
    }
}

extension BootloaderLink: CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard peripheral == self.peripheral else { return }
        guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == Self.service }) else {
            return found(nil)
        }
        peripheral.discoverCharacteristics([Self.controlPoint, Self.packet], for: service)
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard peripheral == self.peripheral, service.uuid == Self.service else { return }
        let chars = service.characteristics ?? []
        guard error == nil, let control = chars.first(where: { $0.uuid == Self.controlPoint }),
              let packet = chars.first(where: { $0.uuid == Self.packet })
        else { return found(nil) }
        self.control = control
        packetCharacteristic = packet
        peripheral.setNotifyValue(true, for: control)
    }

    public func peripheral(
        _ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?
    ) {
        guard peripheral == self.peripheral, characteristic.uuid == Self.controlPoint else { return }
        found(error == nil && characteristic.isNotifying ? self : nil)
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral == self.peripheral, characteristic.uuid == Self.controlPoint, error == nil,
              let value = characteristic.value
        else { return }
        let bytes = [UInt8](value)
        if let wait = notificationWait {
            notificationWait = nil
            wait.timeout.cancel()
            wait.then.resume(returning: bytes)
        } else {
            notifications.append(bytes)
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral == self.peripheral, characteristic.uuid == Self.controlPoint, let c = controlWrite else { return }
        controlWrite = nil
        if error != nil { c.resume(throwing: DFUError.lost) } else { c.resume() }
    }

    public func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        guard peripheral == self.peripheral, let w = packetWrite else { return }
        packetWrite = nil
        sendPacket(w.bytes)
        w.then.resume()
    }
}
#endif
