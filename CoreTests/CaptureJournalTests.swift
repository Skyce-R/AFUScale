import XCTest
@testable import AFUScaleCore

final class CaptureJournalTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    func testUnknownPacketsSurviveRestartAndExportBeyondUIWindow() throws {
        var journal: CaptureJournal? = try CaptureJournal(directory: directory, metadata: ["sex": "female"])
        let url = journal!.url
        for n in 1...650 { try journal!.append("gatt.value.rx", fields: ["hex": "ff 00 \(n)", "characteristicUUID": "UNKNOWN"]) }
        let final = try journal!.append("measurement.final", fields: ["weightKg": "69.6", "candidateA": "482", "candidateB": "432"])
        journal = nil
        try CaptureJournal.annotate(url, measurementSequence: final.sequence, values: ["scaleFatPercent": "20.3", "notes": "中文备注\nsecond line"])
        let read = try CaptureJournal.read(url)
        XCTAssertEqual(read.events.count, 653)
        XCTAssertEqual(read.events.map(\.sequence), Array(1...653))
        XCTAssertEqual(read.events[1].fields["hex"], "ff 00 1")
        XCTAssertEqual(read.annotation(for: final.sequence)["scaleFatPercent"], "20.3")
        XCTAssertTrue(CaptureJournal.summary(read).contains("中文备注\nsecond line"))
        XCTAssertEqual(read.damagedLines, 0)
    }
    func testActiveJournalContinuesSequenceAfterAnnotationAndRetainsRevisions() throws {
        let journal = try CaptureJournal(directory: directory, metadata: [:])
        let m = try journal.append("measurement.final", fields: [:])
        try journal.annotate(measurementSequence: m.sequence, values: ["officialFatPercent": "18.2"])
        try journal.append("gatt.value.rx", fields: ["hex": "01 02"])
        try journal.annotate(measurementSequence: m.sequence, values: ["officialFatPercent": "19.2"])
        let read = try CaptureJournal.read(journal.url)
        XCTAssertEqual(read.events.map(\.sequence), Array(1...5))
        XCTAssertEqual(read.events.filter { $0.kind == "annotation" }.count, 2)
        XCTAssertEqual(read.annotation(for: m.sequence)["officialFatPercent"], "19.2")
    }
    func testAnnotationsCannotAttachToOtherEventOrOtherSession() throws {
        let a = try CaptureJournal(directory: directory, metadata: [:])
        let m = try a.append("measurement.final")
        let b = try CaptureJournal(directory: directory, metadata: [:])
        try b.append("gatt.value.rx")
        XCTAssertThrowsError(try CaptureJournal.annotate(b.url, measurementSequence: m.sequence, values: [:]))
        XCTAssertThrowsError(try CaptureJournal.annotate(a.url, measurementSequence: 1, values: [:]))
        for value in ["0", "100", "NaN", "-2", "Infinity", "abc"] {
            XCTAssertThrowsError(try a.annotate(measurementSequence: m.sequence, values: ["scaleFatPercent": value]))
        }
        XCTAssertEqual(try CaptureJournal.read(a.url).events.count, 2)
    }
    func testInterruptedJournalIsPreservedAndCannotAppendAnnotation() throws {
        let journal = try CaptureJournal(directory: directory, metadata: [:])
        let m = try journal.append("measurement.final")
        let handle = try FileHandle(forWritingTo: journal.url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"unfinished\"".utf8))
        try handle.close()
        let before = try Data(contentsOf: journal.url)
        let read = try CaptureJournal.read(journal.url)
        XCTAssertEqual(read.events.count, 2)
        XCTAssertEqual(read.damagedLines, 1)
        XCTAssertThrowsError(try CaptureJournal.annotate(journal.url, measurementSequence: m.sequence, values: [:]))
        XCTAssertEqual(try Data(contentsOf: journal.url), before)
    }
    func testFinalFixtureKeepsOriginalCandidatesAndPacket() throws {
        let data = Data([0xac,0x29,0x02,0x00,0x01,0xe2,0x01,0xb0,0x01,0x80,0x69,0x0f,0xe0,0,0,0,0,0x29,0xd6,0x0e])
        let m = try XCTUnwrap(ScalePacketParser.parse(data))
        XCTAssertEqual(m.weightKg, 69.6, accuracy: 0.001)
        XCTAssertEqual(m.impedance, Impedance(a: 482, b: 432))
        XCTAssertTrue(m.isFinal)
        XCTAssertNil(ScalePacketParser.parse(Data([0xff, 0xff])))
    }
    func testStorageFailuresAreThrown() throws {
        let file = directory.appendingPathComponent("not-a-directory")
        try Data([1]).write(to: file)
        XCTAssertThrowsError(try CaptureJournal(directory: file, metadata: [:]))
    }
}
