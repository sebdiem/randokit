import MapLibre
import SwiftUI

struct ContentView: View {
    var body: some View {
        MapView()
            .ignoresSafeArea()
    }
}

/// Minimal MapLibre wrapper proving the rendering pipeline; the real tile-source
/// plumbing (IGN/OpenTopoMap, offline store) replaces the demo style later.
struct MapView: UIViewRepresentable {
    func makeUIView(context: Context) -> MLNMapView {
        let view = MLNMapView(
            frame: .zero,
            styleURL: URL(string: "https://demotiles.maplibre.org/style.json"))
        view.setCenter(
            CLLocationCoordinate2D(latitude: 45.05, longitude: 6.3),
            zoomLevel: 5, animated: false)
        return view
    }

    func updateUIView(_ uiView: MLNMapView, context: Context) {}
}
