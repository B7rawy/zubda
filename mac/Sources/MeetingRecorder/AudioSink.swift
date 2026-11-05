import AVFoundation

/// Writes one track to disk as mono AAC in a CAF file. CAF stays readable if the app dies
/// mid-meeting, unlike an M4A whose index is only written on close.
final class AudioSink {
    private var file: AVAudioFile?
    private let format: AVAudioFormat
    private var converter: AVAudioConverter?
    private var converterInput: AVAudioFormat?
    private let lock = NSLock()
    private var isMuted = false
    /// Samples left over when a buffer isn't a multiple of three, so no time is lost.
    private var carry: [Float] = []

    /// Called with an RMS level between 0 and 1 for every buffer written.
    var onLevel: ((Float) -> Void)?
    /// Called with the same audio at 16 kHz, the rate Whisper uses, for live transcription.
    var onSamples16k: (([Int16]) -> Void)?

    init(url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        self.file = file
        format = file.processingFormat
    }

    /// A muted sink keeps writing silence, so every track stays on the same timeline.
    var muted: Bool {
        get { lock.withLock { isMuted } }
        set { lock.withLock { isMuted = newValue } }
    }

    func write(_ input: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard let file, let buffer = convert(input), buffer.frameLength > 0 else { return }
        let samples = buffer.floatChannelData![0]
        let count = Int(buffer.frameLength)
        if isMuted {
            samples.update(repeating: 0, count: count)
        }
        var sum: Float = 0
        for i in 0..<count { sum += samples[i] * samples[i] }
        try? file.write(from: buffer)
        onLevel?(min(1, sqrt(sum / Float(count)) * 4))
        if let onSamples16k {
            // 48 kHz to 16 kHz: averaging each group of three samples also filters out what
            // would otherwise alias, which is plenty for speech.
            let source = carry + UnsafeBufferPointer(start: samples, count: count)
            var out = [Int16](repeating: 0, count: source.count / 3)
            for i in 0..<out.count {
                let mean = (source[i * 3] + source[i * 3 + 1] + source[i * 3 + 2]) / 3
                out[i] = Int16(max(-1, min(1, mean)) * 32767)
            }
            carry = Array(source[(out.count * 3)...])
            onSamples16k(out)
        }
    }

    func close() {
        lock.withLock { file = nil }
    }

    private func convert(_ input: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if input.format == format { return input }
        if converter == nil || converterInput != input.format {
            converter = AVAudioConverter(from: input.format, to: format)
            converter?.downmix = true
            converterInput = input.format
        }
        guard let converter else { return nil }
        let ratio = format.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var fed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if fed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            inputStatus.pointee = .haveData
            return input
        }
        return status == .error ? nil : output
    }
}
