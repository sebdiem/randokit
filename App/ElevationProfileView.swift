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

    @State private var dragMode: DragMode?

    private enum DragMode {
        case newRange
        case adjustLower
        case adjustUpper
    }

    /// Touch tolerance around a selection edge that grabs the handle instead
    /// of starting a new selection.
    private static let handleGrabWidth: CGFloat = 24

    private var maxKm: Double { linearized.totalDistance / 1000 }

    private var elevationDomain: ClosedRange<Double> {
        let elevations = displayProfile.map(\.elevation)
        guard let min = elevations.min(), let max = elevations.max() else {
            return 0...1000
        }
        guard max - min >= 10 else {
            return (min - 25)...(max + 25)
        }
        let margin = (max - min) * 0.12
        return (min - margin)...(max + margin)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header

            // The chart exports its plot-area ANCHOR; it is resolved to a rect
            // here, at layout time, in this view's coordinate space. Selection
            // visuals + gesture live outside the (equatable, skipped-during-
            // drag) chart and map km↔x linearly within that rect.
            StaticProfileChart(
                points: displayProfile,
                xDomain: 0...Swift.max(maxKm, 0.001),
                yDomain: elevationDomain,
                currentKm: currentKm,
                positionIsOnTrack: positionIsOnTrack
            )
            .equatable()
            .overlayPreferenceValue(PlotAnchorPreferenceKey.self) { anchor in
                GeometryReader { geometry in
                    selectionOverlay(plot: anchor.map { geometry[$0] } ?? .zero)
                }
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private func selectionOverlay(plot plotFrame: CGRect) -> some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            if let selection = selectedKmRange, plotFrame.width > 0, maxKm > 0 {
                let x0 = plotFrame.minX + selection.lowerBound / maxKm * plotFrame.width
                let x1 = plotFrame.minX + selection.upperBound / maxKm * plotFrame.width
                Rectangle()
                    .fill(.orange.opacity(0.16))
                    .frame(width: max(1, x1 - x0), height: plotFrame.height)
                    .offset(x: x0, y: plotFrame.minY)
                ForEach([x0, x1 - 1.5], id: \.self) { x in
                    Rectangle()
                        .fill(.orange)
                        .frame(width: 1.5, height: plotFrame.height)
                        .offset(x: x, y: plotFrame.minY)
                }
                // Grab handles: drag one to adjust that edge; drag anywhere
                // else to start a fresh selection.
                ForEach([x0, x1], id: \.self) { x in
                    Circle()
                        .fill(.orange)
                        .stroke(.white, lineWidth: 2)
                        .frame(width: 13, height: 13)
                        .offset(x: x - 6.5, y: plotFrame.midY - 6.5)
                }
            }
        }
        .contentShape(Rectangle())
        .gesture(dragGesture(plot: plotFrame))
    }

    private func dragGesture(plot plotFrame: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { drag in
                guard plotFrame.width > 0, maxKm > 0 else { return }
                func km(at x: CGFloat) -> Double {
                    min(maxKm, max(0, Double((x - plotFrame.minX) / plotFrame.width) * maxKm))
                }
                func xPosition(ofKm km: Double) -> CGFloat {
                    plotFrame.minX + km / maxKm * plotFrame.width
                }

                if dragMode == nil {
                    if let selection = selectedKmRange {
                        let startX = drag.startLocation.x
                        if abs(startX - xPosition(ofKm: selection.lowerBound)) < Self.handleGrabWidth {
                            dragMode = .adjustLower
                        } else if abs(startX - xPosition(ofKm: selection.upperBound)) < Self.handleGrabWidth {
                            dragMode = .adjustUpper
                        } else {
                            dragMode = .newRange
                        }
                    } else {
                        dragMode = .newRange
                    }
                }

                switch dragMode {
                case .newRange, nil:
                    let a = km(at: drag.startLocation.x)
                    let b = km(at: drag.location.x)
                    let low = min(a, b)
                    let high = max(a, b)
                    if high - low > 0.02 {
                        selectedKmRange = low...high
                    }
                case .adjustLower:
                    if let selection = selectedKmRange {
                        let newLower = min(km(at: drag.location.x), selection.upperBound - 0.02)
                        selectedKmRange = max(0, newLower)...selection.upperBound
                    }
                case .adjustUpper:
                    if let selection = selectedKmRange {
                        let newUpper = max(km(at: drag.location.x), selection.lowerBound + 0.02)
                        selectedKmRange = selection.lowerBound...min(maxKm, newUpper)
                    }
                }
            }
            .onEnded { _ in
                dragMode = nil
            }
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
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
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
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
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

/// The expensive part: area + line marks. Wrapped `.equatable()` so SwiftUI
/// skips it entirely while only the selection (outside) changes.
private struct StaticProfileChart: View, Equatable {
    let points: [ProfilePoint]
    let xDomain: ClosedRange<Double>
    let yDomain: ClosedRange<Double>
    let currentKm: Double?
    let positionIsOnTrack: Bool

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.points.count == rhs.points.count
            && lhs.points.first == rhs.points.first
            && lhs.points.last == rhs.points.last
            && lhs.xDomain == rhs.xDomain
            && lhs.yDomain == rhs.yDomain
            && lhs.currentKm == rhs.currentKm
            && lhs.positionIsOnTrack == rhs.positionIsOnTrack
    }

    var body: some View {
        Chart {
            ForEach(points.indices, id: \.self) { index in
                AreaMark(
                    x: .value("km", points[index].distance / 1000),
                    yStart: .value("m", yDomain.lowerBound),
                    yEnd: .value("m", points[index].elevation)
                )
                .foregroundStyle(
                    .linearGradient(
                        colors: [.purple.opacity(0.35), .purple.opacity(0.05)],
                        startPoint: .top, endPoint: .bottom)
                )
                .interpolationMethod(.monotone)

                LineMark(
                    x: .value("km", points[index].distance / 1000),
                    y: .value("m", points[index].elevation)
                )
                .foregroundStyle(.purple)
                .lineStyle(StrokeStyle(lineWidth: 2))
                .interpolationMethod(.monotone)
            }

            if let currentKm {
                RuleMark(x: .value("km", currentKm))
                    .foregroundStyle(positionIsOnTrack ? Color.blue : Color.gray.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 2))
            }
        }
        .chartXScale(domain: xDomain)
        .chartYScale(domain: yDomain)
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
        .chartOverlay { proxy in
            Color.clear.preference(key: PlotAnchorPreferenceKey.self, value: proxy.plotFrame)
        }
    }
}

private struct PlotAnchorPreferenceKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}
