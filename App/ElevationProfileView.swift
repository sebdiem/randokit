import Charts
import RandoKit
import SwiftUI

/// Interaction model ("map grammar"): navigation is always map-like — drag
/// pans, pinch and double-tap zoom. A measurement becomes an object only
/// after the user explicitly draws its endpoints: the ruler button (or a
/// long-press) ARMS a single-use definition mode, the next drag draws the
/// exact range, then the mode exits. Once created, only its handles move it;
/// dragging anywhere else pans. Orange is reserved for the measurement.
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
    /// Inspected point (shared with the map) and the tap that sets it.
    var tappedKm: Double?
    var onTap: ((Double) -> Void)?

    /// Visible slice re-downsampled from full resolution — zoom reveals real
    /// detail. Set synchronously with `visibleKmRange` by the zoom handlers so
    /// domain and points flip in the same body pass (single chart re-render).
    @State private var zoomedProfile: [ProfilePoint]?
    @State private var dragMode: DragMode?
    @State private var defineAnchorKm: Double?
    @State private var panConsumedX: CGFloat = 0
    @State private var pinchStart: (domain: ClosedRange<Double>, anchorFraction: Double)?
    @State private var miniMapGrabOffsetKm: Double?
    /// Single-use measurement-definition mode (ruler button or long-press).
    @State private var isArmed = false
    @State private var showsPanHint = false
    @AppStorage("profilePanHintShown") private var panHintShown = false
    @State private var autoPanTask: Task<Void, Never>?
    @State private var autoPanDirection: Double = 0
    @State private var lastDragX: CGFloat = 0
    @State private var lastDragPlot: CGRect = .zero

    private enum DragMode {
        case panning
        case defining
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
    /// steep at every zoom level and pan position.
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
        VStack(alignment: .leading, spacing: 4) {
            header
            miniMapRow

            // The chart exports its plot-area ANCHOR; it is resolved to a rect
            // here, at layout time, in this view's coordinate space. Overlay
            // visuals + gestures live outside the (equatable, skipped-during-
            // gesture) chart and map km↔x linearly within the visible domain.
            StaticProfileChart(
                points: visiblePoints,
                xDomain: visibleDomain,
                yDomain: elevationDomain
            )
            .equatable()
            .overlayPreferenceValue(PlotAnchorPreferenceKey.self) { anchor in
                GeometryReader { geometry in
                    selectionOverlay(plot: anchor.map { geometry[$0] } ?? .zero)
                }
            }
            .frame(height: 130)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .onChange(of: visibleKmRange) { _, newValue in
            syncZoomedProfile(to: newValue)
        }
        .onChange(of: selectedKmRange == nil) { _, _ in
            // Creating or clearing a measurement always leaves definition mode.
            if selectedKmRange != nil {
                isArmed = false
            }
        }
        .onDisappear {
            stopAutoPan()
        }
    }

    // MARK: - Zoom

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

    // MARK: - Measurement arming

    private func arm() {
        guard selectedKmRange == nil, !isArmed else { return }
        isArmed = true
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    // MARK: - Mini-map row (shown while zoomed: fit button + context + drag-to-pan)

    @ViewBuilder
    private var miniMapRow: some View {
        if visibleKmRange != nil, maxKm > 0 {
            HStack(spacing: 0) {
                headerButton(
                    "arrow.up.left.and.arrow.down.right", label: "Afficher tout l'itinéraire",
                    action: resetZoom)
                miniMapStrip
            }
        }
    }

    /// The strip draws thin but the whole 40 pt row accepts touches.
    private var miniMapStrip: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let bandHeight: CGFloat = 18
            let bandTop = (geometry.size.height - bandHeight) / 2
            ZStack(alignment: .topLeading) {
                Color.clear
                MiniProfilePath(profile: displayProfile, maxDistance: linearized.totalDistance)
                    .stroke(Color.secondary.opacity(0.55), lineWidth: 1)
                    .frame(height: bandHeight)
                    .offset(y: bandTop)
                // Navigation window: neutral color — orange is reserved for
                // the measurement.
                if let window = visibleKmRange {
                    let x0 = window.lowerBound / maxKm * width
                    let x1 = window.upperBound / maxKm * width
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.primary.opacity(0.08))
                        .strokeBorder(Color.secondary, lineWidth: 1)
                        .frame(width: max(10, x1 - x0), height: bandHeight)
                        .offset(x: x0, y: bandTop)
                }
                // Measurement, if any, so it stays locatable when offscreen.
                if let selection = selectedKmRange {
                    let x0 = selection.lowerBound / maxKm * width
                    let x1 = selection.upperBound / maxKm * width
                    Rectangle()
                        .fill(Color.orange.opacity(0.7))
                        .frame(width: max(2, x1 - x0), height: 3)
                        .offset(x: x0, y: bandTop + bandHeight + 1)
                }
                // GPS position tick.
                if let currentKm, maxKm > 0 {
                    Rectangle()
                        .fill(positionIsOnTrack ? Color.blue : Color.gray)
                        .frame(width: 2, height: bandHeight)
                        .offset(x: currentKm / maxKm * width - 1, y: bandTop)
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
        .frame(height: 40)
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

    private func yPosition(ofElevation elevation: Double, plot: CGRect) -> CGFloat {
        let domain = elevationDomain
        let span = domain.upperBound - domain.lowerBound
        let fraction = span > 0 ? (elevation - domain.lowerBound) / span : 0
        return plot.minY + (1 - fraction) * plot.height
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
            // Inspected point: white dot with a purple ring on the curve.
            if let tappedKm, plotFrame.width > 0, visibleDomain.contains(tappedKm),
                let elevation = linearized.elevation(atDistance: tappedKm * 1000)
            {
                Circle()
                    .fill(.white)
                    .overlay(Circle().stroke(.purple, lineWidth: 2.5))
                    .frame(width: 12, height: 12)
                    .offset(
                        x: kmToX(tappedKm, plot: plotFrame) - 6,
                        y: yPosition(ofElevation: elevation, plot: plotFrame) - 6)
            }
            // GPS position: a dot ON the curve at the projected km/elevation,
            // same color semantics as the map dot. Drawn in the overlay so
            // GPS fixes never invalidate the chart.
            if let currentKm, plotFrame.width > 0, visibleDomain.contains(currentKm),
                let elevation = linearized.elevation(atDistance: currentKm * 1000)
            {
                Circle()
                    .fill(positionIsOnTrack ? Color.blue : Color.gray)
                    .overlay(Circle().stroke(.white, lineWidth: 2))
                    .frame(width: 12, height: 12)
                    .offset(
                        x: kmToX(currentKm, plot: plotFrame) - 6,
                        y: yPosition(ofElevation: elevation, plot: plotFrame) - 6)
            }
            // Offscreen GPS indicator.
            if let currentKm, plotFrame.width > 0, !visibleDomain.contains(currentKm) {
                let positionColor: Color = positionIsOnTrack ? .blue : .gray
                if currentKm < visibleDomain.lowerBound {
                    edgeIndicator(
                        "location.fill", color: positionColor, x: plotFrame.minX + 12,
                        plot: plotFrame, verticalFraction: 0.25)
                } else {
                    edgeIndicator(
                        "location.fill", color: positionColor, x: plotFrame.maxX - 12,
                        plot: plotFrame, verticalFraction: 0.25)
                }
            }
            if isArmed {
                hintCapsule("Glissez sur le profil pour mesurer", plot: plotFrame)
            } else if showsPanHint {
                hintCapsule("Pincez ou touchez deux fois pour zoomer", plot: plotFrame)
            }
        }
        .contentShape(Rectangle())
        .gesture(dragGesture(plot: plotFrame))
        .simultaneousGesture(
            doubleTapGesture(plot: plotFrame)
                .exclusively(before: singleTapGesture(plot: plotFrame)))
        .simultaneousGesture(magnifyGesture(plot: plotFrame))
        .simultaneousGesture(longPressGesture())
    }

    /// Single tap inspects a point (km/elevation info shared with the map).
    /// Composed after the double-tap so zooming still wins.
    private func singleTapGesture(plot plotFrame: CGRect) -> some Gesture {
        SpatialTapGesture(count: 1)
            .onEnded { tap in
                guard plotFrame.width > 0, !isArmed else { return }
                onTap?(xToKm(tap.location.x, plot: plotFrame))
            }
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

    private func edgeIndicator(
        _ systemName: String, color: Color, x: CGFloat, plot plotFrame: CGRect,
        verticalFraction: CGFloat = 0.5
    ) -> some View {
        Image(systemName: systemName)
            .font(.caption2.weight(.bold))
            .foregroundStyle(color)
            .padding(4)
            .background(.regularMaterial, in: Circle())
            .position(x: x, y: plotFrame.minY + plotFrame.height * verticalFraction)
    }

    private func hintCapsule(_ text: String, plot plotFrame: CGRect) -> some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.regularMaterial, in: Capsule())
            .position(x: plotFrame.midX, y: plotFrame.minY + 16)
    }

    /// Drag = define (when armed), adjust a handle (when starting on one),
    /// otherwise PAN the window. Navigation never edits the measurement.
    private func dragGesture(plot plotFrame: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { drag in
                guard plotFrame.width > 0, maxKm > 0, pinchStart == nil else { return }

                if dragMode == nil {
                    if isArmed {
                        dragMode = .defining
                        defineAnchorKm = xToKm(drag.startLocation.x, plot: plotFrame)
                    } else if let selection = selectedKmRange,
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
                        if visibleKmRange == nil {
                            flashPanHint()
                        }
                    }
                }

                switch dragMode {
                case .defining:
                    guard let anchor = defineAnchorKm else { return }
                    let current = xToKm(drag.location.x, plot: plotFrame)
                    let low = min(anchor, current)
                    let high = max(anchor, current)
                    if high - low > 0.02 {
                        selectedKmRange = low...high
                    }
                case .adjustLower, .adjustUpper:
                    lastDragX = drag.location.x
                    lastDragPlot = plotFrame
                    reapplyDraggedEdge()
                    updateAutoPan(forX: drag.location.x, plot: plotFrame)
                case .panning:
                    pan(translationX: drag.translation.width, plot: plotFrame)
                case nil:
                    break
                }
            }
            .onEnded { _ in
                // Single-use mode: definition mode exits once a range exists.
                if dragMode == .defining, selectedKmRange != nil {
                    isArmed = false
                }
                dragMode = nil
                defineAnchorKm = nil
                panConsumedX = 0
                stopAutoPan()
            }
    }

    /// Applies the finger position to the dragged measurement edge. Called
    /// from gesture ticks AND from auto-pan steps (finger stationary at the
    /// plot edge while the window scrolls underneath — `xToKm` clamps to the
    /// visible domain, so the edge follows the moving window).
    private func reapplyDraggedEdge() {
        guard lastDragPlot.width > 0 else { return }
        switch dragMode {
        case .adjustLower:
            if let selection = selectedKmRange {
                let newLower = min(
                    xToKm(lastDragX, plot: lastDragPlot), selection.upperBound - 0.02)
                selectedKmRange = max(0, newLower)...selection.upperBound
            }
        case .adjustUpper:
            if let selection = selectedKmRange {
                let newUpper = max(
                    xToKm(lastDragX, plot: lastDragPlot), selection.lowerBound + 0.02)
                selectedKmRange = selection.lowerBound...min(maxKm, newUpper)
            }
        case .panning, .defining, nil:
            break
        }
    }

    // MARK: - Handle-only edge auto-pan
    //
    // Only handle drags auto-pan: they unambiguously mean measurement editing.
    // A short dwell prevents accidental triggering when brushing the edge, and
    // the speed ramps up gradually so the window never runs away.

    private static let autoPanEdgeZone: CGFloat = 26

    private func updateAutoPan(forX x: CGFloat, plot plotFrame: CGRect) {
        guard dragMode == .adjustLower || dragMode == .adjustUpper,
            let window = visibleKmRange
        else {
            stopAutoPan()
            return
        }
        let direction: Double
        if x > plotFrame.maxX - Self.autoPanEdgeZone, window.upperBound < maxKm - 0.0001 {
            direction = 1
        } else if x < plotFrame.minX + Self.autoPanEdgeZone, window.lowerBound > 0.0001 {
            direction = -1
        } else {
            stopAutoPan()
            return
        }
        if autoPanTask != nil, direction == autoPanDirection {
            return
        }
        stopAutoPan()
        autoPanDirection = direction
        autoPanTask = Task { @MainActor in
            // Dwell before the first shift.
            try? await Task.sleep(nanoseconds: 300_000_000)
            var tick = 0
            while !Task.isCancelled {
                guard dragMode == .adjustLower || dragMode == .adjustUpper,
                    let current = visibleKmRange
                else { break }
                let span = current.upperBound - current.lowerBound
                let fraction = min(0.03 + 0.012 * Double(tick), 0.10)
                var lower = current.lowerBound + span * fraction * direction
                lower = max(0, min(lower, maxKm - span))
                let shifted = lower...(lower + span)
                guard shifted != current else { break }
                setZoom(shifted)
                reapplyDraggedEdge()
                tick += 1
                try? await Task.sleep(nanoseconds: 120_000_000)
            }
        }
    }

    private func stopAutoPan() {
        autoPanTask?.cancel()
        autoPanTask = nil
        autoPanDirection = 0
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

    private func flashPanHint() {
        guard !panHintShown else { return }
        panHintShown = true
        showsPanHint = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            showsPanHint = false
        }
    }

    /// Double-tap zooms in 2× at the tap point (map grammar). Zooming out is
    /// pinch-out, the fit button, or the mini-map.
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

    /// Long-press arms measurement definition (haptic); the same touch can
    /// then drag to define the range in one gesture. Releasing without
    /// dragging leaves the mode armed — it never invents a range.
    private func longPressGesture() -> some Gesture {
        LongPressGesture(minimumDuration: 0.35)
            .onEnded { _ in
                arm()
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
                    stopAutoPan()
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
    //
    // Stable slots: [title] [spacer] [scope-labeled stats] [recovery?] [ruler|✕].
    // The trailing slot always exists (ruler without a measurement, ✕ with one)
    // so the header never feels jumpy.

    @ViewBuilder
    private var header: some View {
        HStack(alignment: .center, spacing: 0) {
            Group {
                if selectedKmRange != nil {
                    Text("Mesure")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.orange)
                } else if let window = visibleKmRange {
                    Text("\(kmLabel(window.lowerBound)) – \(kmLabel(window.upperBound)) km")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                } else {
                    Text(name ?? "Trace")
                        .font(.footnote.weight(.semibold))
                }
            }
            .lineLimit(1)

            Spacer(minLength: 8)

            Text(scopedSummary)
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)

            if selectedKmRange != nil {
                headerButton("xmark.circle.fill", label: "Supprimer la mesure") {
                    selectedKmRange = nil
                }
            } else {
                headerButton("ruler", label: "Mesurer", tint: isArmed ? .orange : nil) {
                    if isArmed {
                        isArmed = false
                    } else {
                        arm()
                    }
                }
            }
        }
        .frame(height: 44)
    }

    /// Stats always carry their scope — numbers must never silently change
    /// meaning between states. In measurement/window states the title already
    /// names the scope; only the trace-name state needs the explicit prefix.
    private var scopedSummary: String {
        if let selection = selectedKmRange {
            return summary(for: selection)
        }
        if let window = visibleKmRange {
            return summary(for: window)
        }
        return "Total · \(summary(for: nil))"
    }

    private func kmLabel(_ km: Double) -> String {
        km.formatted(.number.precision(.fractionLength(1)))
    }

    private func headerButton(
        _ systemName: String, label: String, tint: Color? = nil, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .foregroundStyle(tint ?? Color.secondary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
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

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.points.count == rhs.points.count
            && lhs.points.first == rhs.points.first
            && lhs.points.last == rhs.points.last
            && lhs.xDomain == rhs.xDomain
            && lhs.yDomain == rhs.yDomain
    }

    var body: some View {
        Chart {
            ForEach(points.indices, id: \.self) { index in
                AreaMark(
                    x: .value("km", points[index].distance / 1000),
                    yStart: .value("m", yDomain.lowerBound),
                    yEnd: .value("m", points[index].elevation),
                    series: .value("Segment", points[index].segmentIndex)
                )
                .foregroundStyle(
                    .linearGradient(
                        colors: [.purple.opacity(0.35), .purple.opacity(0.05)],
                        startPoint: .top, endPoint: .bottom)
                )
                .interpolationMethod(.monotone)

                LineMark(
                    x: .value("km", points[index].distance / 1000),
                    y: .value("m", points[index].elevation),
                    series: .value("Segment", points[index].segmentIndex)
                )
                .foregroundStyle(.purple)
                .lineStyle(StrokeStyle(lineWidth: 2))
                .interpolationMethod(.monotone)
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
        var previousSegment = profile[0].segmentIndex
        for profilePoint in profile.dropFirst() {
            if profilePoint.segmentIndex == previousSegment {
                path.addLine(to: point(profilePoint))
            } else {
                path.move(to: point(profilePoint))
                previousSegment = profilePoint.segmentIndex
            }
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
