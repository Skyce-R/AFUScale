import Foundation

/// Append-only schema: raw values are never replaced by decoded values or annotations.
struct CaptureEvent: Codable, Identifiable, Equatable {
    let schema: Int
    let session: String
    let sequence: Int
    let timestamp: String
    let uptime: Double
    let kind: String
    let fields: [String: String]
    var id: Int { sequence }
}

struct CaptureSnapshot {
    let events: [CaptureEvent]
    let damagedLines: Int
    var measurements: [CaptureEvent] { events.filter { $0.kind == "measurement.final" } }
    func annotation(for sequence: Int) -> [String: String] {
        events.last { $0.kind == "annotation" && $0.fields["measurementSequence"] == String(sequence) }?.fields ?? [:]
    }
}

enum CaptureError: LocalizedError {
    case corruptJournal, missingMeasurement, invalidAnnotation
    var errorDescription: String? {
        switch self {
        case .corruptJournal: return "日志包含不完整行；保留原文件并开始新会话。"
        case .missingMeasurement: return "找不到标注对应的最终测量包。"
        case .invalidAnnotation: return "体脂率须大于 0 且小于 100，体重须为正数。"
        }
    }
}

final class CaptureJournal {
    let url: URL
    let session: String
    private(set) var sequence: Int
    private let handle: FileHandle
    private let encoder: JSONEncoder

    init(directory: URL, metadata: [String: String]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        session = UUID().uuidString
        let stamp = Self.timestamp(Date()).replacingOccurrences(of: ":", with: "-")
        url = directory.appendingPathComponent("AFU-\(stamp)-\(session.prefix(8)).jsonl")
        sequence = 0
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        handle = try FileHandle(forWritingTo: url)
        _ = try append("session.start", fields: metadata)
    }

    private init(existing url: URL, snapshot: CaptureSnapshot) throws {
        guard snapshot.damagedLines == 0, let first = snapshot.events.first,
              snapshot.events.allSatisfy({ $0.session == first.session }),
              snapshot.events.map(\.sequence) == Array(1...snapshot.events.count) else {
            throw CaptureError.corruptJournal
        }
        self.url = url
        session = first.session
        sequence = snapshot.events.last?.sequence ?? 0
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        handle = try FileHandle(forWritingTo: url)
        _ = try handle.seekToEnd()
    }

    deinit { try? handle.close() }

    @discardableResult
    func append(_ kind: String, fields: [String: String] = [:], date: Date = Date(), uptime: Double = ProcessInfo.processInfo.systemUptime) throws -> CaptureEvent {
        let event = CaptureEvent(schema: 1, session: session, sequence: sequence + 1,
                                 timestamp: Self.timestamp(date), uptime: uptime, kind: kind, fields: fields)
        var data = try encoder.encode(event)
        data.append(0x0a)
        try handle.write(contentsOf: data)
        try handle.synchronize()
        sequence = event.sequence
        return event
    }

    static func read(_ url: URL) throws -> CaptureSnapshot {
        let data = try Data(contentsOf: url)
        var events: [CaptureEvent] = []
        var damaged = 0
        let decoder = JSONDecoder()
        for line in data.split(separator: 0x0a, omittingEmptySubsequences: true) {
            if let event = try? decoder.decode(CaptureEvent.self, from: Data(line)), event.schema == 1 {
                events.append(event)
            } else { damaged += 1 }
        }
        // A complete JSON object without its terminating newline may be a interrupted write.
        if !data.isEmpty && data.last != 0x0a { damaged = max(1, damaged) }
        return CaptureSnapshot(events: events, damagedLines: damaged)
    }

    @discardableResult
    static func annotate(_ url: URL, measurementSequence: Int, values: [String: String]) throws -> CaptureEvent {
        let snapshot = try read(url)
        guard snapshot.measurements.contains(where: { $0.sequence == measurementSequence }) else {
            throw CaptureError.missingMeasurement
        }
        for key in ["scaleFatPercent", "officialFatPercent", "officialWeightKg"] {
            if let text = values[key], !text.isEmpty {
                guard let value = Double(text), value.isFinite, value > 0,
                      (key == "officialWeightKg" || value < 100) else { throw CaptureError.invalidAnnotation }
            }
        }
        var fields = values
        fields["measurementSequence"] = String(measurementSequence)
        let journal = try CaptureJournal(existing: url, snapshot: snapshot)
        return try journal.append("annotation", fields: fields)
    }

    // Use this on the active instance to keep its sequence in sync after annotation.
    @discardableResult
    func annotate(measurementSequence: Int, values: [String: String]) throws -> CaptureEvent {
        let event = try Self.annotate(url, measurementSequence: measurementSequence, values: values)
        sequence = event.sequence
        _ = try handle.seekToEnd()
        return event
    }

    static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    static func summary(_ snapshot: CaptureSnapshot) -> String {
        var lines = ["AFUScale 蓝牙采集 · schema 1", "A/B 是原始候选字段，单位与含义尚未验证。标注是人工录入，并非设备返回值。",
                     "事件数：\(snapshot.events.count)；不完整行：\(snapshot.damagedLines)"]
        for event in snapshot.events {
            lines.append("\n#\(event.sequence) \(event.timestamp) [\(event.kind)] uptime=\(event.uptime)")
            for key in event.fields.keys.sorted() { lines.append("\(key): \(event.fields[key] ?? "")") }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
