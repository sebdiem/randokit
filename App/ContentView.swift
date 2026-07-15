import MapLibre
import RandoKit
import SwiftUI

struct ContentView: View {
    @AppStorage("tileSourceID") private var tileSourceID = TileSource.ignPlanV2.id
    @State private var selectedKmRange: ClosedRange<Double>?
    @StateObject private var downloader = CorridorDownloader()
    private let trace = SampleTrace.trace
    private let linearized = SampleTrace.trace.map { LinearizedTrace(trackPoints: $0.points) }

    private var selectionCoordinates: [CLLocationCoordinate2D] {
        guard let trace, let linearized, let kmRange = selectedKmRange else { return [] }
        let meters = (kmRange.lowerBound * 1000)...(kmRange.upperBound * 1000)
        return zip(trace.points, linearized.points)
            .filter { meters.contains($0.1.distance) }
            .map { CLLocationCoordinate2D(latitude: $0.0.latitude, longitude: $0.0.longitude) }
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            MapView(
                tileSource: .withID(tileSourceID), trace: trace,
                selectionCoordinates: selectionCoordinates
            )
            .ignoresSafeArea()

            VStack(spacing: 10) {
                Menu {
                    Picker("Fond de carte", selection: $tileSourceID) {
                        ForEach(TileSource.all) { source in
                            Text(source.name).tag(source.id)
                        }
                    }
                } label: {
                    Image(systemName: "map")
                        .font(.system(size: 18, weight: .medium))
                        .padding(11)
                        .background(.regularMaterial, in: Circle())
                }

                if let progress = downloader.progress {
                    Text("\(Int(progress * 100)) %")
                        .font(.footnote.monospacedDigit().weight(.semibold))
                        .padding(8)
                        .background(.regularMaterial, in: Capsule())
                } else if let trace {
                    Button {
                        Task {
                            await downloader.download(
                                points: trace.points, source: .withID(tileSourceID))
                        }
                    } label: {
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 18, weight: .medium))
                            .padding(11)
                            .background(.regularMaterial, in: Circle())
                    }
                }
            }
            .padding(.trailing, 12)
        }
        .overlay(alignment: .bottom) {
            if let linearized {
                ElevationProfileView(
                    name: trace?.name, linearized: linearized,
                    selectedKmRange: $selectedKmRange
                )
                .frame(height: 200)
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
            }
        }
        .onAppear(perform: applyPresetSelection)
    }

    private func applyPresetSelection() {
        #if DEBUG
            // Headless UI verification: SIMCTL_CHILD_PRESET_SELECTION="0.8-1.8" (km).
            if let preset = ProcessInfo.processInfo.environment["PRESET_SELECTION"] {
                let parts = preset.split(separator: "-").compactMap { Double($0) }
                if parts.count == 2, parts[0] < parts[1] {
                    selectedKmRange = parts[0]...parts[1]
                }
            }
            // Headless verification: start the corridor download at launch.
            if ProcessInfo.processInfo.environment["AUTO_DOWNLOAD"] == "1", let trace {
                Task {
                    await downloader.download(points: trace.points, source: .withID(tileSourceID))
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
    let selectionCoordinates: [CLLocationCoordinate2D]

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
        context.coordinator.syncSelection(on: view)
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
        private var hasFramedTrace = false

        init(_ parent: MapView) {
            self.parent = parent
        }

        // Fires after every style load, including basemap switches (which wipe
        // all runtime layers) — so the trace is (re)added here and nowhere else.
        func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
            addTraceLayers(to: style)
            frameTrace(on: mapView)
            syncSelection(on: mapView)
        }

        /// Keeps the orange "measured segment" overlay in sync with the profile
        /// selection. The source is created once and its shape updated in place.
        func syncSelection(on mapView: MLNMapView) {
            guard let style = mapView.style else { return }
            let coordinates = parent.selectionCoordinates

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

        private func addTraceLayers(to style: MLNStyle) {
            guard let points = parent.trace?.points, points.count >= 2 else { return }
            let coordinates = points.map {
                CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
            }

            let line = MLNPolylineFeature(coordinates: coordinates, count: UInt(coordinates.count))
            let traceSource = MLNShapeSource(identifier: "trace", shape: line)
            style.addSource(traceSource)

            let casing = MLNLineStyleLayer(identifier: "trace-casing", source: traceSource)
            casing.lineColor = NSExpression(forConstantValue: UIColor.white)
            casing.lineWidth = NSExpression(forConstantValue: 7)
            casing.lineCap = NSExpression(forConstantValue: "round")
            casing.lineJoin = NSExpression(forConstantValue: "round")
            style.addLayer(casing)

            let stroke = MLNLineStyleLayer(identifier: "trace-line", source: traceSource)
            stroke.lineColor = NSExpression(
                forConstantValue: UIColor(red: 0.56, green: 0.14, blue: 0.67, alpha: 1))
            stroke.lineWidth = NSExpression(forConstantValue: 4)
            stroke.lineCap = NSExpression(forConstantValue: "round")
            stroke.lineJoin = NSExpression(forConstantValue: "round")
            style.addLayer(stroke)

            addEndpoint(coordinates.first!, id: "trace-start", color: .systemGreen, to: style)
            addEndpoint(coordinates.last!, id: "trace-end", color: .systemRed, to: style)
        }

        private func addEndpoint(
            _ coordinate: CLLocationCoordinate2D, id: String, color: UIColor, to style: MLNStyle
        ) {
            let point = MLNPointFeature()
            point.coordinate = coordinate
            let source = MLNShapeSource(identifier: id, shape: point)
            style.addSource(source)
            let circle = MLNCircleStyleLayer(identifier: id, source: source)
            circle.circleColor = NSExpression(forConstantValue: color)
            circle.circleRadius = NSExpression(forConstantValue: 7)
            circle.circleStrokeColor = NSExpression(forConstantValue: UIColor.white)
            circle.circleStrokeWidth = NSExpression(forConstantValue: 2.5)
            style.addLayer(circle)
        }

        private func frameTrace(on mapView: MLNMapView) {
            guard !hasFramedTrace, let points = parent.trace?.points, !points.isEmpty else { return }
            hasFramedTrace = true
            var bounds = MLNCoordinateBounds(
                sw: CLLocationCoordinate2D(latitude: points[0].latitude, longitude: points[0].longitude),
                ne: CLLocationCoordinate2D(latitude: points[0].latitude, longitude: points[0].longitude))
            for p in points {
                bounds.sw.latitude = min(bounds.sw.latitude, p.latitude)
                bounds.sw.longitude = min(bounds.sw.longitude, p.longitude)
                bounds.ne.latitude = max(bounds.ne.latitude, p.latitude)
                bounds.ne.longitude = max(bounds.ne.longitude, p.longitude)
            }
            mapView.setVisibleCoordinateBounds(
                bounds,
                edgePadding: UIEdgeInsets(top: 80, left: 50, bottom: 80, right: 50),
                animated: false, completionHandler: nil)
        }
    }
}
