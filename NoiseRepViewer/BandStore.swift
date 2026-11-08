import Combine
import Foundation

@MainActor
final class BandStore: ObservableObject {
    @Published var snapshot = Snapshot()
    @Published var isSyncing = false
    @Published var progress = "Ready to connect"
    @Published var errorMessage: String?

    private var link: BandConnection?
    private var fileParts: [String: (Data, Bool)] = [:]

    func sync() async {
        guard !isSyncing else { return }
        isSyncing = true
        errorMessage = nil
        snapshot = Snapshot()
        fileParts.removeAll()
        let connection = BandConnection()
        link = connection
        defer {
            connection.disconnect()
            link = nil
            isSyncing = false
        }
        do {
            progress = "Finding Noise REP…"
            try await connection.connect()
            progress = "Reading device information…"
            if let response = try await ask(Commands.deviceInfo(), type: 32) {
                snapshot.device = Decoder.device(response)
            }
            progress = "Finding available data…"
            let index = try await ask(Commands.index(), type: 112).map(Decoder.index) ?? []
            let earliest = index.min() ?? Calendar.current.date(from: DateComponents(year: 2000, month: 1, day: 1))!
            snapshot.clockMayBeUnset = index.contains { Calendar.current.component(.year, from: $0) < 2020 }

            for (position, metric) in Commands.metricIDs.enumerated() {
                progress = "Reading history \(position + 1) of \(Commands.metricIDs.count)…"
                for type in [113, 115] {
                    if let response = try await ask(Commands.series(type, earliest, metric), type: type),
                       let series = Decoder.series(response),
                       (!series.values.isEmpty || !series.totals.isEmpty) {
                        snapshot.series.append(series)
                    }
                }
            }
            progress = "Receiving RRI files…"
            _ = try await ask(Commands.control123(), type: 123)
            _ = try await ask(Commands.control117(), type: 117)
            let end = Date().addingTimeInterval(18)
            while Date() < end {
                do {
                    let response = try await connection.receive(timeout: 4)
                    acceptFile(response)
                } catch BandError.timeout {
                    break
                }
            }
            progress = "Sync complete"
        } catch {
            errorMessage = error.localizedDescription
            progress = "Sync stopped"
        }
    }

    private func ask(_ command: Data, type: Int) async throws -> Data? {
        guard let link else { throw BandError.disconnected }
        try await link.send(command)
        for _ in 0..<8 {
            let response: Data
            do { response = try await link.receive(timeout: 6) }
            catch BandError.timeout { return nil }
            let responseType = Wire.int(response, 1)
            if responseType == 4097 { acceptFile(response); continue }
            if responseType == type { return response }
        }
        return nil
    }

    private func acceptFile(_ response: Data) {
        guard Wire.int(response, 1) == 4097,
              let (name, bytes, flag) = Decoder.fileChunk(response),
              name.contains("RRI_Data") else { return }
        switch flag {
        case 0:
            fileParts[name] = (bytes, true)
        case 1:
            if var part = fileParts[name], part.1 {
                part.0.append(bytes)
                fileParts[name] = part
            }
        case 2:
            if var part = fileParts[name], part.1 {
                part.0.append(bytes)
                // The observed REP file is a headerless array of little-endian slots.
                if part.0.count >= 2, part.0.count % 2 == 0 {
                    let file = RRIFile(name: name, end: Decoder.fileEnd(name), data: part.0)
                    snapshot.rriFiles.append(file)
                }
            }
            fileParts.removeValue(forKey: name)
        default:
            fileParts.removeValue(forKey: name)
        }
    }
}
