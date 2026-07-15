import Charts
import RandoKit
import SwiftUI

struct ElevationProfileView: View {
    let name: String?
    /// Full resolution — all measurements come from here.
    let linearized: LinearizedTrace
    /// Reduced point set for full-extent chart marks.
    let displayProfile: [ProfilePoint]
    @Binding var selectedKmRange: ClosedRange<Double>?
    /// Zoomed x-domain in km; nil = full trace. Owned by the parent so it
    /// resets with the active trace.
    @Binding var visibleKmRange: ClosedRange<Double>?
    var currentKm: Double?
    var positionIsOnTrack = false

    /// Visible slice re-downsampled from full resolution — zoom reveals real
    /// detail. Set synchronously with `visibleKmRange` by the zoom handlers so
    /// domain and points flip in the same body pass (single chart re-render).
    @State private var zoomedProfile: [ProfilePoint]?
    @State private var dragMode: DragMode?

    private enum DragMode {
        case newRange
        case adjustLower
        case adjustUpper
    }

    /// Touch tolerance around a selection edge that grabs the handle instead
    /// of starting a new selection.
    private static let handleGrabWidth: CGFloat = 24
    private static let minZoomSpanKm = 0.2

    private var maxKm: Double { linearized.totalDistance / 1000 }

    private var visibleDomain: ClosedRange<Double> {
        visibleKmRange ?? 0...Swift.max(maxKm, 0.001)
    }

    private var visiblePoints: [ProfilePoint] {
        zoomedProfile ?? displayProfile
    }

    private var elevationDomain: ClosedRange<Double> {
        let elevations = visiblePoints.map(\.elevation)
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
            // visuals + gestures live outside the (equatable, skipped-during-
            // drag) chart and map km↔x linearly within the visible domain.
            StaticProfileChart(
                points: visiblePoints,
                xDomain: visibleDomain,
                yDomain: elevationDomain,
                currentKm: currentKm.flatMap { visibleDomain.contains($0) ? $0 : nil },
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
        .onChange(of: visibleKmRange) { _, newValue in
            syncZoomedProfile(to: newValue)
        }
    }

    // MARK: - Zoom

    private func zoomToSelection() {
        guard let selection = selectedKmRange, maxKm > 0 else { return }
        let center = (selection.lowerBound + selection.upperBound) / 2
        let halfSpan =
            Swift.max((selection.upperBound - selection.lowerBound) * 1.2, Self.minZoomSpanKm) / 2
        let lower = Swift.max(0, center - halfSpan)
        let upper = Swift.min(maxKm, center + halfSpan)
        guard upper > lower else { return }
        setZoom(lower...upper)
    }

    private func resetZoom() {
        setZoom(nil)
    }

    /// Sets domain and re-downsampled points in the same body pass — exactly
    /// one chart re-render per zoom action, no transient stale frame.
    private func setZoom(_ range: ClosedRange<Double>?) {
        zoomedProfile = zoomedSlice(for: range)
        visibleKmRange = range
    }

    /// Catches external changes (trace switch resets the binding, DEBUG
    /// presets); for internal setZoom calls this recomputes an equal array,
    /// which the equatable chart ignores.
    private func syncZoomedProfile(to range: ClosedRange<Double>?) {
        zoomedProfile = zoomedSlice(for: range)
    }

    private func zoomedSlice(for range: ClosedRange<Double>?) -> [ProfilePoint]? {
        range.map {
            linearized.downsampled(in: ($0.lowerBound * 1000)...($0.upperBound * 1000))
        }
    }

    // MARK: - Selection overlay (band, handles, gestures)

    private func kmToX(_ km: Double, plot: CGRect) -> CGFloat {
        let domain = visibleDomain
        let span = domain.upperBound - domain.lowerBound
        return plot.minX + (km - domain.lowerBound) / span * plot.width
    }

    private func xToKm(_ x: CGFloat, plot: CGRect) -> Double {
        let domain = visibleDomain
        let span = domain.upperBound - domain.lowerBound
        let fraction = Double((x - plot.minX) / plot.width)
        return Swift.min(
            domain.upperBound, Swift.max(domain.lowerBound, domain.lowerBound + fraction * span))
    }

    private func selectionOverlay(plot plotFrame: CGRect) -> some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            if let selection = selectedKmRange, plotFrame.width > 0 {
                let rawX0 = kmToX(selection.lowerBound, plot: plotFrame)
                let rawX1 = kmToX(selection.upperBound, plot: plotFrame)
                let x0 = max(plotFrame.minX, rawX0)
                let x1 = min(plotFrame.maxX, rawX1)
                if x1 > x0 {
                    Rectangle()
                        .fill(.orange.opacity(0.16))
                        .frame(width: max(1, x1 - x0), height: plotFrame.height)
                        .offset(x: x0, y: plotFrame.minY)
                    // Edge line + grab handle only for edges inside the view.
                    if rawX0 >= plotFrame.minX {
                        edgeMarker(atX: rawX0, plot: plotFrame)
                    }
                    if rawX1 <= plotFrame.maxX {
                        edgeMarker(atX: rawX1 - 1.5, plot: plotFrame)
                    }
                }
            }
        }
        .contentShape(Rectangle())
        .gesture(dragGesture(plot: plotFrame))
        .simultaneousGesture(doubleTapGesture(plot: plotFrame))
    }

    @ViewBuilder
    private func edgeMarker(atX x: CGFloat, plot plotFrame: CGRect) -> some View {
        Rectangle()
            .fill(.orange)
            .frame(width: 1.5, height: plotFrame.height)
            .offset(x: x, y: plotFrame.minY)
        Circle()
            .fill(.orange)
            .stroke(.white, lineWidth: 2)
            .frame(width: 13, height: 13)
            .offset(x: x - 6, y: plotFrame.midY - 6.5)
    }

    private func doubleTapGesture(plot plotFrame: CGRect) -> some Gesture {
        SpatialTapGesture(count: 2)
            .onEnded { tap in
                guard plotFrame.width > 0 else { return }
                if let selection = selectedKmRange {
                    let x0 = kmToX(selection.lowerBound, plot: plotFrame)
                    let x1 = kmToX(selection.upperBound, plot: plotFrame)
                    if tap.location.x >= x0, tap.location.x <= x1 {
                        zoomToSelection()
                        return
                    }
                }
                if visibleKmRange != nil {
                    resetZoom()
                }
            }
    }

    private func dragGesture(plot plotFrame: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { drag in
                guard plotFrame.width > 0, maxKm > 0 else { return }

                if dragMode == nil {
                    if let selection = selectedKmRange {
                        let startX = drag.startLocation.x
                        if abs(startX - kmToX(selection.lowerBound, plot: plotFrame))
                            < Self.handleGrabWidth
                        {
                            dragMode = .adjustLower
                        } else if abs(startX - kmToX(selection.upperBound, plot: plotFrame))
                            < Self.handleGrabWidth
                        {
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
                    let a = xToKm(drag.startLocation.x, plot: plotFrame)
                    let b = xToKm(drag.location.x, plot: plotFrame)
                    let low = min(a, b)
                    let high = max(a, b)
                    if high - low > 0.02 {
                        selectedKmRange = low...high
                    }
                case .adjustLower:
                    if let selection = selectedKmRange {
                        let newLower = min(
                            xToKm(drag.location.x, plot: plotFrame), selection.upperBound - 0.02)
                        selectedKmRange = max(0, newLower)...selection.upperBound
                    }
                case .adjustUpper:
                    if let selection = selectedKmRange {
                        let newUpper = max(
                            xToKm(drag.location.x, plot: plotFrame), selection.lowerBound + 0.02)
                        selectedKmRange = selection.lowerBound...min(maxKm, newUpper)
                    }
                }
            }
            .onEnded { _ in
                dragMode = nil
            }
    }

    // MARK: - Header

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
                headerButton("plus.magnifyingglass", action: zoomToSelection)
                if visibleKmRange != nil {
                    headerButton("minus.magnifyingglass", action: resetZoom)
                }
                headerButton("xmark.circle.fill") {
                    selectedKmRange = nil
                }
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
                if visibleKmRange != nil {
                    headerButton("minus.magnifyingglass", action: resetZoom)
                }
            }
        }
    }

    private func headerButton(_ systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
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
                        Text("\(km, format: .number.precision(.fractionLength(0...2))) km")
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
