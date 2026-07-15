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

    public init(latitude: Double, longitude: Double, name: String? = nil, elevation: Double? = nil) {
        self.latitude = latitude
        self.longitude = longitude
        self.name = name
        self.elevation = elevation
    }
}

public struct GPXTrace: Equatable, Sendable {
    public var name: String?
    public var points: [TrackPoint]
    public var waypoints: [Waypoint]

    public init(name: String? = nil, points: [TrackPoint] = [], waypoints: [Waypoint] = []) {
        self.name = name
        self.points = points
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
        guard !delegate.points.isEmpty else {
            throw GPXError.noTrack
        }
        return GPXTrace(name: delegate.traceName, points: delegate.points, waypoints: delegate.waypoints)
    }

    public func parse(_ string: String) throws -> GPXTrace {
        try parse(Data(string.utf8))
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var traceName: String?
        var points: [TrackPoint] = []
        var waypoints: [Waypoint] = []

        private var text = ""
        private var pending: (lat: Double, lon: Double)?
        private var pendingIsWaypoint = false
        private var pendingElevation: Double?
        private var pendingTime: Date?
        private var pendingName: String?
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
            case "trk", "rte":
                inTrackOrRoute = true
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
            case "trkpt", "rtept":
                if let p = pending, !pendingIsWaypoint {
                    points.append(
                        TrackPoint(latitude: p.lat, longitude: p.lon, elevation: pendingElevation, time: pendingTime))
                }
                pending = nil
            case "wpt":
                if let p = pending, pendingIsWaypoint {
                    waypoints.append(
                        Waypoint(latitude: p.lat, longitude: p.lon, name: pendingName, elevation: pendingElevation))
                }
                pending = nil
            case "trk", "rte":
                inTrackOrRoute = false
            case "metadata":
                inMetadata = false
            default:
                break
            }
            text = ""
        }
    }
}
