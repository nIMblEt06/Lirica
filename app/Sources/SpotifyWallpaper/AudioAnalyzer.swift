import Accelerate
import AppKit
import CoreMedia
import ScreenCaptureKit

/// Listens to Spotify's audio (ScreenCaptureKit, so it needs Screen Recording permission) and reports beats:
/// onsets as `{strength, bpm, t, level}` the moment they're detected, and the loudness as `{level}` ~15 times a second.
/// Audio is analysed on its own queue; nothing is recorded or kept.
final class AudioAnalyzer: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    enum Failure: Error { case noDisplay }

    /// Main thread: JSON for `__sw.beat`.
    var onBeat: (@MainActor (String) -> Void)?
    /// Main thread: the system stopped the capture (Spotify quit, permission revoked, display gone).
    var onStopped: (@MainActor () -> Void)?

    private let queue = DispatchQueue(label: "Lirica audio", qos: .userInitiated)
    private var stream: SCStream?  // main thread
    // queue only
    private var detector: OnsetDetector?
    private var mono: [Float] = []
    private var lastLevel: Double = 0

    var isRunning: Bool { stream != nil }

    /// Asks for Screen Recording permission (macOS shows its prompt the first time). False until it's granted.
    static func requestAccess() async -> Bool {
        if !CGPreflightScreenCaptureAccess() { _ = CGRequestScreenCaptureAccess() }
        return (try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)) != nil
    }

    @MainActor
    func start() async throws {
        guard stream == nil else { return }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else { throw Failure.noDisplay }
        // only the player apps' sound; if none is running, everything but this app
        let players = content.applications.filter { ["com.spotify.client", "com.apple.Music"].contains($0.bundleIdentifier) }
        let filter = players.isEmpty
            ? SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
            : SCContentFilter(display: display, including: players, exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        // SCStream always captures video too: make it as cheap as possible and ignore it
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 2, timescale: 1)
        config.queueDepth = 3
        config.showsCursor = false
        let s = SCStream(filter: filter, configuration: config, delegate: self)
        try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await s.startCapture()
        stream = s
    }

    @MainActor
    func stop() {
        guard let s = stream else { return }
        stream = nil
        Task { try? await s.stopCapture() }
    }

    /// New song: forget the old tempo.
    func reset() { queue.async { self.detector?.reset() } }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard self.stream === stream else { return }
                self.stream = nil
                self.onStopped?()
            }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid, let format = sampleBuffer.formatDescription?.audioStreamBasicDescription,
              format.mFormatID == kAudioFormatLinearPCM, format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mBitsPerChannel == 32 else { return }
        let frames = sampleBuffer.numSamples
        guard frames > 0 else { return }
        let channels = Int(format.mChannelsPerFrame)
        let interleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        if mono.count < frames { mono = [Float](repeating: 0, count: frames) }
        do {
            try sampleBuffer.withAudioBufferList { list, _ in
                mono.withUnsafeMutableBufferPointer { out in
                    let dst = out.baseAddress!
                    vDSP_vclr(dst, 1, vDSP_Length(frames))
                    if interleaved, let src = list.first?.mData?.assumingMemoryBound(to: Float.self) {
                        for c in 0..<channels { vDSP_vadd(src + c, vDSP_Stride(channels), dst, 1, dst, 1, vDSP_Length(frames)) }
                    } else {
                        for buffer in list { if let src = buffer.mData?.assumingMemoryBound(to: Float.self) { vDSP_vadd(src, 1, dst, 1, dst, 1, vDSP_Length(frames)) } }
                    }
                    var scale = 1 / Float(max(1, channels))
                    vDSP_vsmul(dst, 1, &scale, dst, 1, vDSP_Length(frames))
                }
            }
        } catch { return }

        if detector?.sampleRate != format.mSampleRate { detector = OnsetDetector(sampleRate: format.mSampleRate) }
        let now = Date().timeIntervalSince1970 * 1000
        let onsets = mono.withUnsafeBufferPointer { detector!.process(UnsafeBufferPointer(rebasing: $0[0..<frames]), endTime: now) }
        let level = detector!.level
        var messages = onsets.map {
            String(format: #"{"strength":%.3f,"bpm":%.2f,"t":%.0f,"level":%.3f}"#, $0.strength, $0.bpm, $0.t, level)
        }
        if onsets.isEmpty, now - lastLevel >= 66 { messages.append(String(format: #"{"level":%.3f}"#, level)) }
        if !messages.isEmpty { lastLevel = now }
        guard !messages.isEmpty else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated { messages.forEach { self.onBeat?($0) } }
        }
    }
}

/// Spectral-flux onset detection, a tempo estimate and a smoothed loudness, on mono float samples. Pure DSP: no I/O,
/// buffers and the FFT setup are reused.
final class OnsetDetector {
    struct Onset { var strength: Double; var bpm: Double; var t: Double }

    let sampleRate: Double
    private let size = 1024, hop = 512, log2n: vDSP_Length = 10
    private let setup: FFTSetup
    private let window: [Float]
    private var pending: [Float] = []
    private var frame: [Float], real: [Float], imag: [Float], spectrum: [Float], previous: [Float], diff: [Float]
    private var frameRate: Double { sampleRate / Double(hop) }

    private var flux: [Float] = []      // recent flux, for the adaptive threshold
    private var envelope: [Float] = []  // ~8 s of onset strength above the local mean, for the tempo
    private var smoothed: [Float] = []
    private var times: [Double] = [0, 0, 0]  // times of the last three frames
    private var lastOnset = -Double.infinity
    private var peak: Float = 1e-3
    private var framesSinceTempo = 0
    private var candidate: (bpm: Double, count: Int) = (0, 0)
    private(set) var bpm: Double = 0
    private(set) var level: Double = 0

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: size, isHalfWindow: false)
        frame = [Float](repeating: 0, count: size)
        real = [Float](repeating: 0, count: size / 2)
        imag = real; spectrum = real; previous = real; diff = real
        pending.reserveCapacity(size * 8)
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    func reset() {
        envelope.removeAll(keepingCapacity: true)
        bpm = 0
        candidate = (0, 0)
    }

    /// `endTime`: ms since 1970 at the last sample. Returns the onsets found in these samples.
    func process(_ samples: UnsafeBufferPointer<Float>, endTime: Double) -> [Onset] {
        pending.append(contentsOf: samples)
        var out: [Onset] = []
        while pending.count >= size {
            let t = endTime - (Double(pending.count - size) + Double(size) / 2) / sampleRate * 1000  // frame centre
            if let o = analyse(t) { out.append(o) }
            pending.removeFirst(hop)
        }
        return out
    }

    private func analyse(_ time: Double) -> Onset? {
        // loudness of the newest hop: fast up, slow down
        let rms = pending.withUnsafeBufferPointer { vDSP.rootMeanSquare(UnsafeBufferPointer(rebasing: $0[(size - hop)..<size])) }
        let db = 20 * log10(Double(max(rms, 1e-7)))
        let target = min(1, max(0, (db + 50) / 44))
        level += (target - level) * (target > level ? 0.5 : 0.08)

        // log-magnitude spectrum, half-wave rectified flux against the previous frame
        pending.withUnsafeBufferPointer { vDSP.multiply(UnsafeBufferPointer(rebasing: $0[0..<size]), window, result: &frame) }
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                frame.withUnsafeBufferPointer {
                    $0.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: size / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(size / 2))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                ip[0] = 0  // packed Nyquist
                vDSP.squareMagnitudes(split, result: &spectrum)
            }
        }
        vForce.sqrt(spectrum, result: &spectrum)
        vDSP.multiply(100 / Float(size), spectrum, result: &spectrum)
        vForce.log1p(spectrum, result: &spectrum)
        vDSP.subtract(spectrum, previous, result: &diff)
        swap(&spectrum, &previous)
        vDSP.threshold(diff, to: 0, with: .clampToThreshold, result: &diff)
        let f = vDSP.sum(diff)

        // adaptive threshold over the last ~0.35 s
        flux.append(f)
        if flux.count > 33 { flux.removeFirst() }
        times.removeFirst(); times.append(time)
        let recent = flux.dropLast(2)
        let mean = recent.isEmpty ? f : recent.reduce(0, +) / Float(recent.count)
        let median = recent.isEmpty ? f : recent.sorted()[recent.count / 2]
        envelope.append(max(0, f - mean))
        if envelope.count > Int(8 * frameRate) { envelope.removeFirst() }
        peak = max(f, peak * 0.9995)

        framesSinceTempo += 1
        if framesSinceTempo >= Int(frameRate / 2) { framesSinceTempo = 0; estimateTempo() }

        // the frame before this one is an onset if it's a local maximum above the threshold
        guard flux.count >= 3, db > -55 else { return nil }
        let (a, b, c) = (flux[flux.count - 3], flux[flux.count - 2], flux[flux.count - 1])
        let threshold = median * 1.5 + mean * 0.5 + 1e-3
        guard b > a, b >= c, b > threshold, times[1] - lastOnset > 100 else { return nil }
        lastOnset = times[1]
        return Onset(strength: Double(min(1, b / peak)), bpm: bpm, t: times[1])
    }

    /// Autocorrelation of the onset envelope over 70–180 BPM, leaning towards ~120 when it's ambiguous, smoothed so a
    /// single odd estimate doesn't move it.
    private func estimateTempo() {
        let n = envelope.count
        guard Double(n) >= 4 * frameRate else { return }
        // widen each onset over ~50 ms so a period between two whole frames (150 BPM = 37.5) still lines up
        if smoothed.count != n { smoothed = [Float](repeating: 0, count: n) }
        for i in 0..<n {
            var s: Float = 0
            for k in -2...2 where i + k >= 0 && i + k < n { s += envelope[i + k] * Float(3 - abs(k)) }
            smoothed[i] = s / 9
        }
        let minLag = Int((60 * frameRate / 180).rounded(.down)), maxLag = Int((60 * frameRate / 70).rounded(.up))
        var acf = [Double](repeating: 0, count: 2 * maxLag + 2)
        smoothed.withUnsafeBufferPointer { e in
            var energy: Float = 0
            vDSP_dotpr(e.baseAddress!, 1, e.baseAddress!, 1, &energy, vDSP_Length(n))
            guard energy > 0 else { return }
            for lag in minLag...min(2 * maxLag + 1, n - 1) {
                var s: Float = 0
                vDSP_dotpr(e.baseAddress!, 1, e.baseAddress! + lag, 1, &s, vDSP_Length(n - lag))
                acf[lag] = Double(s) / Double(n - lag) / (Double(energy) / Double(n))
            }
        }
        func score(_ lag: Int) -> Double {
            let bpm = 60 * frameRate / Double(lag), octave = log2(bpm / 120)
            return (acf[lag] + 0.5 * acf[min(2 * lag, acf.count - 1)]) * exp(-0.5 * octave * octave)
        }
        guard let best = (minLag...maxLag).max(by: { score($0) < score($1) }), acf[best] > 0.1 else { return }
        // parabolic interpolation around the peak
        var lag = Double(best)
        if best > minLag, best < maxLag {
            let (l, m, r) = (acf[best - 1], acf[best], acf[best + 1])
            let d = l - 2 * m + r
            if d < 0 { lag += 0.5 * (l - r) / d }
        }
        let estimate = 60 * frameRate / lag
        if bpm == 0 {
            bpm = estimate
        } else if abs(estimate - bpm) / bpm < 0.06 {
            bpm += (estimate - bpm) * 0.15
            candidate = (0, 0)
        } else {
            // a new tempo has to hold for three estimates in a row
            candidate = abs(estimate - candidate.bpm) / max(1, candidate.bpm) < 0.06 ? (estimate, candidate.count + 1) : (estimate, 1)
            if candidate.count >= 3 { bpm = estimate; candidate = (0, 0) }
        }
    }
}
