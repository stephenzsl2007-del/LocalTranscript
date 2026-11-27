import SwiftUI
import AppKit

@MainActor struct ContextSettingsView: View {
    @ObservedObject var polish: PolishController
    let locked: Bool
    @State private var saveTask: Task<Void, Never>?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("上下文").font(.system(size: 22, weight: .semibold))
                Spacer()
                if polish.savingContext {
                    Button("取消") { saveTask?.cancel() }
                } else { Button("完成") { dismiss() }.keyboardShortcut(.defaultAction) }
            }
            HStack(spacing: 14) {
                Picker("已保存", selection: Binding(get: { polish.selectedTopic }, set: { polish.selectTopic($0) })) {
                    Text("新上下文").tag(Optional<UUID>.none)
                    ForEach(polish.topics) { Text($0.name).tag(Optional($0.id)) }
                }.frame(maxWidth: 280)
                Spacer()
            }.disabled(locked || polish.savingContext)
            TextField("名称，留空自动命名", text: $polish.topicName)
                .textFieldStyle(.roundedBorder).font(.system(size: 15)).disabled(locked || polish.savingContext)
                .onChange(of: polish.topicName) { _, _ in polish.topicChanged() }
            ZStack(alignment: .topLeading) {
                if polish.requirements.isEmpty {
                    Text("背景、术语、表达偏好…").font(.system(size: 16)).foregroundStyle(.tertiary).padding(.horizontal, 14).padding(.vertical, 17)
                }
                TextEditor(text: $polish.requirements).font(.system(size: 16)).lineSpacing(6)
                    .scrollContentBackground(.hidden).padding(8).disabled(locked || polish.savingContext)
                    .accessibilityLabel("上下文内容")
            }.frame(minHeight: 260, maxHeight: .infinity)
                .background(Color.primary.opacity(0.035)).clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.08), lineWidth: 1))
                .onChange(of: polish.requirements) { _, _ in polish.topicChanged() }
            if let message = polish.contextSaveError {
                Text(message).font(.system(size: 14)).foregroundStyle(.red).textSelection(.enabled)
            }
            HStack {
                Button("删除") { polish.deleteTopic() }.disabled(locked || polish.savingContext || polish.selectedTopic == nil)
                if polish.contextIsTooLong {
                    Text("最多 \(PolishController.maximumContextCharacters) 字").font(.system(size: 13)).foregroundStyle(.red)
                }
                Spacer()
                Button {
                    saveTask = Task { if await polish.saveTopic() { dismiss() } }
                } label: {
                    HStack(spacing: 8) {
                        if polish.savingContext { ProgressView().controlSize(.small).tint(.white) }
                        Text(polish.savingContext ? "正在命名…" : "保存上下文")
                    }
                }.buttonStyle(ContextSaveButtonStyle())
                    .disabled(locked || polish.savingContext || !polish.canSaveContext)
            }
        }.padding(26).frame(width: 620, height: 560).tint(.primary)
            .interactiveDismissDisabled(polish.savingContext)
            .onDisappear { saveTask?.cancel() }
    }
}

@MainActor struct RecordingSettingsView: View {
    @ObservedObject var model: TranscriptModel
    @ObservedObject var polish: PolishController
    @State private var speechChoice = ModelCatalog.selectedSpeech
    @State private var polishChoice = LocalPolishClient.model
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("设置").font(.system(size: 22, weight: .semibold))
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            Form {
                Section("语音模型") {
                    Picker("模型", selection: $speechChoice) {
                        ForEach(ModelCatalog.speech) { Text($0.title).tag($0.id) }
                    }.disabled(model.running || model.draining || model.loading || model.downloadingSpeech)
                    HStack {
                        Text("当前：Whisper \(model.speechModel)")
                        Spacer()
                        if model.downloadingSpeech || model.loading { ProgressView().controlSize(.small) }
                        else if ModelCatalog.installed(speechChoice) {
                            Button(speechChoice == model.speechModel ? "使用中" : "切换") { model.useSpeechModel(speechChoice) }.disabled(model.running || model.draining || speechChoice == model.speechModel)
                        } else { Button("下载并使用") { model.downloadSpeechModel(speechChoice) }.disabled(model.running || model.draining) }
                    }
                    if !model.modelDownloadStatus.isEmpty { Text(model.modelDownloadStatus).textSelection(.enabled) }
                }
                Section("听写") {
                    Picker("语言", selection: $model.language) {
                        Text("自动").tag("auto"); Text("中文").tag("zh"); Text("English").tag("en")
                    }.disabled(model.running || model.draining)
                    LabeledContent("声音阈值") {
                        Slider(value: $model.threshold, in: 0.002...0.03).frame(width: 170).disabled(model.running || model.draining)
                    }
                    LabeledContent("麦克风") {
                        Button("系统设置") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!) }
                    }
                }
                Section("润色") {
                    Toggle("自动润色", isOn: $polish.enabled).onChange(of: polish.enabled) { _, _ in polish.enabledChanged() }
                    Picker("模型", selection: $polishChoice) {
                        ForEach(ModelCatalog.polish, id: \.self) { Text(ModelCatalog.polishTitle($0)).tag($0) }
                    }.disabled(model.running || model.draining || polish.hasWork || polish.savingContext || polish.preparing)
                    HStack {
                        Text("当前：\(polish.polishModel)")
                        Spacer()
                        if polish.preparing { ProgressView().controlSize(.small) }
                        else { Button("下载并切换") { polish.usePolishModel(polishChoice, download: true) }.disabled(model.running || model.draining || polish.hasWork || polish.savingContext) }
                    }
                    if polish.preparing { Text(polish.preparingStatus).textSelection(.enabled) }
                    if let error = polish.modelSelectionError { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                    if !polish.ready { Text(polish.preparingStatus).foregroundStyle(.secondary).textSelection(.enabled) }
                    if polish.hasWork {
                        HStack {
                            Text("待处理"); Spacer(); Text("\(polish.pendingCount) 段")
                            Button(polish.paused ? "继续" : "暂停") { polish.togglePause() }
                        }
                    }
                    if polish.needsReprocess { Button("重新润色全文") { polish.reprocess(); dismiss() }.disabled(model.running || model.draining || !polish.ready) }
                }
            }.formStyle(.grouped)
        }.padding(26).frame(width: 560).tint(.primary)
    }
}

@MainActor struct PolishEditorView: View {
    @ObservedObject var polish: PolishController
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 18) {
            HStack {
                Text("编辑文字").font(.system(size: 22, weight: .semibold))
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            TextEditor(text: $polish.text).font(.system(size: 17)).lineSpacing(6)
                .disabled(!polish.canEdit).padding(12)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.1), lineWidth: 1))
        }.padding(26).frame(width: 650, height: 480).tint(.primary)
    }
}

private struct ContextSaveButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Color.white)
            .padding(.horizontal, 18).padding(.vertical, 11)
            .background(Color.black.opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.35))
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
