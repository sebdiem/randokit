import Charts
import RandoKit
import SwiftUI

struct ElevationProfileView: View {
    let name: String?
    /// Full resolution — all measurements come from here.
    let linearized: LinearizedTrace
    /// Reduced point set for chart marks only.
    let displayProfile: [ProfilePoint]
    @Binding var selectedKmRange: ClosedRange<Double>?
    var currentKm: Double?
    var positionIsOnTrack = false

    private var elevationDomain: ClosedRange<Double> {
        let elevations = displayProfile.map(\.elevation)
        guard let min = elevations.min(), let max = elevations.max() else {
            return 0...1000
        }
        // Flat traces get a small window centered on their elevation instead
        // of a domain that would clip them out of view entirely.
        guard max - min >= 10 else {
            return (min - 25)...(max + 25)
        }
        let margin = (max - min) * 0.12
        return (min - margin)...(max + margin)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header

            Chart {
                ForEach(Array(displayProfile.enumerated()), id: \.offset) { _, point in
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

                // "You are here" marker; gray when the position is off the
                // trace and the projected abscissa is therefore approximate.
                if let currentKm {
                    RuleMark(x: .value("km", currentKm))
                        .foregroundStyle(positionIsOnTrack ? Color.blue : Color.gray.opacity(0.6))
                        .lineStyle(StrokeStyle(lineWidth: 2))
                }

                if let selection = selectedKmRange {
                    RectangleMark(
                        xStart: .value("km", selection.lowerBound),
                        xEnd: .value("km", selection.upperBound)
                    )
                    .foregroundStyle(.orange.opacity(0.16))

                    RuleMark(x: .value("km", selection.lowerBound))
                        .foregroundStyle(.orange)
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                    RuleMark(x: .value("km", selection.upperBound))
                        .foregroundStyle(.orange)
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                }
            }
            // chartXSelection(range:) has no built-in gesture on iOS, so the
            // range drag is explicit: horizontal drag anywhere on the plot.
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Rectangle()
                        .fill(.clear)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 8)
                                .onChanged { drag in
                                    guard let plotAnchor = proxy.plotFrame else { return }
                                    let plot = geometry[plotAnchor]
                                    let fromX = drag.startLocation.x - plot.origin.x
                                    let toX = drag.location.x - plot.origin.x
                                    guard let a: Double = proxy.value(atX: fromX),
                                        let b: Double = proxy.value(atX: toX)
                                    else { return }
                                    let maxKm = linearized.totalDistance / 1000
                                    let low = max(0, min(a, b))
                                    let high = min(maxKm, max(a, b))
                                    if high - low > 0.02 {
                                        selectedKmRange = low...high
                                    }
                                }
                        )
                }
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

    @ViewBuilder
    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let selection = selectedKmRange {
                Text("Sélection")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.orange)
                Spacer()
                Text(summary(for: selection))
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button {
                    selectedKmRange = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            } else {
                Text(name ?? "Trace")
                    .font(.footnote.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                Text(summary(for: nil))
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func summary(for kmRange: ClosedRange<Double>?) -> String {
        let km: Double
        let stats: ElevationStats
        if let kmRange {
            km = kmRange.upperBound - kmRange.lowerBound
            stats = linearized.elevationStats(
                in: (kmRange.lowerBound * 1000)...(kmRange.upperBound * 1000))
        } else {
            km = linearized.totalDistance / 1000
            stats = linearized.elevationStats()
        }
        let kmText = km.formatted(.number.precision(.fractionLength(1)))
        return "\(kmText) km  ↗ \(Int(stats.gain.rounded())) m  ↘ \(Int(stats.loss.rounded())) m"
    }
}
