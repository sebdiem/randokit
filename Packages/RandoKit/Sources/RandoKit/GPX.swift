import Foundation

public struct TrackPoint: Equatable, Sendable {
    public var latitude: Double
    public var longitude: Double
    public var elevation: Double?
    public var time: Date?

    public init(latitude: Double, longitude: Double, elevation: Double? = nil, time: Date? = nil) {
        self.latitude = latitude
        self.longitude = longitude
        self.elevation = elevation
        self.time = time
    }
}

public struct Waypoint: Equatable, Sendable {
    public var latitude: Double
    public var longitude: Double
    public var name: String?
    public var elevation: Double?
    /// GPX `<sym>` — a symbol/category hint (e.g. "Campground", "Lodging").
    public var symbol: String?
    /// GPX `<type>` — a free-form classification string.
    public var type: String?

    public init(
        latitude: Double, longitude: Double, name: String? = nil, elevation: Double? = nil,
        symbol: String? = nil, type: String? = nil
    ) {
        self.latitude = latitude
        self.longitude = longitude
        self.name = name
        self.elevation = elevation
        self.symbol = symbol
        self.type = type
    }
}

public struct GPXTrace: Equatable, Sendable {
    public var name: String?
    /// All track points in file order, all segments concatenated.
    public var points: [TrackPoint]
    /// Index ranges into `points`, one per `<trkseg>`/`<rte>`. Consecutive
    /// segments are NOT connected: no line, distance, or projection may
    /// cross a boundary.
    public var segmentRanges: [Range<Int>]
    public var waypoints: [Waypoint]

    public init(
        name: String? = nil, points: [TrackPoint] = [],
        segmentRanges: [Range<Int>]? = nil, waypoints: [Waypoint] = []
    ) {
        self.name = name
        self.points = points
        self.segmentRanges = segmentRanges ?? (points.isEmpty ? [] : [0..<points.count])
        self.waypoints = waypoints
    }
}

public enum GPXError: Error, Equatable {
    case malformedXML(line: Int)
    case noTrack
}

/// Parses GPX 1.0/1.1 files. Track segments are flattened into a single point
/// sequence; `<rte>` routes (common on hiking sites) are treated like tracks.
public struct GPXParser {
    public init() {}

    public func parse(_ data: Data) throws -> GPXTrace {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            throw GPXError.malformedXML(line: parser.lineNumber)
        }
        guard delegate.points.count >= 2 else {
            throw GPXError.noTrack
        }
        // Fall back to a single segment if the file had points outside any
        // recognized container (defensive; not valid GPX).
        var ranges = delegate.segmentRanges
        if ranges.reduce(0, { $0 + $1.count }) != delegate.points.count {
            ranges = [0..<delegate.points.count]
        }
        return GPXTrace(
            name: delegate.traceName, points: delegate.points,
            segmentRanges: ranges, waypoints: delegate.waypoints)
    }

    public func parse(_ string: String) throws -> GPXTrace {
        try parse(Data(string.utf8))
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var traceName: String?
        var points: [TrackPoint] = []
        var segmentRanges: [Range<Int>] = []
        var waypoints: [Waypoint] = []

        private var segmentStart: Int?
        private var text = ""
        private var pending: (lat: Double, lon: Double)?
        private var pendingIsWaypoint = false
        private var pendingElevation: Double?
        private var pendingTime: Date?
        private var pendingName: String?
        private var pendingSymbol: String?
        private var pendingType: String?
        private var inTrackOrRoute = false
        private var inMetadata = false

        private let isoPlain = ISO8601DateFormatter()
        private let isoFractional: ISO8601DateFormatter = {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f
        }()

        func parser(
            _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
            qualifiedName: String?, attributes attributeDict: [String: String]
        ) {
            text = ""
            switch elementName {
            case "trk":
                inTrackOrRoute = true
            case "rte":
                inTrackOrRoute = true
                segmentStart = points.count
            case "trkseg":
                segmentStart = points.count
            case "metadata":
                inMetadata = true
            case "trkpt", "rtept", "wpt":
                guard let lat = attributeDict["lat"].flatMap(Double.init),
                      let lon = attributeDict["lon"].flatMap(Double.init)
                else { return }
                pending = (lat, lon)
                pendingIsWaypoint = elementName == "wpt"
                pendingElevation = nil
                pendingTime = nil
                pendingName = nil
                pendingSymbol = nil
                pendingType = nil
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            text += string
        }

        func parser(
            _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
            qualifiedName: String?
        ) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch elementName {
            case "ele":
                pendingElevation = Double(trimmed)
            case "time":
                if pending != nil {
                    pendingTime = isoFractional.date(from: trimmed) ?? isoPlain.date(from: trimmed)
                }
            case "name":
                if pending != nil {
                    pendingName = trimmed
                } else if (inTrackOrRoute || inMetadata) && traceName == nil {
                    traceName = trimmed.isEmpty ? nil : trimmed
                }
            case "sym":
                if pending != nil, pendingIsWaypoint, !trimmed.isEmpty {
                    pendingSymbol = trimmed
                }
            case "type":
                if pending != nil, pendingIsWaypoint, !trimmed.isEmpty {
                    pendingType = trimmed
                }
            case "trkpt", "rtept":
                if let p = pending, !pendingIsWaypoint {
                    points.append(
                        TrackPoint(latitude: p.lat, longitude: p.lon, elevation: pendingElevation, time: pendingTime))
                }
                pending = nil
            case "wpt":
                if let p = pending, pendingIsWaypoint {
                    waypoints.append(
                        Waypoint(
                            latitude: p.lat, longitude: p.lon, name: pendingName,
                            elevation: pendingElevation, symbol: pendingSymbol, type: pendingType))
                }
                pending = nil
            case "trkseg":
                closeSegment()
            case "trk":
                inTrackOrRoute = false
            case "rte":
                closeSegment()
                inTrackOrRoute = false
            case "metadata":
                inMetadata = false
            default:
                break
            }
            text = ""
        }

        private func closeSegment() {
            if let start = segmentStart, points.count > start {
                segmentRanges.append(start..<points.count)
            }
            segmentStart = nil
        }
    }
}
