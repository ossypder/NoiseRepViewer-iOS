import Foundation

enum WireError: Error {
    case malformed
}

enum Wire {
    static func varint(_ value: Int) -> Data {
        var value = UInt64(value)
        var output = Data()
        while value >= 0x80 {
            output.append(UInt8(value & 0x7f) | 0x80)
            value >>= 7
        }
        output.append(UInt8(value))
        return output
    }

    static func field(_ number: Int, _ value: Int) -> Data {
        var result = varint(number << 3)
        result.append(varint(value))
        return result
    }

    static func field(_ number: Int, _ value: Data) -> Data {
        var result = varint((number << 3) | 2)
        result.append(varint(value.count))
        result.append(value)
        return result
    }

    static func readVarint(_ bytes: Data, _ offset: inout Int) throws -> Int {
        var value: UInt64 = 0
        var shift = 0
        while offset < bytes.count && shift < 64 {
            let byte = bytes[offset]
            offset += 1
            value |= UInt64(byte & 0x7f) << shift
            if byte & 0x80 == 0 { return Int(truncatingIfNeeded: value) }
            shift += 7
        }
        throw WireError.malformed
    }

    static func fields(_ bytes: Data) throws -> [(Int, Int, Data)] {
        var result: [(Int, Int, Data)] = []
        var offset = 0
        while offset < bytes.count {
            let tag = try readVarint(bytes, &offset)
            let number = tag >> 3
            let kind = tag & 7
            guard number > 0 else { throw WireError.malformed }
            if kind == 0 {
                let start = offset
                _ = try readVarint(bytes, &offset)
                result.append((number, kind, bytes.subdata(in: start..<offset)))
            } else if kind == 2 {
                let count = try readVarint(bytes, &offset)
                guard count >= 0, count <= bytes.count - offset else { throw WireError.malformed }
                result.append((number, kind, bytes.subdata(in: offset..<(offset + count))))
                offset += count
            } else {
                throw WireError.malformed
            }
        }
        return result
    }

    static func bytes(_ data: Data, _ number: Int) -> Data? {
        guard let match = try? fields(data).first(where: { $0.0 == number && $0.1 == 2 }) else { return nil }
        return match.2
    }

    static func allBytes(_ data: Data, _ number: Int) -> [Data] {
        guard let parsed = try? fields(data) else { return [] }
        return parsed.filter { $0.0 == number && $0.1 == 2 }.map { $0.2 }
    }

    static func int(_ data: Data, _ number: Int) -> Int? {
        guard let match = try? fields(data).first(where: { $0.0 == number && $0.1 == 0 }) else { return nil }
        var offset = 0
        return try? readVarint(match.2, &offset)
    }
}

enum Commands {
    static let metricIDs = [2, 4, 8, 14, 18, 19, 17, 0, 21, 22, 23, 26, 27, 25, 11, 12]

    static func deviceInfo() -> Data { Wire.field(1, 32) }
    static func index() -> Data { Wire.field(1, 112) + Wire.field(9, Wire.field(29, 3)) }
    static func control123() -> Data { Wire.field(1, 123) + Wire.field(9, Wire.field(28, 1)) }
    static func control117() -> Data { Wire.field(1, 117) }

    static func series(_ type: Int, _ date: Date, _ metric: Int) -> Data {
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let stamp = Wire.field(1, parts.year ?? 2000)
            + Wire.field(2, parts.month ?? 1)
            + Wire.field(3, parts.day ?? 1)
            + Wire.field(4, parts.hour ?? 0)
            + Wire.field(5, parts.minute ?? 0)
            + Wire.field(6, parts.second ?? 0)
        let entry = Wire.field(1, stamp) + Wire.field(2, metric)
        return Wire.field(1, type) + Wire.field(9, Wire.field(1, entry))
    }
}

struct DeviceInfo {
    let firmware: String
    let model: String
}

struct MetricSeries: Identifiable {
    var id: String { "\(metric)-\(day.timeIntervalSince1970)" }
    let metric: Int
    let day: Date
    let values: [Int]
    let totals: [String: Int]
}

struct RRIFile {
    let name: String
    let end: Date?
    let data: Data

    var validIntervals: [Int] {
        stride(from: 0, to: data.count - data.count % 2, by: 2).compactMap { i in
            let value = Int(data[i]) | (Int(data[i + 1]) << 8)
            return (250...3000).contains(value) ? value : nil
        }
    }

    var averageBPM: Int? {
        let intervals = validIntervals
        guard !intervals.isEmpty else { return nil }
        return Int((60_000.0 / (Double(intervals.reduce(0, +)) / Double(intervals.count))).rounded())
    }

    var possibleRest: (start: Date, end: Date, minutes: Int, beats: Int)? {
        guard let end else { return nil }
        let slotCount = data.count / 2
        let windowStart = end.addingTimeInterval(-Double(slotCount))
        var groupStart: Int?
        var lastIndex: Int?
        var beats = 0
        var best: (Int, Int, Int)?
        func consider() {
            if let first = groupStart, let last = lastIndex, last - first >= 1800,
               best == nil || last - first > best!.1 - best!.0 {
                best = (first, last, beats)
            }
        }
        for index in 0..<slotCount {
            let value = Int(data[index * 2]) | (Int(data[index * 2 + 1]) << 8)
            guard (250...3000).contains(value) else { continue }
            if let last = lastIndex, index - last > 1800 {
                consider()
                groupStart = index
                beats = 0
            }
            if groupStart == nil { groupStart = index }
            lastIndex = index
            beats += 1
        }
        consider()
        guard let best else { return nil }
        return (windowStart.addingTimeInterval(Double(best.0)),
                windowStart.addingTimeInterval(Double(best.1)),
                (best.1 - best.0) / 60, best.2)
    }
}

struct Snapshot {
    var device: DeviceInfo?
    var series: [MetricSeries] = []
    var rriFiles: [RRIFile] = []
    var clockMayBeUnset = false

    func latest(_ metric: Int) -> MetricSeries? {
        series.filter { $0.metric == metric && !$0.values.isEmpty }
            .max { $0.day < $1.day }
    }

    func latestValue(_ metric: Int) -> Int? {
        latest(metric)?.values.last(where: { $0 > 0 })
    }

    var activity: MetricSeries? {
        series.filter { $0.metric == 0 && !$0.totals.isEmpty }.max { $0.day < $1.day }
    }
}

enum Decoder {
    static func date(_ data: Data) -> Date? {
        guard let year = Wire.int(data, 1), let month = Wire.int(data, 2), let day = Wire.int(data, 3) else { return nil }
        var parts = DateComponents()
        parts.calendar = Calendar.current
        parts.year = year
        parts.month = month
        parts.day = day
        parts.hour = Wire.int(data, 4) ?? 0
        parts.minute = Wire.int(data, 5) ?? 0
        parts.second = Wire.int(data, 6) ?? 0
        return parts.date
    }

    static func device(_ payload: Data) -> DeviceInfo? {
        guard let outer = Wire.bytes(payload, 4), let info = Wire.bytes(outer, 1) else { return nil }
        return DeviceInfo(
            firmware: Wire.bytes(info, 1).flatMap { String(data: $0, encoding: .utf8) } ?? "Unknown",
            model: Wire.bytes(info, 4).flatMap { String(data: $0, encoding: .utf8) } ?? "Noise REP"
        )
    }

    static func index(_ payload: Data) -> [Date] {
        guard let outer = Wire.bytes(payload, 9), let container = Wire.bytes(outer, 2) else { return [] }
        return Wire.allBytes(container, 1).compactMap { entry in
            Wire.bytes(entry, 1).flatMap(date)
        }
    }

    static func series(_ payload: Data) -> MetricSeries? {
        guard let container = Wire.bytes(payload, 9), let fields = try? Wire.fields(container) else { return nil }
        for (_, kind, body) in fields where kind == 2 {
            guard let entry = Wire.bytes(body, 1),
                  let stamp = Wire.bytes(entry, 1),
                  let day = date(stamp),
                  let metric = Wire.int(entry, 2) else { continue }
            let values = Wire.bytes(body, 3).map { Array($0).map(Int.init) } ?? []
            var totals: [String: Int] = [:]
            if metric == 0 {
                for (name, number, scalar) in [("steps", 3, 9), ("distance", 5, 0), ("calories", 7, 10), ("activeMinutes", 15, 13)] {
                    if let raw = Wire.bytes(body, number), raw.count >= 2 {
                        let hourly = stride(from: 0, to: min(raw.count - 1, 47), by: 2).map { Int(raw[$0]) << 8 | Int(raw[$0 + 1]) }
                        totals[name] = scalar == 0 ? hourly.reduce(0, +) : (Wire.int(body, scalar) ?? hourly.reduce(0, +))
                    }
                }
            }
            return MetricSeries(metric: metric, day: day, values: values, totals: totals)
        }
        return nil
    }

    static func fileChunk(_ payload: Data) -> (String, Data, Int)? {
        guard let outer = Wire.bytes(payload, 16), let body = Wire.bytes(outer, 1),
              let nameData = Wire.bytes(body, 1),
              let name = String(data: nameData, encoding: .utf8),
              let bytes = Wire.bytes(body, 2) else { return nil }
        return (name, bytes, Wire.int(body, 3) ?? 0)
    }

    static func fileEnd(_ name: String) -> Date? {
        guard let prefix = name.split(separator: "_").first else { return nil }
        let parts = prefix.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 4 else { return nil }
        let hhmm = parts[3]
        var date = DateComponents()
        date.calendar = Calendar.current
        date.year = parts[0]
        date.month = parts[1]
        date.day = parts[2]
        date.hour = hhmm / 100
        date.minute = hhmm % 100
        return date.date
    }
}
