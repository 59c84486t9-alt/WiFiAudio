import Foundation
import Network
import AVFoundation
import MediaPlayer

final class AudioReceiver: ObservableObject {
    @Published var status = "Not connected"
    @Published var discovered: [String: NWEndpoint] = [:]
    @Published var connected = false
    private var browser: NWBrowser?
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "dev.wifiaudio.network")
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: false)!
    private var incoming = Data()
    private var playbackStarted = false

    init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [MPMediaItemPropertyTitle: "Windows Audio", MPMediaItemPropertyArtist: "WiFiAudio"]
        discover()
    }

    func discover() {
        browser?.cancel()
        let parameters = NWParameters.tcp
        let b = NWBrowser(for: .bonjour(type: "_wifiaudio._tcp", domain: nil), using: parameters)
        browser = b
        b.browseResultsChangedHandler = { [weak self] results, _ in
            DispatchQueue.main.async {
                self?.discovered = Dictionary(results.map { ($0.endpoint.debugDescription, $0.endpoint) }, uniquingKeysWith: { first, _ in first })
            }
        }
        b.start(queue: queue)
    }

    func connect(to endpoint: NWEndpoint) {
        disconnect()
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true)
            try engine.start()
        } catch { status = "Audio error: \(error.localizedDescription)"; return }
        let c = NWConnection(to: endpoint, using: .tcp)
        connection = c
        incoming.removeAll()
        playbackStarted = false
        status = "Connecting…"
        c.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                guard let self else { return }
                switch state {
                case .ready:
                    self.status = "Playing Windows audio"
                    self.connected = true
                case .failed(let error):
                    self.status = "Connection failed: \(error.localizedDescription)"
                    self.connected = false
                case .cancelled:
                    self.connected = false
                default: break
                }
            }
        }
        c.start(queue: queue)
        receive(c)
    }

    func connect(qr: String) {
        guard let url = URL(string: qr), url.scheme == "wifiaudio", let host = url.host,
              let portNumber = url.port, let port = NWEndpoint.Port(rawValue: UInt16(portNumber)) else {
            status = "Invalid pairing QR code"; return
        }
        connect(to: .hostPort(host: NWEndpoint.Host(host), port: port))
    }

    func disconnect() {
        connection?.cancel(); connection = nil
        player.stop(); engine.stop()
        connected = false
        status = "Not connected"
    }

    private func receive(_ c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data { self.incoming.append(data); self.parseFrames() }
            if !complete && error == nil { self.receive(c) }
        }
    }

    private func parseFrames() {
        while incoming.count >= 4 {
            let size = incoming.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            guard size > 0 && size <= 65536 && size % 4 == 0 else {
                incoming.removeAll(); connection?.cancel(); return
            }
            guard incoming.count >= Int(size) + 4 else { return }
            let payload = incoming.subdata(in: 4..<(4 + Int(size)))
            incoming.removeSubrange(0..<(4 + Int(size)))
            schedule(payload)
        }
    }

    private func schedule(_ bytes: Data) {
        let frames = bytes.count / 4
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let channels = buffer.floatChannelData else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            let pcm = base.assumingMemoryBound(to: Int16.self)
            for i in 0..<frames {
                channels[0][i] = Float(Int16(littleEndian: pcm[i * 2])) / 32768.0
                channels[1][i] = Float(Int16(littleEndian: pcm[i * 2 + 1])) / 32768.0
            }
        }
        player.scheduleBuffer(buffer)
        if !playbackStarted { player.play(); playbackStarted = true }
    }
}
