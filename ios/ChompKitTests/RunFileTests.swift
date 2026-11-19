import Foundation
import Testing
@testable import ChompKit

@Suite("Run files")
struct RunFileTests {
    static let t0 = Date(timeIntervalSince1970: 1_795_000_000)
    static func iso(_ d: Date) -> String { ISO8601DateFormatter().string(from: d) }

    @Test func readsStravaStyleGPX() throws {
        var pts = ""
        for i in 0..<20 {
            pts += #"<trkpt lat="\#(51.34 + Double(i) * 0.0001)" lon="-0.51"><ele>30.5</ele><time>\#(Self.iso(Self.t0.addingTimeInterval(Double(i) * 5)))</time></trkpt>"#
        }
        let gpx = #"<?xml version="1.0"?><gpx creator="StravaGPX" xmlns="http://www.topografix.com/GPX/1/1"><trk><name>Morning Run</name><type>running</type><trkseg>\#(pts)</trkseg></trk></gpx>"#
        let r = try RunFile.parse(Data(gpx.utf8), fileName: "Morning_Run.gpx")
        #expect(r.format == .gpx && r.points.count == 20 && r.sport == "running")
        #expect(r.start == Self.t0 && r.end == Self.t0.addingTimeInterval(95))
        #expect(abs(r.points[19].coordinate.latitude - 51.3419) < 1e-9 && r.points[0].altitude == 30.5)
    }

    @Test func readsGPXWithFractionalSecondsAndNamespaces() throws {
        let gpx = #"<gpx:gpx xmlns:gpx="http://www.topografix.com/GPX/1/1"><gpx:trk><gpx:trkseg><gpx:trkpt lat="51.5" lon="-0.1"><gpx:time>2026-11-18T07:00:00.250Z</gpx:time></gpx:trkpt></gpx:trkseg></gpx:trk></gpx:gpx>"#
        let r = try RunFile.parse(Data(gpx.utf8))
        #expect(r.points.count == 1 && r.points[0].timestamp.timeIntervalSince1970.truncatingRemainder(dividingBy: 1) == 0.25)
    }

    @Test func readsGarminTCX() throws {
        var pts = ""
        for i in 0..<12 {
            pts += "<Trackpoint><Time>\(Self.iso(Self.t0.addingTimeInterval(Double(i))))</Time><Position><LatitudeDegrees>51.3\(i)</LatitudeDegrees><LongitudeDegrees>-0.5</LongitudeDegrees></Position><AltitudeMeters>12</AltitudeMeters></Trackpoint>"
        }
        pts += "<Trackpoint><Time>\(Self.iso(Self.t0.addingTimeInterval(20)))</Time><HeartRateBpm><Value>150</Value></HeartRateBpm></Trackpoint>"  // no position: skipped
        let tcx = #"<?xml version="1.0"?><TrainingCenterDatabase xmlns="http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2"><Activities><Activity Sport="Running"><Lap><Track>\#(pts)</Track></Lap></Activity></Activities></TrainingCenterDatabase>"#
        let r = try RunFile.parse(Data(tcx.utf8))
        #expect(r.format == .tcx && r.points.count == 12 && r.sport == "running" && r.points[3].altitude == 12)
    }

    @Test func refusesRidesRoutesAndJunk() {
        let ride = #"<gpx><trk><type>cycling</type><trkseg><trkpt lat="51" lon="0.1"><time>2026-11-18T07:00:00Z</time></trkpt></trkseg></trk></gpx>"#
        #expect(throws: RunFile.ParseError.notOnFoot("cycling")) { try RunFile.parse(Data(ride.utf8)) }
        let tcxRide = #"<TrainingCenterDatabase><Activities><Activity Sport="Biking"><Lap><Track><Trackpoint><Time>2026-11-18T07:00:00Z</Time><Position><LatitudeDegrees>51</LatitudeDegrees><LongitudeDegrees>0.1</LongitudeDegrees></Position></Trackpoint></Track></Lap></Activity></Activities></TrainingCenterDatabase>"#
        #expect(throws: RunFile.ParseError.notOnFoot("cycling")) { try RunFile.parse(Data(tcxRide.utf8)) }
        let course = #"<gpx><trk><trkseg><trkpt lat="51" lon="0.1"/><trkpt lat="51.001" lon="0.1"/></trkseg></trk></gpx>"#
        #expect(throws: RunFile.ParseError.noTimes) { try RunFile.parse(Data(course.utf8)) }
        #expect(throws: RunFile.ParseError.noPoints) { try RunFile.parse(Data("<gpx></gpx>".utf8)) }
        #expect(throws: RunFile.ParseError.unknownFormat) { try RunFile.parse(Data("PK\u{3}\u{4}zipzip".utf8), fileName: "run.zip") }
    }

    @Test func readsFIT() throws {
        let fit = FITBuilder.run(start: 1_100_000_000, points: 15)
        let r = try RunFile.parse(fit, fileName: "123.fit")
        #expect(r.format == .fit && r.sport == "running" && r.points.count == 15)
        #expect(r.start == Date(timeIntervalSince1970: FITDecoder.epoch + 1_100_000_000))
        #expect(abs(r.points[0].coordinate.latitude - 51.34) < 1e-6 && abs(r.points[0].coordinate.longitude + 0.51) < 1e-6)
        #expect(abs(r.points[0].altitude - 30) < 0.01 && abs(r.points[0].speed - 3.2) < 0.001)
        // Compressed-timestamp records follow on from the last full timestamp.
        #expect(r.end.timeIntervalSince(r.start) == 14 * 2)
    }

    @Test func refusesFITRides() {
        #expect(throws: RunFile.ParseError.notOnFoot("cycling")) { try RunFile.parse(FITBuilder.run(start: 1_100_000_000, points: 3, sport: 2)) }
    }
}

/// Writes a minimal but valid FIT activity: a sport message, then records with
/// full timestamps, then some with compressed timestamp headers.
enum FITBuilder {
    static func run(start: UInt32, points: Int, sport: UInt8 = 1) -> Data {
        var body: [UInt8] = []
        func le32(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24)] }
        func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }
        // Definition, local 1: sport (12): field 0 sport (1 byte, enum).
        body += [0x41, 0, 0]; body += le16(12); body += [1, 0, 1, 0x00]
        body += [0x01, sport]
        // Definition, local 0: record (20): 253 timestamp u32, 0 lat s32, 1 lon s32, 2 altitude u16, 6 speed u16.
        body += [0x40, 0, 0]; body += le16(20); body += [5, 253, 4, 0x86, 0, 4, 0x85, 1, 4, 0x85, 2, 2, 0x84, 6, 2, 0x84]
        // Definition, local 2: record without timestamp, for compressed headers.
        body += [0x42, 0, 0]; body += le16(20); body += [4, 0, 4, 0x85, 1, 4, 0x85, 2, 2, 0x84, 6, 2, 0x84]
        let lat = UInt32(bitPattern: Int32((51.34 / 180) * 2_147_483_648)), lon = UInt32(bitPattern: Int32((-0.51 / 180) * 2_147_483_648))
        let alt = le16(UInt16((30 + 500) * 5)), speed = le16(3200)
        for i in 0..<points {
            let t = start + UInt32(i * 2)
            if i % 2 == 0 {
                body.append(0x00)
                body.append(contentsOf: le32(t))
            } else {
                let compressed: UInt8 = 0x80 | (2 << 5) | UInt8(t & 0x1F)
                body.append(compressed)
            }
            body.append(contentsOf: le32(lat))
            body.append(contentsOf: le32(lon))
            body.append(contentsOf: alt)
            body.append(contentsOf: speed)
        }
        var header: [UInt8] = [12, 0x10]
        header.append(contentsOf: le16(2132))
        header.append(contentsOf: le32(UInt32(body.count)))
        header.append(contentsOf: Array(".FIT".utf8))
        return Data(header + body + [0, 0])  // CRC isn't checked
    }
}

@Suite("Imported runs and anti-cheat")
struct ImportedAntiCheatTests {
    /// A Garmin-style trace: one point a second, and the same made-up accuracy on
    /// every point because GPX files don't record it.
    static func garminTrace() -> [TracePoint] {
        (0..<600).map { i in
            TracePoint(coordinate: Coordinate(latitude: 51.34 + Double(i) * 0.000027, longitude: -0.51 + sin(Double(i) / 40) * 0.0002),
                       timestamp: Date(timeIntervalSince1970: 1_795_000_000 + Double(i)), horizontalAccuracy: 10, speed: -1)
        }
    }

    @Test func liveRunsWithFakeLookingGPSAreStillFlagged() {
        let r = AntiCheat.evaluate(trace: Self.garminTrace(), signals: RunSignals(), rules: RulesConfig.bundled.antiCheat,
                                   matching: RulesConfig.bundled.matching)
        #expect(r.flags.contains { $0.rule == "synthetic" })
    }

    @Test func importedRunsSkipTheAccuracyCheck() {
        let r = AntiCheat.evaluate(trace: Self.garminTrace(), signals: RunSignals(), rules: RulesConfig.bundled.antiCheat,
                                   matching: RulesConfig.bundled.matching, imported: true)
        #expect(!r.flags.contains { $0.rule == "synthetic" })
        #expect(r.verdict == .accepted)
    }
}
