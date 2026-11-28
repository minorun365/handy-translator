import AVFoundation
import CoreMedia
import CryptoKit
import Foundation
import Speech
import SwiftUI
import Translation
#if os(iOS)
import UIKit
#endif

extension AttributedString {
    var audioStartSeconds: Double? {
        for run in runs {
            if let range = run.audioTimeRange { return CMTimeGetSeconds(range.start) }
        }
        return nil
    }

    var audioEndSeconds: Double? {
        var end: Double?
        for run in runs {
            if let range = run.audioTimeRange { end = CMTimeGetSeconds(range.end) }
        }
        return end
    }
}

@MainActor
final class AppModel: ObservableObject {
    // 画面に出すもの
    @Published private(set) var isRecording = false
    @Published private(set) var isPreparing = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var lines: [CaptionLine] = []
    @Published private(set) var liveEnglish = ""
    @Published private(set) var liveJapanese = ""
    @Published private(set) var summary = SummaryCard(id: UUID(), at: Date(), overview: "", points: [])
    @Published private(set) var cards: [SummaryCard] = []
    @Published private(set) var engine: Engine = .none
    @Published private(set) var notice = ""
    @Published private(set) var metrics: [MetricSample] = []
    @Published private(set) var whisperState = ""
    @Published private(set) var timings: [String: Double] = [:]
    @Published private(set) var sessions: [SessionEntry] = []
    @Published private(set) var uploadNotice = ""
    @Published private(set) var isUploading = false

    // 設定
    @AppStorage("useCloud") var useCloud = true
    @AppStorage("useWhisper") var useWhisper = false
    @AppStorage("region") var region = "ap-northeast-1"
    @AppStorage("modelID") var modelID = "global.anthropic.claude-haiku-5-5"
    @AppStorage("vocabulary") var vocabulary = Vocabulary.defaults
    @AppStorage("showEnglish") var showEnglish = false
    @AppStorage("whisperModel") var whisperModel = WhisperEngine.models[0].name
    @AppStorage("localRefine") var localRefine = false
    @AppStorage("s3Bucket") var s3Bucket = ""
    @AppStorage("s3Region") var s3Region = "ap-northeast-1"

    var hasAPIKey: Bool { !apiKey.isEmpty }
    var hasS3Key: Bool { !s3Credentials.isEmpty }
    var pendingUploads: Int { sessions.filter { !$0.uploaded }.count }

    private var apiKey = KeyStore.load()
    private var s3Credentials = KeyStore.load(KeyStore.s3)
    private let audio = AudioInput()
    private let local = LocalLanguageModel()
    private let whisper = WhisperEngine()

    private var analyzer: SpeechAnalyzer?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var tasks: [Task<Void, Never>] = []
    private var startedAt = Date()
    private var cloudDownUntil = Date.distantPast
    private var lastSummarySource = ""
    private var lastCardAt = Date()
    private var liveRevision = 0
    private var refineInFlight = false
    private var timingSums: [String: (total: Double, count: Int)] = [:]
    private var problems: [String] = []

    // 翻訳の作業列。翻訳セッションは画面側から渡される。
    private enum TranslationWork {
        case live(text: String, revision: Int)
        case final(id: UUID)
    }
    private var translationContinuation: AsyncStream<TranslationWork>.Continuation?
    private lazy var translationStream: AsyncStream<TranslationWork> = {
        AsyncStream(bufferingPolicy: .bufferingNewest(64)) { self.translationContinuation = $0 }
    }()

    init() {
        #if os(iOS)
        UIDevice.current.isBatteryMonitoringEnabled = true
        #endif
        applyBundledPreset()
        applyLaunchOverrides()
        sessions = SessionStore.list()
        Task { await uploadPending() }
    }

    // MARK: - 設定

    func setAPIKey(_ value: String) {
        KeyStore.save(value)
        apiKey = KeyStore.load()
        cloudDownUntil = .distantPast
        refreshEngine()
    }

    func setS3Key(_ value: String) {
        KeyStore.save(value, account: KeyStore.s3)
        s3Credentials = KeyStore.load(KeyStore.s3)
        Task { await uploadPending() }
    }

    /// 自分用のビルド：Sources/Preset.plist（git 管理外）を同梱すると、起動時に設定へ入れる。
    /// 同じ内容は一度だけ入れ、Preset.plist の中身が変わったときだけ入れ直す。
    private func applyBundledPreset() {
        guard let url = Bundle.main.url(forResource: "Preset", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let preset = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String]
        else { return }
        let fingerprint = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: "presetApplied") != fingerprint else { return }
        if let key = preset["BedrockAPIKey"], !key.isEmpty { setAPIKey(key) }
        if let value = preset["Region"], !value.isEmpty { region = value }
        if let key = preset["S3Credentials"], !key.isEmpty { setS3Key(key) }
        if let value = preset["S3Bucket"], !value.isEmpty { s3Bucket = value }
        if let value = preset["S3Region"], !value.isEmpty { s3Region = value }
        defaults.set(fingerprint, forKey: "presetApplied")
    }

    /// 検証用：起動時の環境変数でキーと入力ファイルを渡せる。
    private func applyLaunchOverrides() {
        let environment = ProcessInfo.processInfo.environment
        if let key = environment["HANDY_API_KEY"], !key.isEmpty { apiKey = key }
        if let key = environment["HANDY_S3_KEY"], !key.isEmpty { s3Credentials = key }
        if let bucket = environment["HANDY_S3_BUCKET"], !bucket.isEmpty { s3Bucket = bucket }
        if environment["HANDY_WHISPER"] == "1" { useWhisper = true }
        if environment["HANDY_WHISPER"] == "0" { useWhisper = false }
        if let name = environment["HANDY_WHISPER_MODEL"], !name.isEmpty { whisperModel = name }
        if let flag = environment["HANDY_LOCAL_REFINE"] { localRefine = flag == "1" }
        if environment["HANDY_CLOUD"] == "0" { useCloud = false }
        if environment["HANDY_CLOUD"] == "1" { useCloud = true }
        if let replay = environment["HANDY_REPLAY"], !replay.isEmpty {
            loadReplay(URL(fileURLWithPath: replay))
        }
        if let file = environment["HANDY_AUDIO_FILE"], !file.isEmpty {
            Task { await start(fileURL: URL(fileURLWithPath: file)) }
        }
    }

    private func refreshEngine() {
        if useCloud, hasAPIKey, Date() >= cloudDownUntil {
            engine = .cloud
        } else if local.unavailableReason == nil {
            engine = .local
        } else {
            engine = .none
        }
    }

    func toggleCloud() {
        useCloud.toggle()
        cloudDownUntil = .distantPast
        refreshEngine()
    }

    // MARK: - 開始と停止

    func start(fileURL: URL? = nil) async {
        guard !isRecording, !isPreparing else { return }
        isPreparing = true
        notice = ""
        defer { isPreparing = false }

        do {
            if fileURL == nil {
                guard await AVAudioApplication.requestRecordPermission() else {
                    notice = "設定アプリでマイクの使用を許可してください"
                    return
                }
            }
            guard SpeechTranscriber.isAvailable else {
                notice = "この端末では端末内の音声認識を使えません"
                return
            }
            guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US")) else {
                notice = "英語の音声認識に対応していません"
                return
            }
            let transcriber = SpeechTranscriber(
                locale: locale,
                transcriptionOptions: [],
                reportingOptions: [.volatileResults],
                attributeOptions: [.audioTimeRange]
            )
            let modules: [any SpeechModule] = [transcriber]
            if await AssetInventory.status(forModules: modules) != .installed {
                notice = "英語の音声認識モデルを取得中"
                if let request = try await AssetInventory.assetInstallationRequest(supporting: modules) {
                    try await request.downloadAndInstall()
                }
                notice = ""
            }

            let sourceFormat: AVAudioFormat? = fileURL == nil ? audio.microphoneFormat : nil
            guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
                compatibleWith: modules,
                considering: sourceFormat
            ) else {
                notice = "音声の形式を決められません"
                return
            }
            let analyzer = SpeechAnalyzer(
                modules: modules,
                options: .init(priority: .userInitiated, modelRetention: .processLifetime)
            )
            try await analyzer.prepareToAnalyze(in: analyzerFormat)
            self.analyzer = analyzer

            var continuation: AsyncStream<AnalyzerInput>.Continuation!
            let inputStream = AsyncStream<AnalyzerInput>(bufferingPolicy: .bufferingNewest(64)) { continuation = $0 }
            inputContinuation = continuation

            lines = []
            problems = []
            cards = []
            metrics = []
            timings = [:]
            timingSums = [:]
            liveEnglish = ""
            liveJapanese = ""
            summary = SummaryCard(id: UUID(), at: Date(), overview: "", points: [])
            lastSummarySource = ""
            startedAt = Date()
            lastCardAt = startedAt
            elapsed = 0
            refreshEngine()

            if useWhisper {
                notice = "聞き直しのモデルを準備中"
                await loadWhisper()
                notice = ""
                startedAt = Date()
                lastCardAt = startedAt
            }

            if let fileURL {
                audio.onFileFinished = { [weak self] in
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(8))
                        await self?.stop()
                    }
                }
                try audio.startFile(url: fileURL, analyzerFormat: analyzerFormat, continuation: continuation)
            } else {
                try audio.startMicrophone(analyzerFormat: analyzerFormat, continuation: continuation)
            }

            isRecording = true
            setKeepsScreenOn(true)

            tasks.append(Task { [weak self] in
                do {
                    for try await result in transcriber.results {
                        guard !Task.isCancelled else { return }
                        let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                        self?.handle(
                            text: text,
                            isFinal: result.isFinal,
                            start: result.text.audioStartSeconds,
                            end: result.text.audioEndSeconds
                        )
                    }
                } catch {
                    self?.notice = "音声認識が止まりました"
                }
            })
            tasks.append(Task {
                try? await analyzer.start(inputSequence: inputStream)
            })
            tasks.append(Task { [weak self] in await self?.runClock() })
            tasks.append(Task { [weak self] in await self?.runSummaryLoop() })
        } catch {
            notice = "開始できません：\(error.localizedDescription)"
            audio.stop()
        }
    }

    func stop() async {
        guard isRecording else { return }
        isRecording = false
        setKeepsScreenOn(false)
        audio.stop()
        inputContinuation?.finish()
        inputContinuation = nil
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        analyzer = nil
        await refreshSummary(force: true)
        pushCardIfNeeded(force: true)
        sampleMetrics()
        for task in tasks { task.cancel() }
        tasks = []
        liveEnglish = ""
        liveJapanese = ""
        saveSession()
    }

    // MARK: - 認識結果

    private func handle(text: String, isFinal: Bool, start: Double?, end: Double?) {
        guard !text.isEmpty else { return }
        if isFinal {
            liveEnglish = ""
            liveJapanese = ""
            liveRevision += 1
            let line = CaptionLine(
                id: UUID(), english: text, japanese: "", stage: .fast,
                heardAgain: false, at: Date(), audioStart: start, audioEnd: end
            )
            lines.append(line)
            translationContinuation?.yield(.final(id: line.id))
            if useWhisper {
                Task { await self.hearAgain(lineID: line.id) }
            } else {
                scheduleRefine()
            }
        } else {
            liveEnglish = text
            liveRevision += 1
            translationContinuation?.yield(.live(text: text, revision: liveRevision))
        }
    }

    // MARK: - 即時訳（端末内）

    func runTranslationLoop(with session: TranslationSession) async {
        do {
            try await session.prepareTranslation()
        } catch {
            notice = "翻訳の言語データを取得できません"
        }
        for await work in translationStream {
            guard !Task.isCancelled else { return }
            switch work {
            case .final(let id):
                guard let index = lines.firstIndex(where: { $0.id == id }) else { continue }
                let source = lines[index].english
                guard let response = try? await session.translate(source) else { continue }
                if let current = lines.firstIndex(where: { $0.id == id }),
                   lines[current].stage == .fast, lines[current].english == source {
                    lines[current].japanese = response.targetText
                }
            case .live(let text, let revision):
                guard revision == liveRevision else { continue }
                guard let response = try? await session.translate(text) else { continue }
                if revision == liveRevision { liveJapanese = response.targetText }
            }
        }
    }

    // MARK: - 聞き直し（端末内 Whisper）

    func prepareWhisper() {
        Task { await loadWhisper() }
    }

    private func loadWhisper() async {
        whisperState = "モデルを準備中（初回は取得に時間がかかります）"
        do {
            let started = Date()
            try await whisper.load(model: whisperModel)
            record("whisperLoadSeconds", Date().timeIntervalSince(started))
            whisperState = "準備済み"
        } catch {
            whisperState = "準備できません：\(error.localizedDescription)"
        }
    }

    func setWhisper(_ enabled: Bool) {
        useWhisper = enabled
        if enabled {
            prepareWhisper()
        } else {
            Task { await whisper.unload() }
            whisperState = ""
        }
    }

    private func hearAgain(lineID: UUID) async {
        defer { scheduleRefine() }
        guard await whisper.isReady,
              let index = lines.firstIndex(where: { $0.id == lineID }),
              let start = lines[index].audioStart, let end = lines[index].audioEnd else { return }
        let samples = audio.samples(from: start - 0.1, to: end + 0.1)
        guard let text = try? await whisper.transcribe(samples), text.count >= 2 else { return }
        let factor = await whisper.lastRealtimeFactor
        if timings["whisperFirstFactor"] == nil {
            timings["whisperFirstFactor"] = factor   // 初回はモデルの準備を含むので平均から外す
        } else {
            record("whisperRealtimeFactor", factor)
        }
        guard let current = lines.firstIndex(where: { $0.id == lineID }) else { return }
        lines[current].english = text
        lines[current].heardAgain = true
        if lines[current].stage == .fast {
            translationContinuation?.yield(.final(id: lineID))
        }
    }

    // MARK: - 訳し直し

    private func scheduleRefine() {
        guard !refineInFlight else { return }
        refineInFlight = true
        Task {
            await refinePending()
            refineInFlight = false
            if !pendingRefineIndices().isEmpty, engine == .cloud || (engine == .local && localRefine) {
                scheduleRefine()
            }
        }
    }

    private func pendingRefineIndices() -> [Int] {
        lines.indices.filter { lines[$0].stage == .fast && (!useWhisper || lines[$0].heardAgain || lines[$0].audioStart == nil) }
    }

    private func refinePending() async {
        refreshEngine()
        // 端末内モデルの訳し直しは話す速さに追いつかないので、明示的に選んだときだけ行う。
        guard engine == .cloud || (engine == .local && localRefine) else { return }
        let pending = Array(pendingRefineIndices().prefix(engine == .cloud ? 6 : 2))
        guard let first = pending.first else { return }
        let ids = pending.map { lines[$0].id }
        let sources = pending.map { lines[$0].english }
        let context = lines[..<first].suffix(4).map { "\($0.english) → \($0.japanese)" }

        let system = Prompts.refineSystem(vocabulary: vocabulary)
        let user = Prompts.refineUser(context: Array(context), lines: sources)
        let started = Date()
        var stage = CaptionLine.Stage.cloud
        var raw: String?

        if engine == .cloud {
            do {
                raw = try await bedrock.converse(system: system, user: user, maxTokens: 3000, thinks: true)
                record("cloudRefineSeconds", Date().timeIntervalSince(started))
            } catch {
                markCloudDown(error)
            }
        }
        if raw == nil, localRefine, local.unavailableReason == nil {
            stage = .local
            let localStarted = Date()
            raw = try? await local.respond(system: system, user: user)
            if raw != nil { record("localRefineSeconds", Date().timeIntervalSince(localStarted)) }
        }
        guard let raw else { return }
        let parsed = Prompts.parseRefined(raw, count: ids.count)
        for (offset, id) in ids.enumerated() {
            guard let index = lines.firstIndex(where: { $0.id == id }) else { continue }
            if let japanese = parsed[offset] { lines[index].japanese = japanese }
            lines[index].stage = stage
        }
    }

    private var bedrock: BedrockClient {
        BedrockClient(region: region, modelID: modelID, apiKey: apiKey)
    }

    private func markCloudDown(_ error: Error) {
        if problems.count < 50 {
            problems.append("\(Int(Date().timeIntervalSince(startedAt)))秒: \(error.localizedDescription)")
        }
        // 本文が空だっただけなら回線は生きているので、端末内へは切り替えない。
        if case BedrockClient.Failure.empty = error { return }
        cloudDownUntil = Date().addingTimeInterval(30)
        refreshEngine()
        if case BedrockClient.Failure.http(let code, _) = error, code == 401 || code == 403 {
            notice = "Bedrock の API キーを確認してください"
        }
    }

    // MARK: - 要約

    private func runSummaryLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(30))
            guard isRecording else { return }
            await refreshSummary(force: false)
            pushCardIfNeeded(force: false)
        }
    }

    private func refreshSummary(force: Bool) async {
        let cutoff = Date().addingTimeInterval(-5 * 60)
        let recent = lines.filter { $0.at >= cutoff }
        let english = recent.map(\.english).joined(separator: " ")
        guard english.count >= (force ? 60 : 200), english != lastSummarySource else { return }
        refreshEngine()

        let system = Prompts.summarySystem(vocabulary: vocabulary)
        var raw: String?
        if engine == .cloud {
            let started = Date()
            do {
                raw = try await bedrock.converse(system: system, user: english, maxTokens: 1200, thinks: false)
                record("cloudSummarySeconds", Date().timeIntervalSince(started))
            } catch {
                markCloudDown(error)
            }
        }
        if raw == nil, local.unavailableReason == nil {
            let started = Date()
            let source = await local.fit(english)
            raw = try? await local.respond(system: system, user: source)
            if raw != nil { record("localSummarySeconds", Date().timeIntervalSince(started)) }
        }
        guard let raw else { return }
        let parsed = Prompts.parseSummary(raw)
        guard !parsed.overview.isEmpty else { return }
        lastSummarySource = english
        summary = SummaryCard(id: UUID(), at: Date(), overview: parsed.overview, points: parsed.points)
    }

    /// 5分ごとに、その時点の要約を履歴へ積む。
    private func pushCardIfNeeded(force: Bool) {
        guard !summary.isEmpty else { return }
        guard force || Date().timeIntervalSince(lastCardAt) >= 5 * 60 else { return }
        if cards.first?.overview == summary.overview { return }
        cards.insert(SummaryCard(id: UUID(), at: Date(), overview: summary.overview, points: summary.points), at: 0)
        lastCardAt = Date()
    }

    // MARK: - 時計と計測

    private func runClock() async {
        sampleMetrics()
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            guard isRecording else { return }
            elapsed = Date().timeIntervalSince(startedAt)
            if Int(elapsed) % 60 == 0 { sampleMetrics() }
            if Int(elapsed) % 10 == 0 { refreshEngine() }
        }
    }

    private func sampleMetrics() {
        let thermal: String = switch ProcessInfo.processInfo.thermalState {
        case .nominal: "通常"
        case .fair: "やや高い"
        case .serious: "高い"
        case .critical: "危険"
        @unknown default: "不明"
        }
        metrics.append(MetricSample(
            minute: Int(Date().timeIntervalSince(startedAt) / 60),
            battery: batteryLevel,
            thermal: thermal,
            charging: isCharging
        ))
    }

    private func record(_ key: String, _ value: Double) {
        var entry = timingSums[key] ?? (0, 0)
        entry.total += value
        entry.count += 1
        timingSums[key] = entry
        timings[key] = entry.total / Double(entry.count)
    }

    /// 計測のまとめ。設定画面に出す。
    var metricsSummary: [(label: String, value: String)] {
        var rows: [(String, String)] = []
        if let first = metrics.first, let last = metrics.last, first.battery >= 0, last.battery >= 0 {
            let used = Int(((first.battery - last.battery) * 100).rounded())
            rows.append(("電池", "\(last.minute)分で \(used)% 減（\(Int(first.battery * 100))% → \(Int(last.battery * 100))%）\(last.charging ? "・充電中" : "")"))
        }
        if !metrics.isEmpty {
            let order = ["通常", "やや高い", "高い", "危険"]
            let worst = metrics.map(\.thermal).max { (order.firstIndex(of: $0) ?? 0) < (order.firstIndex(of: $1) ?? 0) } ?? "不明"
            rows.append(("本体の熱", "最大「\(worst)」／いま「\(metrics.last?.thermal ?? "")」"))
        }
        let labels: [(String, String, String)] = [
            ("cloudRefineSeconds", "訳し直し（クラウド）", "秒"),
            ("localRefineSeconds", "訳し直し（端末内）", "秒"),
            ("cloudSummarySeconds", "要約（クラウド）", "秒"),
            ("localSummarySeconds", "要約（端末内）", "秒"),
            ("whisperRealtimeFactor", "聞き直しの速さ", "倍の時間（1未満なら実時間より速い）"),
            ("whisperLoadSeconds", "Whisper の準備", "秒"),
            ("whisperFirstFactor", "聞き直しの初回", "倍の時間"),
        ]
        for (key, label, unit) in labels {
            if let value = timings[key] {
                rows.append((label, String(format: "平均 %.2f %@", value, unit)))
            }
        }
        if !lines.isEmpty {
            let cloud = lines.filter { $0.stage == .cloud }.count
            let localCount = lines.filter { $0.stage == .local }.count
            rows.append(("字幕", "\(lines.count)文（クラウド訳 \(cloud)・端末内訳 \(localCount)・聞き直し \(lines.filter(\.heardAgain).count)）"))
        }
        return rows
    }

    private func setKeepsScreenOn(_ on: Bool) {
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = on
        #endif
    }

    private var batteryLevel: Double {
        #if os(iOS)
        Double(UIDevice.current.batteryLevel)
        #else
        -1
        #endif
    }

    private var isCharging: Bool {
        #if os(iOS)
        UIDevice.current.batteryState == .charging || UIDevice.current.batteryState == .full
        #else
        false
        #endif
    }

    // MARK: - 保存

    /// 検証用：保存済みの聞き取り結果を画面に出す。
    private func loadReplay(_ url: URL) {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url),
              let record = try? decoder.decode(SessionRecord.self, from: data) else { return }
        lines = record.lines
        cards = record.cards
        metrics = record.metrics
        timings = record.timings
        if let latest = record.cards.first { summary = latest }
        if record.lines.contains(where: { $0.stage == .cloud }) { engine = .cloud }
        // 検証用：読み込んだ結果を、停止したときと同じ経路で保存して送る。
        if ProcessInfo.processInfo.environment["HANDY_SAVE"] == "1" {
            startedAt = record.startedAt
            saveSession(endedAt: record.endedAt ?? Date())
        }
    }

    private func saveSession(endedAt: Date = Date()) {
        guard !lines.isEmpty else { return }
        let record = SessionRecord(
            startedAt: startedAt, endedAt: endedAt, lines: lines, cards: cards, metrics: metrics,
            settings: ["useCloud": "\(useCloud)", "useWhisper": "\(useWhisper)", "modelID": modelID, "region": region],
            timings: timings,
            problems: problems
        )
        SessionStore.save(record)
        sessions = SessionStore.list()
        Task { await uploadPending() }
    }

    // MARK: - 記録の一覧と送信

    func record(for entry: SessionEntry) -> SessionRecord? {
        SessionStore.load(entry.id)
    }

    func delete(_ entry: SessionEntry) {
        SessionStore.delete(entry.id)
        sessions = SessionStore.list()
    }

    /// まだ送っていない記録を、古い順に S3 へ送る。電波が無ければ端末に残り、次の起動か停止でまた試す。
    func uploadPending() async {
        guard !isUploading else { return }
        let pending = sessions.filter { !$0.uploaded }.reversed()
        guard !pending.isEmpty else { return }
        guard let uploader = S3Uploader(bucket: s3Bucket, region: s3Region, credentials: s3Credentials) else {
            uploadNotice = ""
            return
        }
        isUploading = true
        defer { isUploading = false }
        uploadNotice = ""
        for entry in pending {
            guard let record = SessionStore.load(entry.id),
                  let json = try? SessionStore.encoder.encode(record) else { continue }
            do {
                try await uploader.put(
                    key: SessionStore.objectKey(entry.id, ext: "json"), data: json, contentType: "application/json"
                )
                try await uploader.put(
                    key: SessionStore.objectKey(entry.id, ext: "md"), data: Data(record.markdown.utf8),
                    contentType: "text/markdown; charset=utf-8"
                )
                SessionStore.setUploaded(entry.id, true)
                if let index = sessions.firstIndex(where: { $0.id == entry.id }) { sessions[index].uploaded = true }
            } catch {
                uploadNotice = "送信できません：\(error.localizedDescription)"
                return
            }
        }
    }
}
