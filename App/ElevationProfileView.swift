import Charts
import RandoKit
import SwiftUI

/// Interaction model ("map grammar"): the profile behaves exactly like the
/// map above it — drag pans (when zoomed), pinch zooms anchored, double-tap
/// zooms in. A measurement is an explicit placed object (ruler button or
/// long-press), adjusted ONLY through its two handles; it is never created or
/// moved by plain drags. One grammar for navigation, one object for measuring.
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
    @State private var panConsumedX: CGFloat = 0
    @State private var pinchStart: (domain: ClosedRange<Double>, anchorFraction: Double)?
    @State private var miniMapGrabOffsetKm: Double?
    @State private var longPressCreated = false

    private enum DragMode {
        case panning
        case adjustLower
        case adjustUpper
    }

    /// Touch tolerance around a measurement handle: inside it a drag adjusts
    /// that edge, everywhere else a drag pans.
    private static let handleGrabWidth: CGFloat = 24
    private static let minZoomSpanKm = 0.2

    private var maxKm: Double { linearized.totalDistance / 1000 }

    private var visibleDomain: ClosedRange<Double> {
        visibleKmRange ?? 0...Swift.max(maxKm, 0.001)
    }

    private var visiblePoints: [ProfilePoint] {
        zoomedProfile ?? displayProfile
    }

    /// Always derived from the FULL trace: a given slope must look equally
    /// steep at every zoom level and pan position. Adaptive y-scaling reads
    /// as higher resolution but actually distorts gradient perception.
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
            miniMapRow

            // The chart exports its plot-area ANCHOR; it is resolved to a rect
            // here, at layout time, in this view's coordinate space. Overlay
            // visuals + gestures live outside the (equatable, skipped-during-
            // gesture) chart and map km↔x linearly within the visible domain.
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

    private func zoomTarget(for selection: ClosedRange<Double>) -> ClosedRange<Double>? {
        guard maxKm > 0 else { return nil }
        let center = (selection.lowerBound + selection.upperBound) / 2
        let halfSpan =
            Swift.max((selection.upperBound - selection.lowerBound) * 1.2, Self.minZoomSpanKm) / 2
        let lower = Swift.max(0, center - halfSpan)
        let upper = Swift.min(maxKm, center + halfSpan)
        guard upper > lower else { return nil }
        return lower...upper
    }

    /// The zoom-in button only exists when it would visibly change the view.
    private var canZoomToSelection: Bool {
        guard let selection = selectedKmRange, let target = zoomTarget(for: selection) else {
            return false
        }
        guard let current = visibleKmRange else { return true }
        let tolerance = (current.upperBound - current.lowerBound) * 0.01
        return abs(target.lowerBound - current.lowerBound) > tolerance
            || abs(target.upperBound - current.upperBound) > tolerance
    }

    private func zoomToSelection() {
        guard let selection = selectedKmRange, let target = zoomTarget(for: selection) else { return }
        setZoom(target)
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

    // MARK: - Measurement lifecycle

    /// Places a measurement covering ~30% of the visible window around a km.
    private func createMeasurement(atKm center: Double) {
        guard maxKm > 0 else { return }
        let window = visibleDomain
        let span = Swift.max((window.upperBound - window.lowerBound) * 0.3, 0.04)
        guard span < maxKm else { return }
        let lower = Swift.max(0, Swift.min(center - span / 2, maxKm - span))
        selectedKmRange = lower...(lower + span)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    // MARK: - Mini-map row (shown while zoomed: zoom controls + context + drag-to-pan)

    @ViewBuilder
    private var miniMapRow: some View {
        if visibleKmRange != nil, maxKm > 0 {
            HStack(spacing: 8) {
                headerButton("minus.magnifyingglass", action: resetZoom)
                miniMapStrip
            }
        }
    }

    private var miniMapStrip: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .topLeading) {
                MiniProfilePath(profile: displayProfile, maxDistance: linearized.totalDistance)
                    .stroke(Color.secondary.opacity(0.55), lineWidth: 1)
                if let window = visibleKmRange {
                    let x0 = window.lowerBound / maxKm * width
                    let x1 = window.upperBound / maxKm * width
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.orange.opacity(0.18))
                        .strokeBorder(Color.orange, lineWidth: 1)
                        .frame(width: max(10, x1 - x0), height: geometry.size.height)
                        .offset(x: x0)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        guard let current = visibleKmRange, width > 0 else { return }
                        let span = current.upperBound - current.lowerBound
                        let touchKm = Double(drag.location.x / width) * maxKm
                        // Grabbing the window drags it like a scrollbar
                        // thumb (relative); touching outside jumps there.
                        if miniMapGrabOffsetKm == nil {
                            let center = (current.lowerBound + current.upperBound) / 2
                            let insideWindow = current.contains(touchKm)
                            miniMapGrabOffsetKm = insideWindow ? center - touchKm : 0
                        }
                        var center = touchKm + (miniMapGrabOffsetKm ?? 0)
                        center = Swift.min(maxKm - span / 2, Swift.max(span / 2, center))
                        // Quantized so a slow drag emits a handful of
                        // window updates per second, not sixty.
                        let step = span / 100
                        let lower = ((center - span / 2) / step).rounded() * step
                        let window = lower...(lower + span)
                        if window != current {
                            setZoom(window)
                        }
                    }
                    .onEnded { _ in
                        miniMapGrabOffsetKm = nil
                    }
            )
        }
        .frame(height: 18)
    }

    // MARK: - Chart overlay (measurement visuals + navigation gestures)

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
        .simultaneousGesture(magnifyGesture(plot: plotFrame))
        .simultaneousGesture(longPressGesture(plot: plotFrame))
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

    /// Drag = adjust a handle when it starts on one, otherwise PAN the window.
    private func dragGesture(plot plotFrame: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { drag in
                guard plotFrame.width > 0, maxKm > 0, pinchStart == nil, !longPressCreated
                else { return }

                if dragMode == nil {
                    if let selection = selectedKmRange,
                        abs(drag.startLocation.x - kmToX(selection.lowerBound, plot: plotFrame))
                            < Self.handleGrabWidth
                    {
                        dragMode = .adjustLower
                    } else if let selection = selectedKmRange,
                        abs(drag.startLocation.x - kmToX(selection.upperBound, plot: plotFrame))
                            < Self.handleGrabWidth
                    {
                        dragMode = .adjustUpper
                    } else {
                        dragMode = .panning
                        panConsumedX = 0
                    }
                }

                switch dragMode {
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
                case .panning:
                    pan(translationX: drag.translation.width, plot: plotFrame)
                case nil:
                    break
                }
            }
            .onEnded { _ in
                dragMode = nil
                panConsumedX = 0
            }
    }

    /// Map-style pan, quantized so a drag emits a handful of window updates
    /// per second. `panConsumedX` tracks the already-applied translation.
    private func pan(translationX: CGFloat, plot plotFrame: CGRect) {
        guard let window = visibleKmRange else { return }
        let span = window.upperBound - window.lowerBound
        let kmPerPoint = span / Double(plotFrame.width)
        let pendingKm = -Double(translationX - panConsumedX) * kmPerPoint
        let step = span / 150
        let steps = (pendingKm / step).rounded(.towardZero)
        guard steps != 0 else { return }
        let shift = steps * step
        let lower = Swift.max(0, Swift.min(window.lowerBound + shift, maxKm - span))
        let applied = lower - window.lowerBound
        guard applied != 0 else { return }
        panConsumedX += CGFloat(-applied / kmPerPoint)
        setZoom(lower...(lower + span))
    }

    /// Double-tap zooms in 2× at the tap point (map grammar). Zooming out is
    /// pinch-out, the ⊖ button, or the mini-map.
    private func doubleTapGesture(plot plotFrame: CGRect) -> some Gesture {
        SpatialTapGesture(count: 2)
            .onEnded { tap in
                guard plotFrame.width > 0, maxKm > Self.minZoomSpanKm else { return }
                let currentSpan = visibleDomain.upperBound - visibleDomain.lowerBound
                let newSpan = Swift.max(currentSpan / 2, Self.minZoomSpanKm)
                guard newSpan < currentSpan * 0.99 else { return }
                let center = xToKm(tap.location.x, plot: plotFrame)
                let lower = Swift.max(0, Swift.min(center - newSpan / 2, maxKm - newSpan))
                setZoom(lower...(lower + newSpan))
            }
    }

    /// Long-press places a measurement at the pressed spot (like dropping a
    /// pin on the map). The ruler button does the same at the window center.
    private func longPressGesture(plot plotFrame: CGRect) -> some Gesture {
        LongPressGesture(minimumDuration: 0.35)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .onChanged { value in
                guard case .second(true, let drag?) = value, !longPressCreated,
                    plotFrame.width > 0
                else { return }
                longPressCreated = true
                createMeasurement(atKm: xToKm(drag.startLocation.x, plot: plotFrame))
            }
            .onEnded { value in
                if case .second(true, let drag?) = value, !longPressCreated, plotFrame.width > 0 {
                    createMeasurement(atKm: xToKm(drag.startLocation.x, plot: plotFrame))
                }
                longPressCreated = false
            }
    }

    /// Two-finger pinch: continuous zoom anchored at the pinch location.
    /// Quantized (1% of span); pinching out past the full extent resets.
    private func magnifyGesture(plot plotFrame: CGRect) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                guard plotFrame.width > 0, maxKm > Self.minZoomSpanKm else { return }
                if pinchStart == nil {
                    let domain = visibleDomain
                    let anchorKm = xToKm(value.startLocation.x, plot: plotFrame)
                    let span = domain.upperBound - domain.lowerBound
                    pinchStart = (domain, (anchorKm - domain.lowerBound) / span)
                    // A pinch cancels any in-flight drag.
                    dragMode = nil
                }
                guard let start = pinchStart else { return }
                let startSpan = start.domain.upperBound - start.domain.lowerBound
                let startAnchorKm = start.domain.lowerBound + start.anchorFraction * startSpan
                let magnification = max(0.01, Double(value.magnification))
                var newSpan = startSpan / magnification
                if newSpan >= maxKm * 0.995 {
                    if visibleKmRange != nil {
                        setZoom(nil)
                    }
                    return
                }
                newSpan = max(Self.minZoomSpanKm, min(newSpan, maxKm))
                var lower = startAnchorKm - start.anchorFraction * newSpan
                lower = max(0, min(lower, maxKm - newSpan))
                let target = lower...(lower + newSpan)
                if let current = visibleKmRange {
                    let tolerance = (current.upperBound - current.lowerBound) * 0.01
                    if abs(target.lowerBound - current.lowerBound) < tolerance,
                        abs(target.upperBound - current.upperBound) < tolerance
                    {
                        return
                    }
                }
                setZoom(target)
            }
            .onEnded { _ in
                pinchStart = nil
            }
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let selection = selectedKmRange {
                Text("Mesure")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.orange)
                Spacer()
                Text(summary(for: selection))
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if canZoomToSelection {
                    headerButton("plus.magnifyingglass", action: zoomToSelection)
                }
                headerButton("xmark.circle.fill") {
                    selectedKmRange = nil
                }
            } else if let window = visibleKmRange {
                // Zoomed without a measurement: the header describes the
                // visible window, so the numbers always match the chart.
                Text("\(kmLabel(window.lowerBound)) – \(kmLabel(window.upperBound)) km")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Text(summary(for: window))
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                headerButton("ruler") {
                    let window = visibleDomain
                    createMeasurement(atKm: (window.lowerBound + window.upperBound) / 2)
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
                headerButton("ruler") {
                    let window = visibleDomain
                    createMeasurement(atKm: (window.lowerBound + window.upperBound) / 2)
                }
            }
        }
    }

    private func kmLabel(_ km: Double) -> String {
        km.formatted(.number.precision(.fractionLength(1)))
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
/// skips it entirely while only the overlay (outside) changes.
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

/// The whole trace as a tiny path for the mini-map strip.
private struct MiniProfilePath: Shape {
    let profile: [ProfilePoint]
    let maxDistance: Double

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard maxDistance > 0, profile.count > 1 else { return path }
        let elevations = profile.map(\.elevation)
        let minElevation = elevations.min() ?? 0
        let maxElevation = max(elevations.max() ?? 1, minElevation + 1)
        func point(_ p: ProfilePoint) -> CGPoint {
            CGPoint(
                x: p.distance / maxDistance * rect.width,
                y: rect.maxY - (p.elevation - minElevation) / (maxElevation - minElevation) * rect.height)
        }
        path.move(to: point(profile[0]))
        for p in profile.dropFirst() {
            path.addLine(to: point(p))
        }
        return path
    }
}

private struct PlotAnchorPreferenceKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}
