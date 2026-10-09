// A node over Bluetooth LE, through Core Bluetooth: finding nodes, connecting to one, pairing,
// and carrying a Connection's frames, one to a write and one to a notification, as the
// specification's Bluetooth LE section says. No byte-stream wrapping: the link delimits each.
//
// Everything runs on the main queue. Core Bluetooth calls back there because the central is made
// with no queue of its own, and a Connection, which is not thread-safe, is only ever touched
// from those callbacks and from the app's main thread.

#if canImport(CoreBluetooth)
import CoreBluetooth
import Foundation

/// A node seen advertising the companion service.
public struct FoundNode: Identifiable, Equatable {
    /// Core Bluetooth's identifier for the peripheral: this device's own, not the node's address,
    /// which a node never advertises.
    public var id: UUID
    public var name: String
    public var rssi: Int
}

public final class BluetoothLink: NSObject {
    public enum State: Equatable {
        /// Core Bluetooth has not said yet.
        case starting
        case unsupported
        /// The user has not let the app use Bluetooth.
        case unauthorized
        case poweredOff
        /// No node chosen, and not looking for one.
        case idle
        /// The user disconnected from the remembered node: nothing connects until they connect again.
        case disconnected
        case scanning
        /// Waiting to connect to the chosen node: iOS keeps the request until it is in range.
        case connecting
        /// Subscribing, which needs an encrypted link: iOS asks for the node's passkey if they
        /// are not paired yet.
        case pairing
        /// `HELLO` sent.
        case opening
        /// The node answered, and the first sync is under way.
        case syncing
        case ready
        case failed(Failure)
    }

    public enum Failure: Equatable {
        /// Pairing did not finish: the wrong passkey, cancelled, or a bond the node no longer has.
        case pairing
        /// The link's MTU leaves less than a frame: `maximum` is the most one write may carry.
        case mtu(maximum: Int)
        /// The node refused the `HELLO` with this code.
        case refused(code: UInt8)
        /// The peripheral does not offer the service, or not both characteristics.
        case notTern
    }

    public static let service = CBUUID(string: Companion.service)
    public static let toNode = CBUUID(string: Companion.toNode)
    public static let fromNode = CBUUID(string: Companion.fromNode)

    /// The clock a Connection on this link keeps time by. The link's timers run by it too.
    public static func clock() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }

    public private(set) var state: State = .starting {
        didSet { if state != oldValue { onState(state) } }
    }
    /// Nodes seen since scanning began, nearest first.
    public private(set) var found: [FoundNode] = [] {
        didSet { onFound(found) }
    }
    /// The node this link connects to, and connects to again whenever it can. Kept across runs.
    public private(set) var remembered: UUID?
    /// The connection to the remembered node, once the link has been opened to it. Kept across
    /// reconnects, so the records in it are kept too.
    public private(set) var connection: Connection?
    /// The user disconnected from the remembered node, and has not connected again. Kept across
    /// runs, so the app does not connect by itself when it next starts.
    public private(set) var isDisconnected = false

    public var onState: (State) -> Void = { _ in }
    public var onFound: ([FoundNode]) -> Void = { _ in }
    /// Every event of the connection, after the link has acted on it.
    public var onEvent: (ConnectionEvent) -> Void = { _ in }
    /// Makes the connection for a node, with whatever records the app kept of it.
    public var makeConnection: (UUID) -> Connection = { _ in
        Connection(now: BluetoothLink.clock, wallTime: { UInt32(Date().timeIntervalSince1970) })
    }

    private static let rememberedKey = "org.ternmesh.tern.node"
    private static let disconnectedKey = "org.ternmesh.tern.node.disconnected"
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var seen: [UUID: CBPeripheral] = [:]
    private var writer: CBCharacteristic?
    /// The user wants the remembered node connected: false after a failure, until they try again.
    private var wanted = false
    private var scanning = false
    private var timer: Timer?

    /// - Parameter restoreIdentifier: lets iOS relaunch the app in the background for its node
    ///   and hand the connection back. Ignored on a Mac, which does not restore.
    public init(restoreIdentifier: String? = "org.ternmesh.tern.central") {
        super.init()
        remembered = UserDefaults.standard.string(forKey: Self.rememberedKey).flatMap(UUID.init(uuidString:))
        isDisconnected = remembered != nil && UserDefaults.standard.bool(forKey: Self.disconnectedKey)
        wanted = remembered != nil && !isDisconnected
        var options: [String: Any] = [CBCentralManagerOptionShowPowerAlertKey: true]
        #if os(iOS)
        if let restoreIdentifier { options[CBCentralManagerOptionRestoreIdentifierKey] = restoreIdentifier }
        #endif
        central = CBCentralManager(delegate: self, queue: nil, options: options)
    }

    // MARK: What the app asks

    /// Looks for nodes nearby. Only while the app is in front: scanning for a service in the
    /// background finds little and costs battery.
    public func startScanning() {
        scanning = true
        found = []
        guard central.state == .poweredOn else { return }
        central.scanForPeripherals(
            withServices: [Self.service], options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        if peripheral == nil || !wanted { state = .scanning }
    }

    public func stopScanning() {
        scanning = false
        if central.state == .poweredOn { central.stopScan() }
        if state == .scanning { settle() }
        // Still looking for the remembered node, which Core Bluetooth had forgotten.
        if wanted, peripheral == nil { reconnect() }
    }

    /// Connects to a node found by scanning, and remembers it in place of any other.
    public func connect(to id: UUID) {
        if remembered == id, wanted, [.pairing, .opening, .syncing, .ready].contains(state) { return stopScanning() }
        if let old = peripheral, old.identifier != id {
            drop(old)
            // Not the node any more: a scan that finds the new one connects only with no peripheral held.
            peripheral = nil
        }
        if remembered != id {
            connection?.close()
            connection = nil
        }
        remembered = id
        UserDefaults.standard.set(id.uuidString, forKey: Self.rememberedKey)
        setDisconnected(false)
        stopScanning()
        wanted = true
        reconnect()
    }

    /// Tries again after a failure (pairing, the MTU or a refused `HELLO`), or connects again after
    /// the user disconnected.
    public func retry() {
        guard remembered != nil else { return }
        setDisconnected(false)
        wanted = true
        if let p = peripheral, p.state == .connected || p.state == .connecting {
            // Its didDisconnect connects again.
            drop(p)
            state = .connecting
        } else {
            reconnect()
        }
    }

    /// Disconnects from the remembered node and stays off it, across runs too, until `retry` or
    /// `connect(to:)`. The node stays remembered, and so does the connection with its records:
    /// connecting again syncs only what is new.
    public func disconnect() {
        guard remembered != nil else { return }
        wanted = false
        setDisconnected(true)
        if let p = peripheral { drop(p) }
        settle()
    }

    private func setDisconnected(_ off: Bool) {
        isDisconnected = off
        if off {
            UserDefaults.standard.set(true, forKey: Self.disconnectedKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.disconnectedKey)
        }
    }

    /// Disconnects, and forgets the node. The bond stays in the system's Bluetooth settings until
    /// the user forgets it there.
    public func forget() {
        wanted = false
        if let p = peripheral { drop(p) }
        peripheral = nil
        connection?.close()
        connection = nil
        remembered = nil
        UserDefaults.standard.removeObject(forKey: Self.rememberedKey)
        setDisconnected(false)
        settle()
    }

    // MARK: -

    /// Asks Core Bluetooth to connect to the remembered node. A `connect` does not time out, so
    /// when the node is out of range iOS connects the moment it is back, even with the app in the
    /// background.
    private func reconnect() {
        guard wanted, central.state == .poweredOn, let id = remembered else { return }
        let p = peripheral?.identifier == id
            ? peripheral
            : seen[id] ?? central.retrievePeripherals(withIdentifiers: [id]).first
        guard let p else {
            // Core Bluetooth no longer knows it: look for it, and connect when it is seen.
            if !scanning { central.scanForPeripherals(withServices: [Self.service], options: nil) }
            state = .connecting
            return
        }
        peripheral = p
        p.delegate = self
        state = .connecting
        if p.state == .connected {
            discover(p)
        } else if p.state != .connecting {
            central.connect(p, options: nil)
        }
    }

    /// Lets go of a peripheral: the connection over it is closed, and no callback of its counts.
    private func drop(_ p: CBPeripheral) {
        stopTimer()
        connection?.close()
        writer = nil
        if p.state == .connected || p.state == .connecting {
            central.cancelPeripheralConnection(p)
        }
    }

    private func fail(_ failure: Failure) {
        wanted = false
        if let p = peripheral { drop(p) }
        state = .failed(failure)
    }

    /// The state when nothing is under way.
    private func settle() {
        switch central.state {
        case .unsupported: state = .unsupported
        case .unauthorized: state = .unauthorized
        case .poweredOff: state = .poweredOff
        case .poweredOn: state = scanning ? .scanning : wanted ? .connecting : isDisconnected ? .disconnected : .idle
        default: state = .starting
        }
    }

    private func discover(_ p: CBPeripheral) {
        p.discoverServices([Self.service])
    }

    /// Both characteristics found and subscribed: the link carries frames from here.
    private func open(_ p: CBPeripheral, writer: CBCharacteristic) {
        // A write with response may be longer than the ATT MTU, as a long write; a notification
        // may not. The length without response is the MTU less 3, so it is what says whether the
        // node's frames fit.
        let maximum = p.maximumWriteValueLength(for: .withoutResponse)
        guard maximum >= Companion.maxFrame else { return fail(.mtu(maximum: maximum)) }
        self.writer = writer
        let c: Connection
        if let connection {
            c = connection
        } else {
            c = makeConnection(p.identifier)
            connection = c
        }
        c.send = { [weak self] bytes in self?.write(bytes) }
        c.onEvent = { [weak self] event in self?.handle(event) }
        state = .opening
        c.close()
        c.open()
        schedule()
    }

    private func write(_ bytes: [UInt8]) {
        guard let p = peripheral, let writer else { return }
        p.writeValue(Data(bytes), for: writer, type: .withResponse)
        // A request just went: its answer is due.
        schedule()
    }

    private func handle(_ event: ConnectionEvent) {
        switch event {
        case .ready:
            state = .syncing
        case .synced:
            state = .ready
        case let .refused(code):
            fail(code == ErrorCode.mtu ? .mtu(maximum: peripheral?.maximumWriteValueLength(for: .withoutResponse) ?? 0)
                : .refused(code: code))
        case .gone:
            // Disconnecting brings the delegate's didDisconnect, which connects again.
            if let p = peripheral {
                stopTimer()
                writer = nil
                state = .connecting
                central.cancelPeripheralConnection(p)
            }
        case .news, .syncRefused:
            break
        }
        onEvent(event)
    }

    // MARK: The Connection's clock

    private func schedule() {
        stopTimer()
        guard let deadline = connection?.nextDeadline else { return }
        let delay = max(0, deadline - Self.clock()) + 0.01
        timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.timer = nil
            self.connection?.tick()
            self.schedule()
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    /// Whether an error means the link was not encrypted as the characteristics require: pairing
    /// failed or was cancelled, or one side has lost the bond.
    private static func isPairing(_ error: Error) -> Bool {
        let e = error as NSError
        if e.domain == CBATTErrorDomain {
            return e.code == CBATTError.Code.insufficientAuthentication.rawValue
                || e.code == CBATTError.Code.insufficientEncryption.rawValue
                || e.code == CBATTError.Code.insufficientAuthorization.rawValue
        }
        if e.domain == CBErrorDomain {
            // 14 peerRemovedPairingInformation, 15 encryptionTimedOut: by number, since the names
            // are not in every SDK this builds with.
            return e.code == 14 || e.code == 15
        }
        return false
    }
}

extension BluetoothLink: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else {
            // Bluetooth went off, or was never on: every peripheral is gone, with no callback.
            if central.state == .poweredOff { peripheral = nil }
            stopTimer()
            connection?.close()
            writer = nil
            settle()
            return
        }
        if scanning { startScanning() }
        if case .failed = state { return }
        settle()
        reconnect()
    }

    #if os(iOS)
    public func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        // iOS relaunched the app for its node: take the peripheral back. Once Bluetooth is on,
        // `reconnect` finds it connected or connecting and carries on from there.
        let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        if let p = restored.first(where: { $0.identifier == remembered }) {
            peripheral = p
            p.delegate = self
        }
    }
    #endif

    public func centralManager(
        _ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        seen[peripheral.identifier] = peripheral
        if wanted, peripheral.identifier == remembered, self.peripheral == nil {
            // The remembered node, which Core Bluetooth had forgotten, is back.
            if !scanning { central.stopScan() }
            reconnect()
        }
        guard scanning else { return }
        // 127 is Core Bluetooth's "not available".
        let rssi = RSSI.intValue
        guard rssi != 127 else { return }
        let name = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? "Tern node"
        var list = found
        let node = FoundNode(id: peripheral.identifier, name: name, rssi: rssi)
        if let i = list.firstIndex(where: { $0.id == node.id }) {
            // Notifications of the same node come many times a second: move it only when its
            // signal has changed enough to say so.
            if list[i].name == node.name, abs(list[i].rssi - node.rssi) < 6 { return }
            list[i] = node
        } else {
            list.append(node)
        }
        found = list.sorted { $0.rssi > $1.rssi }
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard peripheral.identifier == remembered, wanted else {
            central.cancelPeripheralConnection(peripheral)
            return
        }
        self.peripheral = peripheral
        peripheral.delegate = self
        discover(peripheral)
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard peripheral.identifier == remembered else { return }
        if let error, Self.isPairing(error) { return fail(.pairing) }
        reconnect()
    }

    public func centralManager(
        _ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?
    ) {
        guard peripheral.identifier == remembered else { return }
        stopTimer()
        connection?.close()
        writer = nil
        if let error, Self.isPairing(error) { return fail(.pairing) }
        if wanted {
            reconnect()
        } else if case .failed = state {
            return
        } else {
            settle()
        }
    }
}

extension BluetoothLink: CBPeripheralDelegate {
    /// Something other than pairing went wrong on the link, part way to opening it: what the node
    /// has is unknown, not missing, so the link starts again rather than giving up on it.
    private func restart() {
        if let p = self.peripheral {
            drop(p)
            state = .connecting
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard peripheral == self.peripheral else { return }
        if let error { return Self.isPairing(error) ? fail(.pairing) : restart() }
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.service }) else {
            return fail(.notTern)
        }
        peripheral.discoverCharacteristics([Self.toNode, Self.fromNode], for: service)
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard peripheral == self.peripheral, service.uuid == Self.service else { return }
        if let error { return Self.isPairing(error) ? fail(.pairing) : restart() }
        let chars = service.characteristics ?? []
        guard chars.contains(where: { $0.uuid == Self.toNode }),
              let from = chars.first(where: { $0.uuid == Self.fromNode })
        else { return fail(.notTern) }
        // The characteristic needs an encrypted link: subscribing to an unpaired node makes iOS
        // pair, and ask the user for the passkey the node shows.
        state = .pairing
        peripheral.setNotifyValue(true, for: from)
    }

    public func peripheral(
        _ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?
    ) {
        guard peripheral == self.peripheral, characteristic.uuid == Self.fromNode else { return }
        if let error {
            return Self.isPairing(error) ? fail(.pairing) : restart()
        }
        guard characteristic.isNotifying,
              let writer = characteristic.service?.characteristics?.first(where: { $0.uuid == Self.toNode })
        else { return }
        open(peripheral, writer: writer)
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral == self.peripheral, characteristic.uuid == Self.fromNode, error == nil,
              let value = characteristic.value, writer != nil
        else { return }
        connection?.receive([UInt8](value))
        schedule()
    }

    public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        // A write that fails otherwise goes unanswered, and the connection gives up on it in time.
        if let error, peripheral == self.peripheral, Self.isPairing(error) { fail(.pairing) }
    }

    public func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        guard peripheral == self.peripheral, invalidatedServices.contains(where: { $0.uuid == Self.service }) else {
            return
        }
        // The node's firmware changed under the link: find the service again.
        stopTimer()
        connection?.close()
        writer = nil
        state = .connecting
        discover(peripheral)
    }
}
#endif
