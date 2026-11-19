import Foundation

/// Reads a run exported from another app: GPX (Strava, Garmin Connect and most
/// apps), TCX (Garmin Connect) or FIT (Garmin's own format, "Export Original").
/// Only the GPS points and their times are used.
public enum RunFile {
    public enum Format: String, Sendable { case gpx, tcx, fit }

    public struct Parsed: Sendable {
        public var format: Format
        public var points: [TracePoint]
        /// The sport the file says it is ("running", "cycling"...), lowercased, if any.
        public var sport: String?
        public var start: Date { points.first?.timestamp ?? .distantPast }
        public var end: Date { points.last?.timestamp ?? .distantPast }
    }

    public enum ParseError: LocalizedError, Equatable {
        case unknownFormat, noPoints, noTimes, notOnFoot(String)
        public var errorDescription: String? {
            switch self {
            case .unknownFormat: "Chomp can read GPX, TCX and FIT files. If you have a .zip, open it in the Files app first."
            case .noPoints: "That file has no GPS points, so there's no route to add."
            case .noTimes: "That file is a route without times (like a planned course), not a recorded run."
            case .notOnFoot(let s): "That file is a \(s) activity. Only runs and walks on foot collect coins."
            }
        }
    }

    public static func parse(_ data: Data, fileName: String = "") throws -> Parsed {
        let format = try detect(data, fileName: fileName)
        var parsed: Parsed
        switch format {
        case .gpx, .tcx: parsed = try XMLTrack.parse(data, format: format)
        case .fit: parsed = try FITDecoder.parse(data)
        }
        guard !parsed.points.isEmpty else { throw ParseError.noPoints }
        parsed.points.sort { $0.timestamp < $1.timestamp }
        if let s = parsed.sport, let label = offFootLabel(s) { throw ParseError.notOnFoot(label) }
        return parsed
    }

    static func detect(_ data: Data, fileName: String) throws -> Format {
        if data.count >= 12, data[8] == 0x2E, data[9] == 0x46, data[10] == 0x49, data[11] == 0x54 { return .fit }  // ".FIT"
        let head = String(decoding: data.prefix(2048), as: UTF8.self).lowercased()
        if head.contains("<gpx") { return .gpx }
        if head.contains("<trainingcenterdatabase") { return .tcx }
        switch (fileName as NSString).pathExtension.lowercased() {
        case "gpx": return .gpx
        case "tcx": return .tcx
        case "fit": return .fit
        default: throw ParseError.unknownFormat
        }
    }

    /// "cycling" etc. for sports that aren't on foot; nil for runs, walks, hikes and unknowns.
    static func offFootLabel(_ sport: String) -> String? {
        let s = sport.lowercased()
        let wheels = ["cycl", "bik", "ride", "ski", "swim", "row", "kayak", "paddl", "skat", "drive", "motor"]
        guard let hit = wheels.first(where: { s.contains($0) }) else { return nil }
        switch hit {
        case "cycl", "bik", "ride": return "cycling"
        case "swim": return "swimming"
        case "ski": return "skiing"
        default: return s
        }
    }
}

// MARK: GPX and TCX

private final class XMLTrack: NSObject, XMLParserDelegate {
    let format: RunFile.Format
    var points: [TracePoint] = []
    var sport: String?
    var missingTimes = 0

    private var lat: Double?, lon: Double?, ele: Double = 0, time: Date?
    private var inPoint = false
    private var text = ""

    init(format: RunFile.Format) { self.format = format }

    static func parse(_ data: Data, format: RunFile.Format) throws -> RunFile.Parsed {
        let t = XMLTrack(format: format)
        let p = XMLParser(data: data)
        p.delegate = t
        p.parse()
        if t.points.isEmpty && t.missingTimes > 0 { throw RunFile.ParseError.noTimes }
        return .init(format: format, points: t.points, sport: t.sport)
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        let n = local(name)
        text = ""
        switch (format, n) {
        case (.gpx, "trkpt"):
            inPoint = true; time = nil; ele = 0
            lat = attributes["lat"].flatMap(Double.init); lon = attributes["lon"].flatMap(Double.init)
        case (.tcx, "Trackpoint"):
            inPoint = true; time = nil; ele = 0; lat = nil; lon = nil
        case (.tcx, "Activity"):
            if sport == nil { sport = attributes["Sport"]?.lowercased() }
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let n = local(name)
        let v = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch (format, n) {
        case (.gpx, "time"), (.tcx, "Time"): if inPoint { time = ISODate.parse(v) }
        case (.gpx, "ele"), (.tcx, "AltitudeMeters"): if inPoint { ele = Double(v) ?? 0 }
        case (.tcx, "LatitudeDegrees"): if inPoint { lat = Double(v) }
        case (.tcx, "LongitudeDegrees"): if inPoint { lon = Double(v) }
        case (.gpx, "type"): if !inPoint, sport == nil, !v.isEmpty { sport = v.lowercased() }
        case (.gpx, "trkpt"), (.tcx, "Trackpoint"):
            inPoint = false
            guard let lat, let lon, abs(lat) <= 90, abs(lon) <= 180, !(lat == 0 && lon == 0) else { break }
            guard let time else { missingTimes += 1; break }
            points.append(TracePoint(coordinate: Coordinate(latitude: lat, longitude: lon), timestamp: time,
                                     horizontalAccuracy: 10, speed: -1, altitude: ele))
        default: break
        }
        text = ""
    }

    private func local(_ name: String) -> String { name.split(separator: ":").last.map(String.init) ?? name }
}

enum ISODate {
    // ISO8601DateFormatter is thread-safe.
    nonisolated(unsafe) private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()
    nonisolated(unsafe) private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    static func parse(_ s: String) -> Date? {
        if let d = plain.date(from: s) ?? fractional.date(from: s) { return d }
        // No time zone at all: treat as UTC, which is what GPX requires anyway.
        return s.hasSuffix("Z") ? nil : plain.date(from: s + "Z") ?? fractional.date(from: s + "Z")
    }
}

// MARK: FIT

/// Just enough of the FIT protocol to read GPS records (message 20) and the sport.
enum FITDecoder {
    /// FIT times count seconds from 31 Dec 1989 00:00 UTC.
    static let epoch: TimeInterval = 631_065_600

    private struct Field { let num: UInt8; let size: Int; let baseType: UInt8 }
    private struct Definition { let global: UInt16; let bigEndian: Bool; let fields: [Field]; let devBytes: Int }

    static func parse(_ data: Data) throws -> RunFile.Parsed {
        let b = [UInt8](data)
        guard b.count >= 12 else { throw RunFile.ParseError.unknownFormat }
        let headerSize = Int(b[0])
        let dataSize = Int(UInt32(b[4]) | UInt32(b[5]) << 8 | UInt32(b[6]) << 16 | UInt32(b[7]) << 24)
        let end = min(b.count, headerSize + dataSize)
        var i = headerSize
        var defs: [UInt8: Definition] = [:]
        var lastTime: UInt32 = 0
        var points: [TracePoint] = []
        var sport: String?

        func uint(_ at: Int, _ size: Int, big: Bool) -> UInt64 {
            var v: UInt64 = 0
            for k in 0..<size { v |= UInt64(b[at + (big ? size - 1 - k : k)]) << (8 * UInt64(k)) }
            return v
        }

        while i < end {
            let h = b[i]; i += 1
            if h & 0x80 != 0 {
                // Compressed timestamp header: a data message with a 5-bit time offset.
                let local = (h >> 5) & 0x03, offset = UInt32(h & 0x1F)
                guard let d = defs[local] else { throw RunFile.ParseError.unknownFormat }
                let low = lastTime & 0x1F
                lastTime = (lastTime & ~0x1F) + offset + (offset >= low ? 0 : 0x20)
                let rec = read(d, at: i, uint: uint)
                i += d.fields.reduce(0) { $0 + $1.size } + d.devBytes
                if d.global == 20, let p = point(rec, time: lastTime) { points.append(p) }
                continue
            }
            let local = h & 0x0F
            if h & 0x40 != 0 {
                // Definition message.
                guard i + 5 <= end else { break }
                let big = b[i + 1] == 1
                let global = UInt16(uint(i + 2, 2, big: big))
                let n = Int(b[i + 4]); i += 5
                var fields: [Field] = []
                for _ in 0..<n {
                    guard i + 3 <= end else { break }
                    fields.append(Field(num: b[i], size: Int(b[i + 1]), baseType: b[i + 2])); i += 3
                }
                var devBytes = 0
                if h & 0x20 != 0, i < end {
                    let nd = Int(b[i]); i += 1
                    for _ in 0..<nd where i + 3 <= end { devBytes += Int(b[i + 1]); i += 3 }
                }
                defs[local] = Definition(global: global, bigEndian: big, fields: fields, devBytes: devBytes)
                continue
            }
            guard let d = defs[local] else { throw RunFile.ParseError.unknownFormat }
            let size = d.fields.reduce(0) { $0 + $1.size } + d.devBytes
            guard i + size <= end else { break }
            let rec = read(d, at: i, uint: uint)
            i += size
            if let t = rec[253], t != 0xFFFF_FFFF { lastTime = UInt32(t) }
            switch d.global {
            case 20: if let p = point(rec, time: lastTime) { points.append(p) }
            case 12, 18: if sport == nil, let s = rec[d.global == 12 ? 0 : 5], s != 0xFF { sport = sportName(Int(s)) }
            default: break
            }
        }
        return .init(format: .fit, points: points, sport: sport)
    }

    /// Field number → raw unsigned value (fields of 1, 2 or 4 bytes only).
    private static func read(_ d: Definition, at start: Int, uint: (Int, Int, Bool) -> UInt64) -> [UInt8: UInt64] {
        var out: [UInt8: UInt64] = [:]
        var at = start
        for f in d.fields {
            if f.size == 1 || f.size == 2 || f.size == 4 { out[f.num] = uint(at, f.size, d.bigEndian) }
            at += f.size
        }
        return out
    }

    private static func point(_ rec: [UInt8: UInt64], time: UInt32) -> TracePoint? {
        guard let la = rec[0], let lo = rec[1], la != 0x7FFF_FFFF, lo != 0x7FFF_FFFF, time > 0 else { return nil }
        let deg = 180.0 / 2_147_483_648.0
        let lat = Double(Int32(bitPattern: UInt32(la))) * deg, lon = Double(Int32(bitPattern: UInt32(lo))) * deg
        guard abs(lat) <= 90, abs(lon) <= 180 else { return nil }
        var alt = 0.0
        if let a = rec[78], a != 0xFFFF_FFFF { alt = Double(a) / 5 - 500 }
        else if let a = rec[2], a != 0xFFFF { alt = Double(a) / 5 - 500 }
        var speed = -1.0
        if let s = rec[73], s != 0xFFFF_FFFF { speed = Double(s) / 1000 }
        else if let s = rec[6], s != 0xFFFF { speed = Double(s) / 1000 }
        return TracePoint(coordinate: Coordinate(latitude: lat, longitude: lon),
                          timestamp: Date(timeIntervalSince1970: epoch + Double(time)),
                          horizontalAccuracy: 10, speed: speed, altitude: alt)
    }

    private static func sportName(_ s: Int) -> String? {
        switch s {
        case 1: "running"; case 11: "walking"; case 17: "hiking"
        case 2: "cycling"; case 5: "swimming"; case 13: "skiing"; case 15: "rowing"
        default: nil
        }
    }
}
