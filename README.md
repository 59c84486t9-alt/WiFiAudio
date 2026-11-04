# WiFiAudio — Windows audio on your iPhone

Experimental native Windows sender + native iOS receiver. This is **not** an Apple AirPlay protocol implementation: it offers a similar Wi-Fi receiver experience.

## First version
- Windows: .NET 8 WinForms, NAudio WASAPI loopback, 48 kHz stereo 16-bit PCM over TCP port **49321**.
- iOS: SwiftUI, Network.framework Bonjour discovery, QR scan, AVAudioEngine playback, `audio` background mode.
- Discovery: Bonjour `_wifiaudio._tcp` and manual IP/QR fallback.
- CI: GitHub Actions generates an **unsigned** IPA and publishes a standalone Windows build.

## Build / install
1. Push this repository to GitHub; Actions → **iOS IPA** and **Windows Sender**.
2. Download the Windows artifact and run the executable on your Windows computer. Allow inbound TCP **49321** on your *private* Windows network firewall profile.
3. Download the unsigned IPA and **sign it with a compatible iOS signing/sideloading method** before installation. It will not install directly on a stock iPhone.
4. Put PC and iPhone on the same Wi-Fi/LAN. Start the sender, then select the discovered PC or scan its QR code. Manual IP is also available.

## Known limitations / engineering follow-ups
- Both GitHub Actions builds have passed; end-to-end audio still needs testing on a Windows PC and iPhone.
- Unencrypted and unauthenticated PCM stream: **trusted home LAN only**, not exposed to the Internet. QR contains a connection address, not a secure pairing credential.
- Only one receiver at a time; TCP can introduce noticeable latency and backlog.
- Audio capture follows the Windows default output device and downmixes surround output to stereo; per-application selection is not available.
- Windows mDNS/Bonjour discovery may depend on firewall/network configuration; manual IP is the fallback.
- iOS lock-screen playback uses `.playback` audio session and `UIBackgroundModes=audio`; iOS may suspend/restrict playback after interruption or when playback is no longer active.
- No Windows virtual audio output device, no AirPlay protocol compatibility, no Opus/WebRTC yet.
- Next: test device build, ring-buffer/latency control, secure pairing and TLS, reconnect, Opus, playback controls, Windows device selector.
