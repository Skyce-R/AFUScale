import Foundation
import UIKit
import Combine

@MainActor
final class ConsoleRecorder: ObservableObject {
    @Published private(set) var events: [CaptureEvent] = []
    @Published private(set) var sessions: [URL] = []
    @Published private(set) var activeURL: URL?
    @Published private(set) var errorMessage: String?
    @Published private(set) var total = 0
    @Published private(set) var measurementRevision = 0
    var onWriteFailure: (() -> Void)?
    private var journal: CaptureJournal?
    private let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("AFU-Diagnostics", isDirectory: true)
    var isRecording: Bool { journal != nil }

    init() { refreshSessions() }

    func start(profile: [String: String]) {
        stop()
        do {
            var metadata = profile
            metadata["appVersion"] = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
            metadata["appBuild"] = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
            metadata["iOS"] = UIDevice.current.systemVersion
            metadata["deviceModel"] = UIDevice.current.model
            metadata["timezone"] = TimeZone.current.identifier
            metadata["scope"] = "This app's CoreBluetooth callbacks; not official AFU app traffic"
            metadata["scaleStoredProfile"] = "unknown"
            metadata["impedanceUnits"] = "unverified"
            let newJournal = try CaptureJournal(directory: directory, metadata: metadata)
            journal = newJournal
            activeURL = newJournal.url
            events = try CaptureJournal.read(newJournal.url).events
            total = events.count
            errorMessage = nil
            refreshSessions()
        } catch { report(error) }
    }

    func stop() {
        if journal != nil { log("session.stop") }
        journal = nil
    }

    @discardableResult
    func log(_ kind: String, _ fields: [String: String] = [:], date: Date = Date(), uptime: Double = ProcessInfo.processInfo.systemUptime) -> CaptureEvent? {
        guard let journal else { return nil }
        do {
            let event = try journal.append(kind, fields: fields, date: date, uptime: uptime)
            display(event)
            return event
        } catch {
            report(error)
            self.journal = nil
            return nil
        }
    }

    func annotate(url: URL, sequence: Int, fields: [String: String]) throws {
        let event: CaptureEvent
        if let journal, journal.url == url {
            event = try journal.annotate(measurementSequence: sequence, values: fields)
            display(event)
        } else {
            event = try CaptureJournal.annotate(url, measurementSequence: sequence, values: fields)
        }
        _ = event
    }

    func export(_ url: URL) throws -> [URL] {
        // Separate snapshot files prevent incoming BLE callbacks from changing a shared export.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("AFU-Export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let data = try Data(contentsOf: url)
        let raw = folder.appendingPathComponent(url.lastPathComponent)
        try data.write(to: raw, options: .atomic)
        let snapshot = try CaptureJournal.read(raw)
        let text = folder.appendingPathComponent(url.deletingPathExtension().lastPathComponent + "-summary.txt")
        try CaptureJournal.summary(snapshot).write(to: text, atomically: true, encoding: .utf8)
        return [raw, text]
    }

    private func display(_ event: CaptureEvent) {
        if event.kind == "measurement.final" || event.kind == "annotation" { measurementRevision += 1 }
        total = event.sequence
        events.append(event)
        if events.count > 300 { events.removeFirst(events.count - 300) }
    }
    private func refreshSessions() {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            sessions = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "jsonl" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
        } catch { report(error) }
    }
    private func report(_ error: Error) {
        errorMessage = "日志保存失败：\(error.localizedDescription)"
        onWriteFailure?()
    }
}
