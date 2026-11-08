import CoreBluetooth
import Foundation

enum BandError: LocalizedError {
    case bluetoothUnavailable
    case notFound
    case disconnected
    case missingCharacteristics
    case timeout
    case rejected

    var errorDescription: String? {
        switch self {
        case .bluetoothUnavailable: return "Bluetooth is unavailable. Turn it on in Settings."
        case .notFound: return "No Noise REP band was found. Wake it or place it on its charger."
        case .disconnected: return "The band disconnected."
        case .missingCharacteristics: return "The band did not expose the expected protocol characteristics."
        case .timeout: return "The band did not answer in time."
        case .rejected: return "The band rejected a transfer."
        }
    }
}

@MainActor
final class BandConnection: NSObject, @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    private let serviceID = CBUUID(string: "16186f00-0000-1000-8000-00807f9b34fb")
    private let readID = CBUUID(string: "16186f01-0000-1000-8000-00807f9b34fb")
    private let writeID = CBUUID(string: "16186f02-0000-1000-8000-00807f9b34fb")
    private let activityID = CBUUID(string: "16186f03-0000-1000-8000-00807f9b34fb")

    private var manager: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var characteristics: [CBUUID: CBCharacteristic] = [:]
    private var pendingNotifications = Set<CBUUID>()
    private var connectWaiter: CheckedContinuation<Void, Error>?
    private var ackWaiter: CheckedContinuation<Void, Error>?
    private var ackExpected = -1
    private var messageWaiter: CheckedContinuation<Data, Error>?
    private var messages: [Data] = []
    private var transfers: [CBUUID: (Int, [Int: Data])] = [:]
    private var generation = 0
    private var ackTicket = 0
    private var messageTicket = 0

    override init() {
        super.init()
        manager = CBCentralManager(delegate: self, queue: .main)
    }

    func connect() async throws {
        try await withCheckedThrowingContinuation { continuation in
            connectWaiter = continuation
            if manager.state == .poweredOn { startScan() }
            else if manager.state != .unknown && manager.state != .resetting {
                failConnection(BandError.bluetoothUnavailable)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
                guard let self, self.connectWaiter != nil else { return }
                self.failConnection(BandError.notFound)
            }
        }
    }

    func disconnect() {
        if let peripheral { manager.cancelPeripheralConnection(peripheral) }
        peripheral = nil
        characteristics.removeAll()
        pendingNotifications.removeAll()
        transfers.removeAll()
        messages.removeAll()
        generation += 1
        failPending(BandError.disconnected)
    }

    private func startScan() {
        guard connectWaiter != nil else { return }
        manager.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    private func failConnection(_ error: Error) {
        manager.stopScan()
        connectWaiter?.resume(throwing: error)
        connectWaiter = nil
    }

    private func failPending(_ error: Error) {
        connectWaiter?.resume(throwing: error)
        connectWaiter = nil
        ackWaiter?.resume(throwing: error)
        ackWaiter = nil
        messageWaiter?.resume(throwing: error)
        messageWaiter = nil
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn { startScan() }
        else if central.state != .unknown && central.state != .resetting {
            failConnection(BandError.bluetoothUnavailable)
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover device: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? device.name ?? ""
        guard name.hasPrefix("Noise_REP_") else { return }
        manager.stopScan()
        peripheral = device
        device.delegate = self
        manager.connect(device)
    }

    func centralManager(_ central: CBCentralManager, didConnect device: CBPeripheral) {
        device.discoverServices([serviceID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect device: CBPeripheral, error: Error?) {
        failConnection(error ?? BandError.disconnected)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral device: CBPeripheral, error: Error?) {
        peripheral = nil
        failPending(error ?? BandError.disconnected)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error { failConnection(error); return }
        guard let service = peripheral.services?.first(where: { $0.uuid == serviceID }) else {
            failConnection(BandError.missingCharacteristics); return
        }
        peripheral.discoverCharacteristics([readID, writeID, activityID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error { failConnection(error); return }
        for characteristic in service.characteristics ?? [] { characteristics[characteristic.uuid] = characteristic }
        guard characteristics[readID] != nil, characteristics[writeID] != nil,
              characteristics[activityID] != nil else {
            failConnection(BandError.missingCharacteristics); return
        }
        pendingNotifications = [readID, writeID, activityID]
        for id in pendingNotifications {
            if let characteristic = characteristics[id] { peripheral.setNotifyValue(true, for: characteristic) }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error { failConnection(error); return }
        guard characteristic.isNotifying else { failConnection(BandError.missingCharacteristics); return }
        pendingNotifications.remove(characteristic.uuid)
        if pendingNotifications.isEmpty {
            connectWaiter?.resume()
            connectWaiter = nil
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let data = characteristic.value, data.count >= 3 else { return }
        let index = Int(data[0]) | (Int(data[1]) << 8)
        if index == 0 {
            let kind = data[2]
            if kind == 0, data.count >= 6 {
                let count = Int(data[4]) | (Int(data[5]) << 8)
                transfers[characteristic.uuid] = (count, [:])
                peripheral.writeValue(Data([0, 0, 1, 1]), for: characteristic, type: .withoutResponse)
            } else if kind == 1, data.count >= 4 {
                let status = Int(data[3])
                if status == 2 {
                    ackWaiter?.resume(throwing: BandError.rejected)
                    ackWaiter = nil
                } else if status == ackExpected {
                    ackWaiter?.resume()
                    ackWaiter = nil
                }
            }
            return
        }
        guard var transfer = transfers[characteristic.uuid] else { return }
        transfer.1[index] = data.subdata(in: 2..<data.count)
        transfers[characteristic.uuid] = transfer
        if transfer.0 > 0 && transfer.1.count >= transfer.0 {
            let payload = (1...transfer.0).compactMap { transfer.1[$0] }.reduce(Data(), +)
            transfers.removeValue(forKey: characteristic.uuid)
            peripheral.writeValue(Data([0, 0, 1, 0]), for: characteristic, type: .withoutResponse)
            if let waiter = messageWaiter {
                messageWaiter = nil
                waiter.resume(returning: payload)
            } else {
                messages.append(payload)
            }
        }
    }

    private func performAndWaitForAck(_ expected: Int, timeout: TimeInterval = 6,
                                      action: () -> Void) async throws {
        try await withCheckedThrowingContinuation { continuation in
            ackExpected = expected
            ackWaiter = continuation
            ackTicket += 1
            let ticket = ackTicket
            action()
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self, self.ackTicket == ticket, self.ackWaiter != nil,
                      self.ackExpected == expected else { return }
                self.ackWaiter?.resume(throwing: BandError.timeout)
                self.ackWaiter = nil
            }
        }
    }

    func send(_ payload: Data) async throws {
        guard let peripheral, let write = characteristics[writeID] else { throw BandError.disconnected }
        let chunkSize = max(1, min(242, peripheral.maximumWriteValueLength(for: .withoutResponse) - 2))
        let count = max(1, (payload.count + chunkSize - 1) / chunkSize)
        guard count < 65536 else { throw WireError.malformed }
        let start = Data([0, 0, 0, 0, UInt8(count & 255), UInt8(count >> 8)])
        try await performAndWaitForAck(1) {
            peripheral.writeValue(start, for: write, type: .withoutResponse)
        }
        try await performAndWaitForAck(0) {
            for i in 0..<count {
                let low = UInt8((i + 1) & 255)
                let high = UInt8((i + 1) >> 8)
                let begin = i * chunkSize
                let end = min(begin + chunkSize, payload.count)
                peripheral.writeValue(Data([low, high]) + payload.subdata(in: begin..<end), for: write, type: .withoutResponse)
            }
        }
    }

    func receive(timeout: TimeInterval = 6) async throws -> Data {
        if !messages.isEmpty { return messages.removeFirst() }
        return try await withCheckedThrowingContinuation { continuation in
            messageWaiter = continuation
            messageTicket += 1
            let ticket = messageTicket
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self, self.messageTicket == ticket, self.messageWaiter != nil else { return }
                self.messageWaiter?.resume(throwing: BandError.timeout)
                self.messageWaiter = nil
            }
        }
    }
}
