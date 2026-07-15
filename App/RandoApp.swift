import MapLibre
import SwiftUI

@main
struct RandoApp: App {
    init() {
        // Identify ourselves politely to tile servers (OpenTopoMap policy), and
        // route rando-tile:// requests through the offline read-through cache.
        let configuration = URLSessionConfiguration.default
        configuration.httpAdditionalHeaders = ["User-Agent": "Rando/0.1 (personal hiking app)"]
        configuration.protocolClasses = [TileURLProtocol.self]
        MLNNetworkConfiguration.sharedManager.sessionConfiguration = configuration
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
