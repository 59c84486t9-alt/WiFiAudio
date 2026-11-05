using System.Net;
using System.Net.Sockets;
using System.Buffers.Binary;
using System.Diagnostics;
using NAudio.Wave;
using NAudio.Wave.SampleProviders;
using Makaretu.Dns;
using QRCoder;

namespace WiFiAudio.Server;

internal static class Program
{
    [STAThread]
    private static void Main() { ApplicationConfiguration.Initialize(); Application.Run(new MainForm()); }
}

public sealed class MainForm : Form
{
    private readonly Label status = new() { Dock = DockStyle.Top, Height = 42, TextAlign = ContentAlignment.MiddleCenter };
    private readonly Label latency = new() { Dock = DockStyle.Top, Height = 30, TextAlign = ContentAlignment.MiddleCenter, Text = "Latency: waiting for iPhone" };
    private readonly PictureBox qr = new() { Dock = DockStyle.Fill, SizeMode = PictureBoxSizeMode.Zoom };
    private readonly Button toggle = new() { Dock = DockStyle.Bottom, Height = 50, Text = "Start streaming server" };
    private CancellationTokenSource? cts;
    private TcpListener? listener;
    private ServiceDiscovery? discovery;
    private const int Port = 49321;

    public MainForm()
    {
        Text = "WiFiAudio • Windows sender"; Width = 380; Height = 470;
        Controls.Add(qr); Controls.Add(latency); Controls.Add(status); Controls.Add(toggle);
        toggle.Click += async (_, _) => { if (cts is null) Start(); else await StopAsync(); };
        FormClosing += (_, _) => { cts?.Cancel(); listener?.Stop(); discovery?.Dispose(); };
        status.Text = "Stopped";
    }

    private void Start()
    {
        cts = new CancellationTokenSource();
        listener = new TcpListener(IPAddress.Any, Port);
        try
        {
            listener.Start();
            discovery = new ServiceDiscovery();
            discovery.Advertise(new ServiceProfile("WiFiAudio-PC", "_wifiaudio._tcp", (ushort)Port));
            var ip = Dns.GetHostAddresses(Dns.GetHostName()).FirstOrDefault(a => a.AddressFamily == AddressFamily.InterNetwork && !IPAddress.IsLoopback(a));
            var uri = $"wifiaudio://{ip ?? IPAddress.Loopback}:{Port}";
            using var gen = new QRCodeGenerator();
            using var data = gen.CreateQrCode(uri, QRCodeGenerator.ECCLevel.Q);
            using var code = new QRCode(data);
            qr.Image = new Bitmap(code.GetGraphic(8));
            toggle.Text = "Stop"; status.Text = $"Waiting for iPhone • {uri}"; latency.Text = "Latency: waiting for iPhone";
            _ = AcceptLoop(cts.Token);
        }
        catch (Exception ex) { status.Text = ex.Message; _ = StopAsync(); }
    }

    private async Task StopAsync()
    {
        cts?.Cancel(); listener?.Stop(); discovery?.Dispose(); discovery = null;
        cts?.Dispose(); cts = null; listener = null;
        toggle.Text = "Start streaming server"; status.Text = "Stopped";
        latency.Text = "Latency: waiting for iPhone";
        qr.Image?.Dispose(); qr.Image = null;
        await Task.CompletedTask;
    }

    private void SetStatus(string value) { if (!IsDisposed && IsHandleCreated) BeginInvoke(() => status.Text = value); }
    private void SetLatency(string value, Color color)
    {
        if (!IsDisposed && IsHandleCreated) BeginInvoke(() => { latency.Text = value; latency.ForeColor = color; });
    }

    private async Task AcceptLoop(CancellationToken token)
    {
        while (!token.IsCancellationRequested)
        {
            try
            {
                using var client = await listener!.AcceptTcpClientAsync(token);
                client.NoDelay = true;
                SetStatus("iPhone connected • streaming desktop audio");
                SetLatency("Latency: measuring…", Color.Black);
                await StreamClient(client, token);
                SetStatus("Disconnected • waiting for iPhone");
            }
            catch (OperationCanceledException) { break; }
            catch (ObjectDisposedException) { break; }
            catch (Exception ex) { SetStatus($"Stream error: {ex.Message}"); await Task.Delay(1000); }
        }
    }

    private async Task StreamClient(TcpClient client, CancellationToken token)
    {
        using var capture = new WasapiLoopbackCapture();
        var buffer = new BufferedWaveProvider(capture.WaveFormat) { BufferDuration = TimeSpan.FromMilliseconds(250), DiscardOnBufferOverflow = true };
        capture.DataAvailable += (_, e) => buffer.AddSamples(e.Buffer, 0, e.BytesRecorded);
        ISampleProvider samples = buffer.ToSampleProvider();
        if (samples.WaveFormat.Channels == 1) samples = new MonoToStereoSampleProvider(samples);
        else if (samples.WaveFormat.Channels != 2) samples = new DownmixToStereoSampleProvider(samples);
        samples = new WdlResamplingSampleProvider(samples, 48000);
        var pcm = new SampleToWaveProvider16(samples);
        const int frameBytes = 1920; // 10ms, 48kHz, 2ch, 16-bit
        byte[] audioFrame = new byte[4 + frameBytes];
        byte[] length = new byte[4];
        byte[] pingTimestamp = new byte[8];
        using var stream = client.GetStream();
        var latencyMetrics = new LatencyMetrics();
        using var reportCts = CancellationTokenSource.CreateLinkedTokenSource(token);
        Task reportTask = ReadLatencyReports(stream, buffer, capture, latencyMetrics, reportCts.Token);
        capture.StartRecording();
        long lastPing = Stopwatch.GetTimestamp();
        try
        {
            while (!token.IsCancellationRequested && client.Connected)
            {
                // Wait until there is approximately one 10ms frame of source audio.
                if (buffer.BufferedBytes < capture.WaveFormat.AverageBytesPerSecond / 100)
                { await Task.Delay(5, token); continue; }

                // If capture or sending briefly falls behind, discard old audio to stay live.
                int backlogLimit = capture.WaveFormat.AverageBytesPerSecond * 6 / 100; // 60ms
                while (buffer.BufferedBytes > backlogLimit)
                {
                    int discarded = pcm.Read(audioFrame, 4, frameBytes);
                    if (discarded <= 0) break;
                }

                int read = pcm.Read(audioFrame, 4, frameBytes);
                if (read <= 0) { await Task.Delay(5, token); continue; }
                read -= read % 4;
                BinaryPrimitives.WriteInt32BigEndian(audioFrame.AsSpan(0, 4), read);
                await stream.WriteAsync(audioFrame.AsMemory(0, 4 + read), token);

                if (Stopwatch.GetElapsedTime(lastPing).TotalMilliseconds >= 1000)
                {
                    long sentAt = Stopwatch.GetTimestamp();
                    Interlocked.Exchange(ref latencyMetrics.PendingPingTimestamp, sentAt);
                    BinaryPrimitives.WriteInt32BigEndian(length, -1); // Reserved marker for a latency ping.
                    BinaryPrimitives.WriteInt64BigEndian(pingTimestamp, sentAt);
                    await stream.WriteAsync(length, token);
                    await stream.WriteAsync(pingTimestamp, token);
                    lastPing = sentAt;
                }
            }
        }
        finally
        {
            reportCts.Cancel();
            capture.StopRecording();
            try { await reportTask; }
            catch (OperationCanceledException) { }
            catch (IOException) { }
            catch (ObjectDisposedException) { }
        }
    }

    private async Task ReadLatencyReports(NetworkStream stream, BufferedWaveProvider buffer,
        WasapiLoopbackCapture capture, LatencyMetrics metrics, CancellationToken token)
    {
        byte[] report = new byte[20];
        while (!token.IsCancellationRequested)
        {
            await stream.ReadExactlyAsync(report.AsMemory(), token);
            if (BinaryPrimitives.ReadUInt32BigEndian(report.AsSpan(0, 4)) != 0x57464131) continue; // WFA1
            long echoedTimestamp = BinaryPrimitives.ReadInt64BigEndian(report.AsSpan(4, 8));
            if (echoedTimestamp != Interlocked.Read(ref metrics.PendingPingTimestamp)) continue;

            double senderBufferMs = buffer.BufferedBytes * 1000.0 / capture.WaveFormat.AverageBytesPerSecond;
            double networkMs = Stopwatch.GetElapsedTime(echoedTimestamp).TotalMilliseconds / 2.0;
            double phoneQueueMs = BinaryPrimitives.ReadUInt32BigEndian(report.AsSpan(12, 4));
            double phoneOutputMs = BinaryPrimitives.ReadUInt32BigEndian(report.AsSpan(16, 4));
            double estimateMs = senderBufferMs + networkMs + phoneQueueMs + phoneOutputMs;
            Color color = estimateMs < 80 ? Color.DarkGreen : estimateMs < 180 ? Color.DarkGoldenrod : Color.DarkRed;
            SetLatency($"Latency ~{estimateMs:0} ms  •  PC {senderBufferMs:0}  Wi-Fi {networkMs:0}  iPhone {phoneQueueMs + phoneOutputMs:0}", color);
        }
    }

    private sealed class LatencyMetrics
    {
        public long PendingPingTimestamp;
    }
}

/// <summary>Downmixes Windows' interleaved surround mix to the stereo stream expected by iOS.</summary>
internal sealed class DownmixToStereoSampleProvider : ISampleProvider
{
    private const float SurroundGain = 0.70710678f;
    private readonly ISampleProvider source;
    private readonly int inputChannels;
    private float[] input = Array.Empty<float>();

    public DownmixToStereoSampleProvider(ISampleProvider source)
    {
        this.source = source;
        inputChannels = source.WaveFormat.Channels;
        if (inputChannels < 3) throw new ArgumentException("Downmix requires at least three input channels", nameof(source));
        WaveFormat = WaveFormat.CreateIeeeFloatWaveFormat(source.WaveFormat.SampleRate, 2);
    }

    public WaveFormat WaveFormat { get; }

    public int Read(float[] destination, int offset, int count)
    {
        int outputSamples = count - count % 2;
        int framesRequested = outputSamples / 2;
        int inputSamplesRequested = framesRequested * inputChannels;
        if (input.Length < inputSamplesRequested) input = new float[inputSamplesRequested];

        int samplesRead = source.Read(input, 0, inputSamplesRequested);
        int framesRead = samplesRead / inputChannels;
        for (int frame = 0; frame < framesRead; frame++)
        {
            int sample = frame * inputChannels;
            float left = input[sample];
            float right = input[sample + 1];

            if (inputChannels == 4)
            {
                left += input[sample + 2] * SurroundGain;
                right += input[sample + 3] * SurroundGain;
            }
            else
            {
                // Standard Windows order: FL, FR, FC, [LFE], back/side left, back/side right.
                left += input[sample + 2] * SurroundGain;
                right += input[sample + 2] * SurroundGain;

                int firstSurround = inputChannels is 6 or 8 ? 4 : 3; // Skip the LFE channel in 5.1/7.1.
                for (int channel = firstSurround; channel < inputChannels; channel++)
                {
                    if (inputChannels > 8)
                    {
                        // For uncommon layouts, fold remaining channels into alternating sides.
                        if ((channel & 1) == 0) left += input[sample + channel] * 0.5f;
                        else right += input[sample + channel] * 0.5f;
                    }
                    else if ((channel & 1) == (firstSurround & 1)) left += input[sample + channel] * SurroundGain;
                    else right += input[sample + channel] * SurroundGain;
                }
            }

            destination[offset + frame * 2] = Math.Clamp(left, -1f, 1f);
            destination[offset + frame * 2 + 1] = Math.Clamp(right, -1f, 1f);
        }
        return framesRead * 2;
    }
}

