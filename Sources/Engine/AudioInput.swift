import AVFoundation
import Speech

/// マイク（または音声ファイル）から音を取り込み、認識器へ流す。
/// 同じ音を16kHzで直近ぶんだけ手元に残し、聞き直し（Whisper）に使う。
final class AudioInput: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var analyzerConverter: AVAudioConverter?
    private var analyzerFormat: AVAudioFormat?
    private var ringConverter: AVAudioConverter?
    private var fileTask: Task<Void, Never>?

    private static let ringRate = 16_000.0
    private static let ringSeconds = 180.0
    private let ringFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: AudioInput.ringRate, channels: 1, interleaved: false
    )!
    private var ring: [Float] = []
    private var ringStartSample = 0   // ring[0] が録音開始から何サンプル目か

    var onFileFinished: (@Sendable () -> Void)?

    var microphoneFormat: AVAudioFormat { engine.inputNode.outputFormat(forBus: 0) }

    func startMicrophone(
        analyzerFormat: AVAudioFormat,
        continuation: AsyncStream<AnalyzerInput>.Continuation
    ) throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.mixWithOthers, .defaultToSpeaker])
        try session.setActive(true)
        #endif

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        configure(sourceFormat: format, analyzerFormat: analyzerFormat, continuation: continuation)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.consume(buffer)
        }
        engine.prepare()
        try engine.start()
    }

    /// 音声ファイルを実時間の速さで流す。録音済みの講演で試すための入口。
    func startFile(
        url: URL,
        analyzerFormat: AVAudioFormat,
        continuation: AsyncStream<AnalyzerInput>.Continuation
    ) throws {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        configure(sourceFormat: format, analyzerFormat: analyzerFormat, continuation: continuation)
        let chunk = AVAudioFrameCount(format.sampleRate / 10)
        fileTask = Task.detached { [weak self] in
            while !Task.isCancelled {
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { break }
                do { try file.read(into: buffer, frameCount: chunk) } catch { break }
                if buffer.frameLength == 0 { break }
                self?.consume(buffer)
                try? await Task.sleep(for: .milliseconds(100))
            }
            if !Task.isCancelled { self?.onFileFinished?() }
        }
    }

    func stop() {
        fileTask?.cancel()
        fileTask = nil
        if engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            #if os(iOS)
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            #endif
        }
        lock.withLock {
            continuation = nil
            analyzerConverter = nil
            ringConverter = nil
        }
    }

    /// 録音開始からの秒で区間を指定し、16kHzの音を取り出す。
    func samples(from start: Double, to end: Double) -> [Float] {
        lock.withLock {
            let first = max(Int(start * Self.ringRate) - ringStartSample, 0)
            let last = min(Int(end * Self.ringRate) - ringStartSample, ring.count)
            guard last > first else { return [] }
            return Array(ring[first..<last])
        }
    }

    private func configure(
        sourceFormat: AVAudioFormat,
        analyzerFormat: AVAudioFormat,
        continuation: AsyncStream<AnalyzerInput>.Continuation
    ) {
        lock.withLock {
            self.continuation = continuation
            self.analyzerFormat = analyzerFormat
            analyzerConverter = AVAudioConverter(from: sourceFormat, to: analyzerFormat)
            ringConverter = AVAudioConverter(from: sourceFormat, to: ringFormat)
            ring.removeAll(keepingCapacity: true)
            ringStartSample = 0
        }
    }

    private func consume(_ buffer: AVAudioPCMBuffer) {
        lock.withLock {
            guard let continuation, let analyzerConverter, let analyzerFormat else { return }
            if let converted = Self.convert(buffer, using: analyzerConverter, to: analyzerFormat) {
                continuation.yield(AnalyzerInput(buffer: converted))
            }
            if let ringConverter,
               let mono = Self.convert(buffer, using: ringConverter, to: ringFormat),
               let channel = mono.floatChannelData?[0] {
                ring.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(mono.frameLength)))
                let limit = Int(Self.ringSeconds * Self.ringRate)
                if ring.count > limit + 16_000 {
                    let drop = ring.count - limit
                    ring.removeFirst(drop)
                    ringStartSample += drop
                }
            }
        }
    }

    private static func convert(
        _ input: AVAudioPCMBuffer,
        using converter: AVAudioConverter,
        to outputFormat: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let ratio = outputFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount((Double(input.frameLength) * ratio).rounded(.up)) + 1
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return nil }
        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return input
        }
        guard status != .error, conversionError == nil, output.frameLength > 0 else { return nil }
        return output
    }
}
