import MapLibre
import SwiftUI

struct ContentView: View {
    @AppStorage("tileSourceID") private var tileSourceID = TileSource.ignPlanV2.id

    var body: some View {
        ZStack(alignment: .topTrailing) {
            MapView(tileSource: .withID(tileSourceID))
                .ignoresSafeArea()

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
            .padding(.trailing, 12)
        }
    }
}

struct MapView: UIViewRepresentable {
    let tileSource: TileSource

    func makeUIView(context: Context) -> MLNMapView {
        let view = MLNMapView(frame: .zero)
        // Chamonix while there's no trace to frame yet.
        view.setCenter(
            CLLocationCoordinate2D(latitude: 45.9237, longitude: 6.8694),
            zoomLevel: 12, animated: false)
        apply(tileSource, to: view)
        return view
    }

    func updateUIView(_ view: MLNMapView, context: Context) {
        apply(tileSource, to: view)
    }

    private func apply(_ source: TileSource, to view: MLNMapView) {
        view.maximumZoomLevel = Double(source.maxZoom)
        guard let url = try? source.styleURL() else { return }
        if view.styleURL != url {
            view.styleURL = url
        }
    }
}
