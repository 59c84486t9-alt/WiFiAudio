import SwiftUI
import Network
import AVFoundation

struct ContentView: View {
    @EnvironmentObject var receiver: AudioReceiver
    @State private var showingScanner = false
    @State private var manualAddress = ""
    var body: some View {
        NavigationStack {
            Form {
                Section("Connection") {
                    Label(receiver.status, systemImage: receiver.connected ? "waveform" : "wifi")
                    if receiver.connected { Button("Disconnect", role: .destructive) { receiver.disconnect() } }
                    Button("Scan Windows pairing QR") { showingScanner = true }
                }
                Section("Nearby Windows computers") {
                    if receiver.discovered.isEmpty { Text("Searching on local Wi-Fi…").foregroundStyle(.secondary) }
                    ForEach(receiver.discovered.keys.sorted(), id: \.self) { key in
                        Button(key) { if let endpoint = receiver.discovered[key] { receiver.connect(to: endpoint) } }
                    }
                    Button("Refresh discovery") { receiver.discover() }
                }
                Section("Manual pairing") {
                    TextField("PC IP address, e.g. 192.168.1.10", text: $manualAddress)
                        .textInputAutocapitalization(.never).keyboardType(.numbersAndPunctuation)
                    Button("Connect to IP") { receiver.connect(qr: "wifiaudio://\(manualAddress):49321") }
                }
                Section { Text("Streams your Windows system output over Wi-Fi. Keep this app installed and enable local network access. Audio continues with the screen locked while iOS permits the active playback session.").font(.footnote).foregroundStyle(.secondary) }
            }
            .navigationTitle("WiFiAudio")
            .sheet(isPresented: $showingScanner) {
                QRScanner { code in showingScanner = false; receiver.connect(qr: code) }
            }
        }
    }
}

struct QRScanner: UIViewControllerRepresentable {
    let onCode: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }
    func makeUIViewController(context: Context) -> UIViewController {
        let vc = UIViewController()
        let session = AVCaptureSession()
        guard let camera = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: camera), session.canAddInput(input) else { return vc }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return vc }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(context.coordinator, queue: .main)
        output.metadataObjectTypes = [.qr]
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = UIScreen.main.bounds
        vc.view.layer.addSublayer(preview)
        context.coordinator.session = session
        DispatchQueue.global(qos: .userInitiated).async { session.startRunning() }
        return vc
    }
    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
    static func dismantleUIViewController(_ uiViewController: UIViewController, coordinator: Coordinator) {
        coordinator.session?.stopRunning()
    }
    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        let onCode: (String) -> Void
        var session: AVCaptureSession?
        private var scanned = false
        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }
        func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
            guard !scanned, let value = (metadataObjects.first as? AVMetadataMachineReadableCodeObject)?.stringValue else { return }
            scanned = true; onCode(value)
        }
    }
}
