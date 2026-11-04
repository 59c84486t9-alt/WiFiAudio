import SwiftUI

@main struct WiFiAudioApp: App {
    @StateObject private var receiver = AudioReceiver()
    var body: some Scene { WindowGroup { ContentView().environmentObject(receiver) } }
}
