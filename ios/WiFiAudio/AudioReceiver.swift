import Foundation
import Network
import AVFoundation
import MediaPlayer
import UIKit

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
    private let playbackQueueLock = NSLock()
    private var queuedPlaybackFrames = 0
    private var playbackGeneration: UInt64 = 0
    // Allow short Wi-Fi/TCP delivery bursts without repeatedly stopping playback.
    // Overflow still drops stale audio to recover toward live playback.
    private let maxQueuedPlaybackFrames = 5760 // 120ms at 48kHz
    private var audioSessionObservers: [NSObjectProtocol] = []

    init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [MPMediaItemPropertyTitle: "Windows Audio", MPMediaItemPropertyArtist: "WiFiAudio"]
        observeAudioSessionLifecycle()
        discover()
    }

    deinit {
        audioSessionObservers.forEach(NotificationCenter.default.removeObserver)
    }

    private func observeAudioSessionLifecycle() {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        let backgroundToken = center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { [weak self] _ in
            guard let self else { return }
            self.queue.async { [weak self] in self?.reactivateAudioSessionIfNeeded() }
        }
        let interruptionToken = center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: nil) { [weak self] notification in
            guard let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: rawType) == .ended,
                  let self else { return }
            self.queue.async { [weak self] in self?.reactivateAudioSessionIfNeeded() }
        }
        audioSessionObservers = [backgroundToken, interruptionToken]
    }

    private func reactivateAudioSessionIfNeeded() {
        guard connected else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setActive(true)
            if !engine.isRunning { try engine.start() }
            if !player.isPlaying { player.play() }
            playbackStarted = true
        } catch {
            DispatchQueue.main.async { self.status = "Audio resume error: \(error.localizedDescription)" }
        }
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
        playbackQueueLock.lock()
        playbackGeneration &+= 1
        queuedPlaybackFrames = 0
        playbackQueueLock.unlock()
        connection?.cancel(); connection = nil
        player.stop(); engine.stop()
        playbackStarted = false
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
            if size == UInt32.max {
                guard incoming.count >= 12 else { return }
                let token = incoming[4..<12].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
                incoming.removeSubrange(0..<12)
                sendLatencyReport(echoing: token)
                continue
            }
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
        playbackQueueLock.lock()
        let shouldDropBacklog = queuedPlaybackFrames + frames > maxQueuedPlaybackFrames
        if shouldDropBacklog {
            queuedPlaybackFrames = 0
            playbackGeneration &+= 1
        }
        let generation = playbackGeneration
        queuedPlaybackFrames += frames
        playbackQueueLock.unlock()

        if shouldDropBacklog {
            // Keep playback close to live audio instead of draining a stale queue.
            player.stop()
            playbackStarted = false
        }
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            guard let self else { return }
            self.playbackQueueLock.lock()
            if self.playbackGeneration == generation {
                self.queuedPlaybackFrames = max(0, self.queuedPlaybackFrames - frames)
            }
            self.playbackQueueLock.unlock()
        }
        if !playbackStarted { player.play(); playbackStarted = true }
    }

    private func sendLatencyReport(echoing token: UInt64) {
        guard let connection else { return }
        playbackQueueLock.lock()
        let queuedFrames = queuedPlaybackFrames
        playbackQueueLock.unlock()

        let session = AVAudioSession.sharedInstance()
        let phoneQueueMs = UInt32(max(0, min(10_000, queuedFrames * 1000 / 48_000)))
        let outputLatencyMs = UInt32(max(0, min(10_000, Int((session.outputLatency + session.ioBufferDuration) * 1000))))
        var report = Data()
        appendBigEndian(UInt32(0x57464131), to: &report) // WFA1
        appendBigEndian(token, to: &report)
        appendBigEndian(phoneQueueMs, to: &report)
        appendBigEndian(outputLatencyMs, to: &report)
        connection.send(content: report, completion: .contentProcessed { [weak self] error in
            guard let error else { return }
            DispatchQueue.main.async { self?.status = "Latency report error: \(error.localizedDescription)" }
        })
    }

    private func appendBigEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }
}

