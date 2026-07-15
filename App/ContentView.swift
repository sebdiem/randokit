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
    @State private var cameraCommand: MapCameraCommand?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            MapView(
                tileSource: .withID(tileSourceID),
                trace: library.active?.trace,
                traceKey: library.active?.entryID ?? "none",
                selectionCoordinates: selectionCoordinates,
                positionCoordinate: location.lastFix?.coordinate,
                positionColor: positionColor,
                cameraCommand: cameraCommand
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
            // Re-project the last fix against the new trace: with a static
            // position, Core Location won't deliver another fix, and the
            // dot/marker would stay absent until the next movement.
            handle(location.lastFix)
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

    /// Map-app-standard controls only; everything management lives in the
    /// "Mes traces" sheet.
    private var controls: some View {
        VStack(spacing: 10) {
            if location.authorization == .denied || location.authorization == .restricted {
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    controlIcon("location.slash")
                        .foregroundStyle(.red)
                }
            } else {
                Button {
                    cameraCommand = MapCameraCommand(kind: .centerOnUser)
                } label: {
                    controlIcon("location")
                }
            }

            Button {
                cameraCommand = MapCameraCommand(kind: .fitTrace)
            } label: {
                controlIcon("arrow.up.left.and.arrow.down.right")
            }

            Menu {
                Picker("Fond de carte", selection: $tileSourceID) {
                    ForEach(TileSource.all) { source in
                        Text(source.name).tag(source.id)
                    }
                }
            } label: {
                controlIcon("square.3.layers.3d")
            }

            Button {
                showsTracePicker = true
            } label: {
                controlIcon("folder")
            }
        }
    }

    private func controlIcon(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 18, weight: .medium))
            .frame(width: 44, height: 44)
            .background(.regularMaterial, in: Circle())
    }

    /// "Mes traces": selection, import, per-trace offline download, deletion.
    private var tracePicker: some View {
        NavigationStack {
            List {
                if library.isImporting {
                    Section {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("Import et correction des altitudes…")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if let progress = downloader.progress {
                    Section {
                        ProgressView(value: progress) {
                            Text("Téléchargement des fonds de carte… \(Int(progress * 100)) %")
                                .font(.footnote)
                        }
                    }
                } else if let result = downloader.lastResult {
                    Section {
                        Text(result)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    ForEach(library.entries) { entry in
                        Button {
                            library.select(entry)
                            showsTracePicker = false
                        } label: {
                            HStack {
                                Text(entry.name)
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Spacer()
                                if entry.id == library.active?.entryID {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                }
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if entry.url != nil {
                                Button(role: .destructive) {
                                    library.delete(entry)
                                } label: {
                                    Label("Supprimer", systemImage: "trash")
                                }
                            }
                            Button {
                                downloadTiles(for: entry)
                            } label: {
                                Label("Hors-ligne", systemImage: "arrow.down.circle")
                            }
                            .tint(.blue)
                        }
                    }
                } footer: {
                    Text("Balayez une trace pour télécharger ses fonds de carte ou la supprimer.")
                }
            }
            .navigationTitle("Mes traces")
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
        .presentationDetents([.medium, .large])
    }

    private func downloadTiles(for entry: TraceLibrary.Entry) {
        Task {
            if let trace = await library.loadTrace(for: entry) {
                await downloader.download(trace: trace, source: .withID(tileSourceID))
            }
        }
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

struct MapCameraCommand: Equatable {
    enum Kind {
        case centerOnUser
        case fitTrace
    }

    let kind: Kind
    let token = UUID()
}

struct MapView: UIViewRepresentable {
    let tileSource: TileSource
    let trace: GPXTrace?
    let traceKey: String
    let selectionCoordinates: [CLLocationCoordinate2D]
    let positionCoordinate: CLLocationCoordinate2D?
    let positionColor: UIColor
    let cameraCommand: MapCameraCommand?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> MLNMapView {
        let view = MLNMapView(frame: .zero)
        view.delegate = context.coordinator
        // Top-left, where no overlay control will ever cover it (the button
        // stack lives top-right).
        view.compassViewPosition = .topLeft
        view.compassViewMargins = CGPoint(x: 12, y: 12)
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
        context.coordinator.handleCameraCommand(on: view)
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
        private var handledCameraToken: UUID?

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

        func handleCameraCommand(on mapView: MLNMapView) {
            guard let command = parent.cameraCommand, command.token != handledCameraToken
            else { return }
            handledCameraToken = command.token
            switch command.kind {
            case .centerOnUser:
                if let coordinate = parent.positionCoordinate {
                    mapView.setCenter(
                        coordinate, zoomLevel: max(mapView.zoomLevel, 14), animated: true)
                }
            case .fitTrace:
                if let points = parent.trace?.points, !points.isEmpty {
                    frame(
                        coordinates: points.map {
                            CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
                        }, on: mapView, animated: true)
                }
            }
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

            syncEndpointMarkers(style: style, hidden: shape == nil)

            if framedTraceKey != parent.traceKey, let points = trace?.points, !points.isEmpty {
                framedTraceKey = parent.traceKey
                frame(
                    coordinates: points.map {
                        CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
                    }, on: mapView)
            }

            raisePositionLayer(in: style)
        }

        /// The GPS dot must stay topmost. Trace activation is async, so its
        /// layers can be created AFTER the position layer — re-raise it
        /// whenever other layers may have been added above.
        private func raisePositionLayer(in style: MLNStyle) {
            guard let layer = style.layer(withIdentifier: "position") else { return }
            style.removeLayer(layer)
            style.addLayer(layer)
        }

        /// Start = green flag, finish = checkered flag — distinct from the
        /// round GPS dot. A loop (start ≈ finish) shows a single checkered
        /// flag instead of two markers overlapping at the same point.
        private func syncEndpointMarkers(style: MLNStyle, hidden: Bool) {
            var startShape: MLNShape?
            var finishShape: MLNShape?
            if !hidden, let first = parent.trace?.points.first, let last = parent.trace?.points.last {
                let isLoop = Geo.distanceMeters(from: first, to: last) < 150
                let finishPoint = MLNPointFeature()
                finishPoint.coordinate = CLLocationCoordinate2D(
                    latitude: last.latitude, longitude: last.longitude)
                finishShape = finishPoint
                if !isLoop {
                    let startPoint = MLNPointFeature()
                    startPoint.coordinate = CLLocationCoordinate2D(
                        latitude: first.latitude, longitude: first.longitude)
                    startShape = startPoint
                }
            }
            syncMarker(
                id: "trace-start", shape: startShape, symbol: "flag.fill",
                colors: [.systemGreen], style: style)
            syncMarker(
                id: "trace-end", shape: finishShape, symbol: "flag.checkered",
                colors: [.black, .white], style: style)
        }

        private func syncMarker(
            id: String, shape: MLNShape?, symbol: String, colors: [UIColor], style: MLNStyle
        ) {
            if let source = style.source(withIdentifier: id) as? MLNShapeSource {
                source.shape = shape
            } else if shape != nil {
                if let image = Self.badgeImage(symbol: symbol, colors: colors) {
                    style.setImage(image, forName: "\(id)-icon")
                }
                let source = MLNShapeSource(identifier: id, shape: shape)
                style.addSource(source)
                let layer = MLNSymbolStyleLayer(identifier: id, source: source)
                layer.iconImageName = NSExpression(forConstantValue: "\(id)-icon")
                layer.iconAllowsOverlap = NSExpression(forConstantValue: true)
                style.addLayer(layer)
            }
        }

        /// SF symbol rasterized onto a white round badge. Drawing into a
        /// bitmap guarantees real pixels — template/palette symbols passed
        /// straight to MapLibre render as black silhouettes.
        private static func badgeImage(symbol: String, colors: [UIColor]) -> UIImage? {
            let configuration = UIImage.SymbolConfiguration(pointSize: 13, weight: .bold)
                .applying(UIImage.SymbolConfiguration(paletteColors: colors))
            guard let glyph = UIImage(systemName: symbol, withConfiguration: configuration) else {
                return nil
            }
            let diameter: CGFloat = 26
            let size = CGSize(width: diameter, height: diameter)
            return UIGraphicsImageRenderer(size: size).image { context in
                let circle = CGRect(origin: .zero, size: size)
                UIColor.white.setFill()
                context.cgContext.fillEllipse(in: circle.insetBy(dx: 1, dy: 1))
                UIColor.systemGray3.setStroke()
                context.cgContext.setLineWidth(1)
                context.cgContext.strokeEllipse(in: circle.insetBy(dx: 1.5, dy: 1.5))
                glyph.draw(
                    in: CGRect(
                        x: (diameter - glyph.size.width) / 2,
                        y: (diameter - glyph.size.height) / 2,
                        width: glyph.size.width, height: glyph.size.height))
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
                raisePositionLayer(in: style)
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

        private func frame(
            coordinates: [CLLocationCoordinate2D], on mapView: MLNMapView, animated: Bool = false
        ) {
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
                animated: animated, completionHandler: nil)
        }
    }
}
