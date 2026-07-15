import MapLibre
import RandoKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @AppStorage("tileSourceID") private var tileSourceID = TileSource.ignPlanV2.id
    @StateObject private var library = TraceLibrary()
    @StateObject private var downloader = CorridorDownloader()
    @StateObject private var location = LocationService()
    @State private var selectedKmRange: ClosedRange<Double>?
    @State private var monitor = OffTrackMonitor()
    @State private var currentProjection: TraceProjection?
    @State private var showsTracePicker = false
    @State private var showsFileImporter = false
    @State private var selectionCoordinates: [CLLocationCoordinate2D] = []
    @State private var visibleKmRange: ClosedRange<Double>?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            MapView(
                tileSource: .withID(tileSourceID),
                trace: library.active?.trace,
                traceKey: library.active?.entryID ?? "none",
                selectionCoordinates: selectionCoordinates,
                positionCoordinate: location.lastFix?.coordinate,
                positionColor: positionColor
            )
            .ignoresSafeArea()

            controls
                .padding(.trailing, 12)
        }
        .overlay(alignment: .bottom) {
            if let active = library.active {
                ElevationProfileView(
                    name: active.trace.name, linearized: active.linearized,
                    displayProfile: active.displayProfile,
                    selectedKmRange: $selectedKmRange,
                    visibleKmRange: $visibleKmRange,
                    currentKm: currentProjection.map { $0.distanceAlong / 1000 },
                    positionIsOnTrack: monitor.status == .onTrack
                )
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
            }
        }
        .sheet(isPresented: $showsTracePicker) {
            tracePicker
        }
        .fileImporter(
            isPresented: $showsFileImporter,
            allowedContentTypes: [UTType(filenameExtension: "gpx") ?? .xml]
        ) { result in
            if case .success(let url) = result {
                Task { await library.importGPX(from: url) }
            }
        }
        .onOpenURL { url in
            Task { await library.importGPX(from: url) }
        }
        .alert(
            library.importMessage ?? "", isPresented: .init(
                get: { library.importMessage != nil },
                set: { if !$0 { library.importMessage = nil } })
        ) {
            Button("OK") { library.importMessage = nil }
        }
        .onChange(of: library.active?.entryID) { oldValue, _ in
            resetTracking()
            // Trace activation is async; hooks that need an active trace run
            // after the first activation, not at onAppear.
            if oldValue == nil {
                applyPostActivationDebugHooks()
            }
        }
        .onChange(of: selectedKmRange) {
            updateSelectionCoordinates()
        }
        .onAppear(perform: applyDebugHooks)
        .onAppear {
            location.start()
        }
        .onReceive(location.$lastFix) { fix in
            handle(fix)
        }
    }

    private var controls: some View {
        VStack(spacing: 10) {
            Menu {
                Picker("Fond de carte", selection: $tileSourceID) {
                    ForEach(TileSource.all) { source in
                        Text(source.name).tag(source.id)
                    }
                }
            } label: {
                controlIcon("map")
            }

            Button {
                showsTracePicker = true
            } label: {
                controlIcon("folder")
            }

            if library.isImporting {
                ProgressView()
                    .padding(11)
                    .background(.regularMaterial, in: Circle())
            }

            if let progress = downloader.progress {
                Text("\(Int(progress * 100)) %")
                    .font(.footnote.monospacedDigit().weight(.semibold))
                    .padding(8)
                    .background(.regularMaterial, in: Capsule())
            } else if let active = library.active {
                Button {
                    Task {
                        await downloader.download(
                            trace: active.trace, source: .withID(tileSourceID))
                    }
                } label: {
                    controlIcon("arrow.down.circle")
                }
            }

            if location.authorization == .denied || location.authorization == .restricted {
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Image(systemName: "location.slash")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.red)
                        .padding(11)
                        .background(.regularMaterial, in: Circle())
                }
            }
        }
    }

    private func controlIcon(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 18, weight: .medium))
            .padding(11)
            .background(.regularMaterial, in: Circle())
    }

    private var tracePicker: some View {
        NavigationStack {
            List {
                ForEach(library.entries) { entry in
                    Button {
                        library.select(entry)
                        showsTracePicker = false
                    } label: {
                        HStack {
                            Text(entry.name)
                                .foregroundStyle(.primary)
                            Spacer()
                            if entry.id == library.active?.entryID {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Traces")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Importer…") {
                        showsTracePicker = false
                        showsFileImporter = true
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }

    /// Dot color is the whole off-track UI: blue on track, red off, gray
    /// while approaching the start, past the end, or without a status yet.
    private var positionColor: UIColor {
        switch monitor.status {
        case .onTrack: .systemBlue
        case .offTrack: .systemRed
        case .approachingStart, .finished, .unknown: .systemGray
        }
    }

    private func resetTracking() {
        let dwell = monitor.dwell
        monitor = OffTrackMonitor(dwell: dwell)
        currentProjection = nil
        selectedKmRange = nil
        selectionCoordinates = []
        visibleKmRange = nil
    }

    /// Recomputed only when the selection changes (not on every GPS fix);
    /// endpoints are interpolated so even a between-samples range highlights.
    private func updateSelectionCoordinates() {
        guard let projector = library.active?.projector, let kmRange = selectedKmRange else {
            selectionCoordinates = []
            return
        }
        var slice = projector
            .sliceCoordinates(in: (kmRange.lowerBound * 1000)...(kmRange.upperBound * 1000))
        // The overlay is redrawn on every drag tick — cap its point count
        // (visually indistinguishable, keeps long-trace drags fluid).
        let maxOverlayPoints = 800
        if slice.count > maxOverlayPoints, let last = slice.last {
            let stride = Double(slice.count) / Double(maxOverlayPoints)
            slice = (0..<maxOverlayPoints).map { slice[Int(Double($0) * stride)] } + [last]
        }
        selectionCoordinates = slice
            .map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
    }

    private func handle(_ fix: CLLocation?) {
        guard let fix, let projector = library.active?.projector,
            let projection = projector.project(
                latitude: fix.coordinate.latitude, longitude: fix.coordinate.longitude,
                nearSegment: currentProjection?.segmentIndex)
        else { return }
        monitor.update(
            projection: projection, horizontalAccuracy: fix.horizontalAccuracy,
            traceLength: projector.totalDistance, timestamp: fix.timestamp)
        currentProjection = projection
    }

    private func applyDebugHooks() {
        #if DEBUG
            let env = ProcessInfo.processInfo.environment
            if let dwell = env["OFFTRACK_DWELL"].flatMap(Double.init) {
                monitor.dwell = dwell
            }
            if let path = env["IMPORT_GPX"] {
                Task { await library.importGPX(from: URL(fileURLWithPath: path)) }
            }
        #endif
    }

    private func applyPostActivationDebugHooks() {
        #if DEBUG
            let env = ProcessInfo.processInfo.environment
            if let preset = env["PRESET_SELECTION"] {
                let parts = preset.split(separator: "-").compactMap { Double($0) }
                if parts.count == 2, parts[0] < parts[1] {
                    selectedKmRange = parts[0]...parts[1]
                }
            }
            if let zoomPreset = env["PRESET_ZOOM"], let active = library.active {
                let maxKm = active.linearized.totalDistance / 1000
                if zoomPreset == "1", let selection = selectedKmRange {
                    let padding = (selection.upperBound - selection.lowerBound) * 0.1
                    visibleKmRange =
                        max(0, selection.lowerBound - padding)...min(maxKm, selection.upperBound + padding)
                } else {
                    let parts = zoomPreset.split(separator: "-").compactMap { Double($0) }
                    if parts.count == 2, parts[0] < parts[1] {
                        visibleKmRange = max(0, parts[0])...min(maxKm, parts[1])
                    }
                }
            }
            if env["AUTO_DOWNLOAD"] == "1", let active = library.active {
                Task {
                    await downloader.download(trace: active.trace, source: .withID(tileSourceID))
                }
            }
        #endif
    }
}

enum SampleTrace {
    static let trace: GPXTrace? = {
        guard let url = Bundle.main.url(forResource: "SampleTrace", withExtension: "gpx"),
            let data = try? Data(contentsOf: url)
        else { return nil }
        return try? GPXParser().parse(data)
    }()
}

struct MapView: UIViewRepresentable {
    let tileSource: TileSource
    let trace: GPXTrace?
    let traceKey: String
    let selectionCoordinates: [CLLocationCoordinate2D]
    let positionCoordinate: CLLocationCoordinate2D?
    let positionColor: UIColor

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> MLNMapView {
        let view = MLNMapView(frame: .zero)
        view.delegate = context.coordinator
        // Chamonix fallback while there's no trace to frame.
        view.setCenter(
            CLLocationCoordinate2D(latitude: 45.9237, longitude: 6.8694),
            zoomLevel: 12, animated: false)
        apply(tileSource, to: view)
        return view
    }

    func updateUIView(_ view: MLNMapView, context: Context) {
        context.coordinator.parent = self
        apply(tileSource, to: view)
        context.coordinator.syncAll(on: view)
    }

    private func apply(_ source: TileSource, to view: MLNMapView) {
        view.maximumZoomLevel = Double(source.maxZoom)
        guard let url = try? source.styleURL() else { return }
        if view.styleURL != url {
            view.styleURL = url
        }
    }

    final class Coordinator: NSObject, MLNMapViewDelegate {
        var parent: MapView
        private var framedTraceKey: String?
        private var syncedTraceKey: String?
        private var syncedSelectionKey: String?
        private var syncedPositionKey: String?

        init(_ parent: MapView) {
            self.parent = parent
        }

        // Fires after every style load, including basemap switches (which wipe
        // all runtime layers) — everything is re-synced from scratch here.
        func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
            syncedTraceKey = nil
            syncedSelectionKey = nil
            syncedPositionKey = nil
            syncAll(on: mapView)
        }

        func syncAll(on mapView: MLNMapView) {
            guard mapView.style != nil else { return }
            syncTrace(on: mapView)
            syncSelection(on: mapView)
            syncPosition(on: mapView)
        }

        /// Rebuilds trace geometry only when the active trace (or the style)
        /// actually changed — position updates arrive every few meters and
        /// must not touch this. One polyline per GPX segment: disconnected
        /// segments render disconnected.
        private func syncTrace(on mapView: MLNMapView) {
            guard let style = mapView.style else { return }
            guard syncedTraceKey != parent.traceKey else { return }
            syncedTraceKey = parent.traceKey

            let trace = parent.trace
            let polylines: [MLNPolyline] = (trace?.segmentRanges ?? []).compactMap { range in
                guard range.count >= 2, let points = trace?.points[range] else { return nil }
                let coordinates = points.map {
                    CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
                }
                return MLNPolylineFeature(coordinates: coordinates, count: UInt(coordinates.count))
            }
            let shape: MLNShape? =
                polylines.isEmpty ? nil : MLNMultiPolylineFeature(polylines: polylines)

            if let source = style.source(withIdentifier: "trace") as? MLNShapeSource {
                source.shape = shape
            } else if shape != nil {
                let source = MLNShapeSource(identifier: "trace", shape: shape)
                style.addSource(source)

                let casing = MLNLineStyleLayer(identifier: "trace-casing", source: source)
                casing.lineColor = NSExpression(forConstantValue: UIColor.white)
                casing.lineWidth = NSExpression(forConstantValue: 7)
                casing.lineCap = NSExpression(forConstantValue: "round")
                casing.lineJoin = NSExpression(forConstantValue: "round")
                style.addLayer(casing)

                let stroke = MLNLineStyleLayer(identifier: "trace-line", source: source)
                stroke.lineColor = NSExpression(
                    forConstantValue: UIColor(red: 0.56, green: 0.14, blue: 0.67, alpha: 1))
                stroke.lineWidth = NSExpression(forConstantValue: 4)
                stroke.lineCap = NSExpression(forConstantValue: "round")
                stroke.lineJoin = NSExpression(forConstantValue: "round")
                style.addLayer(stroke)
            }

            let first = trace?.points.first.map {
                CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
            }
            let last = trace?.points.last.map {
                CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
            }
            syncEndpoint(shape == nil ? nil : first, id: "trace-start", color: .systemGreen, style: style)
            syncEndpoint(shape == nil ? nil : last, id: "trace-end", color: .systemRed, style: style)

            if framedTraceKey != parent.traceKey, let points = trace?.points, !points.isEmpty {
                framedTraceKey = parent.traceKey
                frame(
                    coordinates: points.map {
                        CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
                    }, on: mapView)
            }
        }

        private func syncEndpoint(
            _ coordinate: CLLocationCoordinate2D?, id: String, color: UIColor, style: MLNStyle
        ) {
            let shape: MLNShape? = coordinate.map {
                let point = MLNPointFeature()
                point.coordinate = $0
                return point
            }
            if let source = style.source(withIdentifier: id) as? MLNShapeSource {
                source.shape = shape
            } else if shape != nil {
                let source = MLNShapeSource(identifier: id, shape: shape)
                style.addSource(source)
                let circle = MLNCircleStyleLayer(identifier: id, source: source)
                circle.circleColor = NSExpression(forConstantValue: color)
                circle.circleRadius = NSExpression(forConstantValue: 7)
                circle.circleStrokeColor = NSExpression(forConstantValue: UIColor.white)
                circle.circleStrokeWidth = NSExpression(forConstantValue: 2.5)
                style.addLayer(circle)
            }
        }

        /// Keeps the orange "measured segment" overlay in sync with the profile
        /// selection. The source is created once and its shape updated in place;
        /// skipped entirely while the selection is unchanged.
        func syncSelection(on mapView: MLNMapView) {
            guard let style = mapView.style else { return }
            let coordinates = parent.selectionCoordinates

            let key = coordinates.isEmpty
                ? "none"
                : "\(coordinates.count)-\(coordinates[0].latitude)-\(coordinates[0].longitude)"
                    + "-\(coordinates[coordinates.count - 1].latitude)-\(coordinates[coordinates.count - 1].longitude)"
            guard key != syncedSelectionKey else { return }
            syncedSelectionKey = key

            let shape: MLNShape? =
                coordinates.count >= 2
                ? MLNPolylineFeature(coordinates: coordinates, count: UInt(coordinates.count))
                : nil

            if let source = style.source(withIdentifier: "selection") as? MLNShapeSource {
                source.shape = shape
            } else if shape != nil {
                let source = MLNShapeSource(identifier: "selection", shape: shape)
                style.addSource(source)
                let layer = MLNLineStyleLayer(identifier: "selection", source: source)
                layer.lineColor = NSExpression(forConstantValue: UIColor.systemOrange)
                layer.lineWidth = NSExpression(forConstantValue: 5)
                layer.lineCap = NSExpression(forConstantValue: "round")
                layer.lineJoin = NSExpression(forConstantValue: "round")
                if let startLayer = style.layer(withIdentifier: "trace-start") {
                    style.insertLayer(layer, below: startLayer)
                } else {
                    style.addLayer(layer)
                }
            }
        }

        /// GPS dot, always topmost. Color carries the off-track state.
        func syncPosition(on mapView: MLNMapView) {
            guard let style = mapView.style else { return }

            let key = parent.positionCoordinate.map {
                "\($0.latitude),\($0.longitude),\(parent.positionColor)"
            } ?? "none"
            guard key != syncedPositionKey else { return }
            syncedPositionKey = key

            let shape: MLNShape? = parent.positionCoordinate.map { coordinate in
                let point = MLNPointFeature()
                point.coordinate = coordinate
                return point
            }

            if let source = style.source(withIdentifier: "position") as? MLNShapeSource {
                source.shape = shape
                if let layer = style.layer(withIdentifier: "position") as? MLNCircleStyleLayer {
                    layer.circleColor = NSExpression(forConstantValue: parent.positionColor)
                }
            } else if shape != nil {
                let source = MLNShapeSource(identifier: "position", shape: shape)
                style.addSource(source)
                let layer = MLNCircleStyleLayer(identifier: "position", source: source)
                layer.circleColor = NSExpression(forConstantValue: parent.positionColor)
                layer.circleRadius = NSExpression(forConstantValue: 9)
                layer.circleStrokeColor = NSExpression(forConstantValue: UIColor.white)
                layer.circleStrokeWidth = NSExpression(forConstantValue: 3)
                style.addLayer(layer)
            }
        }

        private func frame(coordinates: [CLLocationCoordinate2D], on mapView: MLNMapView) {
            guard let first = coordinates.first else { return }
            var bounds = MLNCoordinateBounds(sw: first, ne: first)
            for coordinate in coordinates {
                bounds.sw.latitude = min(bounds.sw.latitude, coordinate.latitude)
                bounds.sw.longitude = min(bounds.sw.longitude, coordinate.longitude)
                bounds.ne.latitude = max(bounds.ne.latitude, coordinate.latitude)
                bounds.ne.longitude = max(bounds.ne.longitude, coordinate.longitude)
            }
            mapView.setVisibleCoordinateBounds(
                bounds,
                edgePadding: UIEdgeInsets(top: 80, left: 50, bottom: 80, right: 50),
                animated: false, completionHandler: nil)
        }
    }
}
