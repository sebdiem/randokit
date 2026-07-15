import Charts
import RandoKit
import SwiftUI

struct ElevationProfileView: View {
    let name: String?
    let linearized: LinearizedTrace

    private var stats: ElevationStats {
        linearized.elevationStats()
    }

    private var elevationDomain: ClosedRange<Double> {
        let elevations = linearized.points.map(\.elevation)
        guard let min = elevations.min(), let max = elevations.max(), min < max else {
            return 0...1000
        }
        let margin = (max - min) * 0.12
        return (min - margin)...(max + margin)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(name ?? "Trace")
                    .font(.footnote.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                Text(summary)
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Chart(Array(linearized.points.enumerated()), id: \.offset) { _, point in
                AreaMark(
                    x: .value("km", point.distance / 1000),
                    yStart: .value("m", elevationDomain.lowerBound),
                    yEnd: .value("m", point.elevation)
                )
                .foregroundStyle(
                    .linearGradient(
                        colors: [.purple.opacity(0.35), .purple.opacity(0.05)],
                        startPoint: .top, endPoint: .bottom)
                )
                .interpolationMethod(.monotone)

                LineMark(
                    x: .value("km", point.distance / 1000),
                    y: .value("m", point.elevation)
                )
                .foregroundStyle(.purple)
                .lineStyle(StrokeStyle(lineWidth: 2))
                .interpolationMethod(.monotone)
            }
            .chartYScale(domain: elevationDomain)
            .chartXAxis {
                AxisMarks { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let km = value.as(Double.self) {
                            Text("\(km, format: .number.precision(.fractionLength(0...1))) km")
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .trailing) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let m = value.as(Double.self) {
                            Text("\(Int(m)) m")
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private var summary: String {
        let km = linearized.totalDistance / 1000
        let kmText = km.formatted(.number.precision(.fractionLength(1)))
        return "\(kmText) km  ↗ \(Int(stats.gain.rounded())) m  ↘ \(Int(stats.loss.rounded())) m"
    }
}
