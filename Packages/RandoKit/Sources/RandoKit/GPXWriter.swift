import Foundation

/// Serializes a trace back to GPX 1.1 — used to persist imported traces
/// (with corrected elevations) and, later, edited ones.
public struct GPXWriter {
    private let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    public init() {}

    public func write(_ trace: GPXTrace) -> String {
        var xml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <gpx version="1.1" creator="Rando" xmlns="http://www.topografix.com/GPX/1/1">

            """
        if let name = trace.name {
            xml += "  <metadata><name>\(escape(name))</name></metadata>\n"
        }
        for waypoint in trace.waypoints {
            xml += "  <wpt lat=\"\(format(waypoint.latitude))\" lon=\"\(format(waypoint.longitude))\">"
            if let elevation = waypoint.elevation {
                xml += "<ele>\(format(elevation))</ele>"
            }
            if let name = waypoint.name {
                xml += "<name>\(escape(name))</name>"
            }
            if let symbol = waypoint.symbol {
                xml += "<sym>\(escape(symbol))</sym>"
            }
            if let type = waypoint.type {
                xml += "<type>\(escape(type))</type>"
            }
            xml += "</wpt>\n"
        }
        xml += "  <trk>\n"
        if let name = trace.name {
            xml += "    <name>\(escape(name))</name>\n"
        }
        for range in trace.segmentRanges {
            xml += "    <trkseg>\n"
            for point in trace.points[range] {
                xml += "      <trkpt lat=\"\(format(point.latitude))\" lon=\"\(format(point.longitude))\">"
                if let elevation = point.elevation {
                    xml += "<ele>\(format(elevation))</ele>"
                }
                if let time = point.time {
                    xml += "<time>\(iso.string(from: time))</time>"
                }
                xml += "</trkpt>\n"
            }
            xml += "    </trkseg>\n"
        }
        xml += "  </trk>\n</gpx>\n"
        return xml
    }

    private func format(_ value: Double) -> String {
        String(format: "%.6f", value)
            .replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)
    }

    private func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
