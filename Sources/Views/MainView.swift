import SwiftUI
import Translation

struct MainView: View {
    @ObservedObject var model: AppModel
    @State private var showsHistory = false
    @State private var showsSettings = false
    @State private var showsSessions = false
    @State private var cardHeight: CGFloat = 0
    @State private var bodyHeight: CGFloat = 0
    @AppStorage("summaryCollapsed") private var summaryCollapsed = false

    private let translation = TranslationSession.Configuration(
        source: Locale.Language(identifier: "en"),
        target: Locale.Language(identifier: "ja")
    )

    var body: some View {
        VStack(spacing: 0) {
            topBar
            GeometryReader { proxy in
                ZStack(alignment: .top) {
                    captionPane(height: proxy.size.height)
                    summaryCard(limit: proxy.size.height * 0.46)
                }
                .overlay(alignment: .bottom) { bottomBar }
            }
        }
        .background(Theme.background)
        .modifier(InstantTranslation(model: model, configuration: translation))
        .onAppear {
            // 検証用：起動時にシートを開いた状態にできる。
            switch ProcessInfo.processInfo.environment["HANDY_SHEET"] {
            case "history": showsHistory = true
            case "settings": showsSettings = true
            case "sessions": showsSessions = true
            default: break
            }
        }
        .sheet(isPresented: $showsHistory) { HistoryView(model: model) }
        .sheet(isPresented: $showsSettings) { SettingsView(model: model) }
        .sheet(isPresented: $showsSessions) { SessionsView(model: model) }
    }

    // MARK: 上端

    private var topBar: some View {
        HStack(spacing: 12) {
            if model.isRecording {
                Circle().fill(Theme.live).frame(width: 8, height: 8)
                Text(clock(model.elapsed))
                    .font(.system(size: 15, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.ink)
            } else {
                Text("通訳くん")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.ink)
            }
            Spacer()
            Button(action: model.toggleCloud) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(model.engine == .cloud ? Theme.good : Theme.mute)
                        .frame(width: 6, height: 6)
                    Text(model.engine.label)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.sub)
                }
                .frame(height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("訳し直しの方式：\(model.engine.label)")
            Button { showsSessions = true } label: {
                Image(systemName: "clock")
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(Theme.sub)
                    .frame(width: 40, height: 44)
            }
            .buttonStyle(.plain)
            .disabled(model.isRecording)
            .opacity(model.isRecording ? 0.35 : 1)
            .accessibilityLabel("過去の記録")
            Button { showsSettings = true } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(Theme.sub)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("設定")
        }
        .padding(.leading, Theme.edge)
        .padding(.trailing, Theme.edge - 14)
        .frame(height: 52)
    }

    // MARK: 要約（字幕の上に浮かぶ面）

    @ViewBuilder
    private func summaryCard(limit: CGFloat) -> some View {
        if !model.summary.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) {
                    Button { showsHistory = true } label: {
                        HStack(spacing: 5) {
                            Text("直近5分")
                                .font(.system(size: 13, weight: .medium))
                            if !model.cards.isEmpty {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 10, weight: .semibold))
                            }
                        }
                        .foregroundStyle(Theme.mute)
                        .frame(height: 36)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(model.cards.isEmpty)
                    .accessibilityLabel("ここまでの流れを開く")
                    Spacer()
                    Image(systemName: summaryCollapsed ? "chevron.down" : "chevron.up")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.mute)
                        .frame(width: 36, height: 36)
                }
                if summaryCollapsed {
                    Text(model.summary.overview)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                        .lineSpacing(4)
                        .lineLimit(2)
                } else {
                    // 中身が上限より長いときだけ中で送れるようにし、下端は面の色へ溶かす。
                    let room = max(80, limit - 60)
                    ScrollView {
                        summaryBody
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { bodyHeight = $0 }
                    }
                    .scrollIndicators(.hidden)
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(height: min(max(bodyHeight, 1), room))
                    .mask {
                        VStack(spacing: 0) {
                            Color.black
                            LinearGradient(colors: [.black, bodyHeight > room ? .clear : .black],
                                           startPoint: .top, endPoint: .bottom)
                                .frame(height: 28)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 18)
            .padding(.trailing, 8)
            .padding(.top, 4)
            .padding(.bottom, 16)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .onTapGesture { withAnimation(.easeOut(duration: 0.25)) { summaryCollapsed.toggle() } }
            .accessibilityHint(summaryCollapsed ? "押すと要約を広げる" : "押すと要約を畳む")
            .padding(.horizontal, 12)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { cardHeight = $0 }
            .animation(.easeOut(duration: 0.3), value: model.summary.id)
            .transition(.opacity)
        }
    }

    private var summaryBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.summary.overview)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .lineSpacing(5)
                .padding(.bottom, 2)
            ForEach(Array(model.summary.points.enumerated()), id: \.offset) { _, point in
                Text(point)
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.sub)
                    .lineSpacing(4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.trailing, 10)
    }

    // MARK: 字幕（画面全体を下から上へ流れる）

    private func captionPane(height: CGFloat) -> some View {
        let lines = Array(model.lines.suffix(40))
        let covered = model.summary.isEmpty ? 0 : cardHeight
        return ScrollViewReader { reader in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(line.japanese.isEmpty ? line.english : line.japanese)
                                .font(.system(size: 19))
                                .foregroundStyle(
                                    line.japanese.isEmpty ? Theme.mute
                                        : index >= lines.count - 3 ? Theme.ink : Theme.sub
                                )
                                .lineSpacing(6)
                            if model.showEnglish, !line.japanese.isEmpty {
                                Text(line.english)
                                    .font(.system(size: 13))
                                    .foregroundStyle(Theme.mute)
                                    .lineSpacing(3)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if !model.liveEnglish.isEmpty {
                        Text(model.liveJapanese.isEmpty ? model.liveEnglish : model.liveJapanese)
                            .font(.system(size: 19))
                            .foregroundStyle(Theme.mute)
                            .lineSpacing(6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    // 下端のボタンに文字が重ならないよう、末尾の目印までを空けておく。
                    Color.clear.frame(height: 92).id("end")
                }
                .padding(.horizontal, Theme.edge)
                .padding(.top, covered + 40)
                .frame(minHeight: height, alignment: .bottom)
            }
            .scrollIndicators(.hidden)
            .onAppear { reader.scrollTo("end", anchor: .bottom) }
            .onChange(of: model.lines.count) { reader.scrollTo("end", anchor: .bottom) }
            .onChange(of: model.liveJapanese) { reader.scrollTo("end", anchor: .bottom) }
            .onChange(of: model.liveEnglish) { reader.scrollTo("end", anchor: .bottom) }
        }
        // 要約の面の下と、下端のボタンの手前で、文字を白へ溶かす。線では切らない。
        .mask {
            VStack(spacing: 0) {
                Color.clear.frame(height: covered + 4)
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                    .frame(height: 56)
                Color.black
                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: 28)
                Color.clear.frame(height: 76)
            }
        }
    }

    // MARK: 下端（字幕の上に浮かぶ）

    private var bottomBar: some View {
        VStack(spacing: 10) {
            if !model.notice.isEmpty {
                Text(model.notice)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.sub)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Theme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            Button {
                Task {
                    if model.isRecording { await model.stop() } else { await model.start() }
                }
            } label: {
                Group {
                    if model.isRecording {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(.white)
                            .frame(width: 20, height: 20)
                            .frame(width: 64, height: 64)
                    } else {
                        HStack(spacing: 10) {
                            if model.isPreparing { ProgressView().tint(.white) }
                            Text(model.isPreparing ? "準備中" : "聞き取りを開始")
                                .font(.system(size: 17, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 32)
                        .frame(height: 56)
                    }
                }
                .background(Theme.ink)
                .clipShape(Capsule())
                .shadow(color: Theme.ink.opacity(0.22), radius: 14, y: 6)
            }
            .buttonStyle(.plain)
            .disabled(model.isPreparing)
            .accessibilityLabel(model.isRecording ? "停止" : "聞き取りを開始")
        }
        .padding(.horizontal, Theme.edge)
        .padding(.bottom, 12)
        .animation(.easeOut(duration: 0.25), value: model.isRecording)
    }

    private func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return String(format: "%d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
    }
}

/// 5分ごとの要約を新しい順に並べる。
struct HistoryView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(model.cards) { card in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(card.at, format: .dateTime.hour().minute())
                                .font(.system(size: 13, weight: .medium).monospacedDigit())
                                .foregroundStyle(Theme.mute)
                            Text(card.overview)
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(Theme.ink)
                                .lineSpacing(5)
                            ForEach(card.points, id: \.self) { point in
                                Text(point)
                                    .font(.system(size: 15))
                                    .foregroundStyle(Theme.sub)
                                    .lineSpacing(4)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 20)
                        Rectangle().fill(Theme.hairline).frame(height: 1)
                    }
                    if model.cards.isEmpty {
                        Text("要約は5分ごとにここへ積まれます")
                            .font(.system(size: 15))
                            .foregroundStyle(Theme.mute)
                            .padding(.top, 24)
                    }
                }
                .padding(.horizontal, Theme.edge)
            }
            .background(Theme.background)
            .navigationTitle("ここまでの流れ")
            .sheetChrome { dismiss() }
        }
        .preferredColorScheme(.light)
    }
}

/// 端末内の即時訳。Apple の翻訳はシミュレータで動かないので、実機でだけつなぐ。
private struct InstantTranslation: ViewModifier {
    let model: AppModel
    let configuration: TranslationSession.Configuration

    func body(content: Content) -> some View {
        #if targetEnvironment(simulator)
        content
        #else
        content.translationTask(configuration) { session in
            await model.runTranslationLoop(with: session)
        }
        #endif
    }
}

extension View {
    /// シートの題と「閉じる」。iPhone と Mac で置き場所の指定が違うのでここで吸収する。
    @ViewBuilder
    func sheetChrome(close: @escaping () -> Void) -> some View {
        #if os(iOS)
        self.navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("閉じる", action: close).tint(Theme.ink)
                }
            }
        #else
        self.toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("閉じる", action: close)
            }
        }
        .frame(minWidth: 393, minHeight: 600)
        #endif
    }

    @ViewBuilder
    func plainEntry() -> some View {
        #if os(iOS)
        self.textInputAutocapitalization(.never).autocorrectionDisabled()
        #else
        self.autocorrectionDisabled()
        #endif
    }
}
