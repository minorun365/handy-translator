import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var keyDraft = ""
    @State private var s3Draft = ""
    @State private var picksFile = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("クラウドで訳し直す", isOn: Binding(
                        get: { model.useCloud },
                        set: { _ in model.toggleCloud() }
                    ))
                    SecureField(model.hasAPIKey ? "API キー（保存済み）" : "Bedrock の API キー", text: $keyDraft)
                        .plainEntry()
                        .onSubmit(saveKey)
                    if !keyDraft.isEmpty {
                        Button("キーを保存", action: saveKey)
                    }
                    TextField("リージョン", text: $model.region)
                        .plainEntry()
                    TextField("モデル", text: $model.modelID)
                        .plainEntry()
                } header: {
                    Text("訳し直しと要約")
                } footer: {
                    Text("送るのは確定した英文の文字だけで、音声は端末から出ません。切ると端末内のモデルを使います。")
                }

                Section {
                    TextField("バケット名", text: $model.s3Bucket)
                        .plainEntry()
                    TextField("リージョン", text: $model.s3Region)
                        .plainEntry()
                    SecureField(model.hasS3Key ? "鍵（保存済み）" : "アクセスキーID:シークレット", text: $s3Draft)
                        .plainEntry()
                        .onSubmit(saveS3Key)
                    if !s3Draft.isEmpty {
                        Button("鍵を保存", action: saveS3Key)
                    }
                } header: {
                    Text("記録の保存先（S3）")
                } footer: {
                    Text("停止すると、文字の記録を自分の S3 へ自動で送ります。音声は送りません。鍵は、このバケットへ書き込むだけの権限にしてください。")
                }

                Section("表示") {
                    Toggle("英語の原文も出す", isOn: $model.showEnglish)
                }

                Section {
                    TextField("語彙", text: $model.vocabulary, axis: .vertical)
                        .lineLimit(3...8)
                        .plainEntry()
                } header: {
                    Text("聞き違えやすい語")
                }

                Section {
                    Toggle("Whisper で聞き直す", isOn: Binding(
                        get: { model.useWhisper },
                        set: { model.setWhisper($0) }
                    ))
                    Picker("モデル", selection: $model.whisperModel) {
                        ForEach(WhisperEngine.models, id: \.name) { item in
                            Text(item.label).tag(item.name)
                        }
                    }
                    .disabled(model.isRecording)
                    if !model.whisperState.isEmpty {
                        LabeledContent("状態", value: model.whisperState)
                    }
                    Toggle("端末内のモデルで訳し直す", isOn: $model.localRefine)
                } header: {
                    Text("試験的な機能")
                } footer: {
                    Text("どちらも既定は切。Whisper の聞き直しは本体がかなり熱くなります。端末内モデルの訳し直しは、話す速さに追いつかないことがあります。")
                }

                Section {
                    Button("音声ファイルで試す") { picksFile = true }
                        .disabled(model.isRecording)
                } footer: {
                    Text("録音済みの講演を実時間の速さで流し、マイクと同じ経路で字幕と要約を作ります。")
                }

                if !model.metricsSummary.isEmpty {
                    Section("計測（今回の聞き取り）") {
                        ForEach(model.metricsSummary, id: \.label) { row in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(row.label).font(.system(size: 13)).foregroundStyle(Theme.mute)
                                Text(row.value).font(.system(size: 15).monospacedDigit()).foregroundStyle(Theme.ink)
                            }
                        }
                    }
                }
            }
            .navigationTitle("設定")
            .sheetChrome { dismiss() }
            .fileImporter(isPresented: $picksFile, allowedContentTypes: [.audio]) { result in
                guard case .success(let url) = result else { return }
                let granted = url.startAccessingSecurityScopedResource()
                dismiss()
                Task {
                    await model.start(fileURL: url)
                    if granted { url.stopAccessingSecurityScopedResource() }
                }
            }
        }
        .tint(Theme.ink)
        .preferredColorScheme(.light)
    }

    private func saveS3Key() {
        model.setS3Key(s3Draft)
        s3Draft = ""
    }

    private func saveKey() {
        model.setAPIKey(keyDraft)
        keyDraft = ""
    }
}
