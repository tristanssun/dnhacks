import SwiftUI

@main
struct NearbyInteractionWithCustomServerApp: App {
  @StateObject var interactionManager = InteractionManager()

  var body: some Scene {
    WindowGroup {
      ContentView()
        .environmentObject(self.interactionManager)
    }
  }
}
