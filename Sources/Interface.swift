import SwiftUI
import AppKit
import UniformTypeIdentifiers

private enum ChatPalette {
    static let canvas = Color(nsColor: .textBackgroundColor)
    static let secondary = Color.primary.opacity(0.045)
    static let border = Color.primary.opacity(0.08)
}

@MainActor struct TranscriptView: View {
    @StateObject private var model: TranscriptModel
    @StateObject private var polish: PolishController
    @State private var sidebarVisible = true
    @State private var showingSettings = false
    @State private var showingContext = false
    @State private var showingEditor = false
    @State private var showingOriginal = false
    @State private var exportError: String?
    init() {
        let controller = PolishController()
        _polish = StateObject(wrappedValue: controller)
        _model = StateObject(wrappedValue: TranscriptModel(polish: controller))
    }
    private var hasContent: Bool { !model.cues.isEmpty || !model.draft.isEmpty || !polish.text.isEmpty }
    private var locked: Bool { model.running || model.draining }
    private var original: String { model.cues.map(\.text).joined(separator: "\n") }
    private var currentText: String { showingOriginal || polish.text.isEmpty ? original : polish.text }
    var body: some View {
        HStack(spacing: 0) {
            if sidebarVisible {
                ChatSidebar(polish: polish, locked: locked, newSession: { model.newSession() }, settings: { showingSettings = true }, topic: { showingContext = true })
                    .frame(width: 218)
            }
            VStack(spacing: 0) {
                header
                if let message = model.errorMessage {
                    ChatError(message: message, action: nil) { model.errorMessage = nil }
                        .padding(.horizontal, 32).padding(.top, 12)
                }
                if let message = exportError {
                    ChatError(message: message, action: nil) { exportError = nil }
                        .padding(.horizontal, 32).padding(.top, 12)
                }
                if let message = polish.error {
                    ChatError(message: message, action: { polish.retry() }, dismiss: nil)
                        .padding(.horizontal, 32).padding(.top, 12)
                }
                if hasContent { conversation }
                else {
                    VStack(spacing: 20) {
                        Spacer()
                        AppMark().frame(width: 78, height: 64)
                        Text("有什么想记录的？").font(.system(size: 29, weight: .medium))
                        Spacer()
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                composer.padding(.horizontal, 32).padding(.bottom, 24).padding(.top, 12)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(ChatPalette.canvas).tint(.primary)
        .frame(minWidth: 780, minHeight: 600)
        .sheet(isPresented: $showingSettings) { RecordingSettingsView(model: model, polish: polish) }
        .sheet(isPresented: $showingContext) { ContextSettingsView(polish: polish, locked: locked) }
        .sheet(isPresented: $showingEditor) { PolishEditorView(polish: polish) }
        .task { polish.prepare() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            if model.running { model.stop() }
            polish.shutdown()
        }
    }
    private var header: some View {
        HStack(spacing: 14) {
            Button { withAnimation(.easeInOut(duration: 0.18)) { sidebarVisible.toggle() } } label: {
                Image(systemName: "sidebar.left").font(.system(size: 17))
            }.buttonStyle(.plain).help("切换侧边栏").accessibilityLabel("切换侧边栏")
            Text("本地听写").font(.system(size: 18, weight: .semibold))
            Spacer()
            if hasContent {
                HStack(spacing: 2) {
                    modeButton("润色", original: false)
                    modeButton("原文", original: true)
                }.padding(3).background(ChatPalette.secondary).clipShape(Capsule())
                Menu {
                    Button("复制") { copyCurrent() }.disabled(currentText.isEmpty)
                    Button("保存 TXT") { saveCurrent() }.disabled(currentText.isEmpty)
                    Button("导出原文 SRT") { model.save(srt: true) }.disabled(model.cues.isEmpty || locked)
                    Divider()
                    Button("重新润色全文") { polish.reprocess() }.disabled(locked || !polish.hasSource || !polish.ready)
                } label: { Image(systemName: "ellipsis").font(.system(size: 18)) }
                    .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("更多操作")
            }
        }.padding(.horizontal, 26).frame(height: 62)
    }
    private func modeButton(_ title: String, original: Bool) -> some View {
        Button { showingOriginal = original } label: {
            Text(title).font(.system(size: 13, weight: .medium)).padding(.horizontal, 15).padding(.vertical, 7)
                .background(showingOriginal == original ? ChatPalette.canvas : Color.clear).clipShape(Capsule())
        }.buttonStyle(.plain)
    }
    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    if showingOriginal || (polish.text.isEmpty && !polish.enabled) {
                        Text(original).font(.system(size: 17)).lineSpacing(7).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if !model.draft.isEmpty { Text(model.draft).font(.system(size: 17)).lineSpacing(7).foregroundStyle(.secondary) }
                    } else {
                        if !original.isEmpty || !model.draft.isEmpty {
                            HStack {
                                Spacer(minLength: 40)
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(original).lineLimit(6).textSelection(.enabled)
                                    if !model.draft.isEmpty { Text(model.draft).foregroundStyle(.secondary) }
                                }.font(.system(size: 16)).lineSpacing(5).padding(.horizontal, 20).padding(.vertical, 15)
                                    .background(ChatPalette.secondary).clipShape(RoundedRectangle(cornerRadius: 22))
                            }
                        }
                        if !polish.text.isEmpty {
                            VStack(alignment: .leading, spacing: 16) {
                                AppMark().frame(width: 36, height: 30)
                                Text(polish.text).font(.system(size: 17)).lineSpacing(7).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                resultActions
                            }
                        } else if polish.enabled && polish.ready {
                            HStack(spacing: 12) {
                                AppMark().frame(width: 32, height: 28)
                                if polish.busy { ProgressView().controlSize(.small) }
                            }
                        }
                    }
                    if polish.needsReprocess {
                        Button("重新润色") { polish.reprocess() }.buttonStyle(.bordered).disabled(locked || !polish.ready)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }.padding(.vertical, 26).frame(maxWidth: 720).padding(.horizontal, 38).frame(maxWidth: .infinity)
            }
            .onChange(of: model.cues.count) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: model.draft) { _, _ in if model.running { proxy.scrollTo("bottom", anchor: .bottom) } }
            .onChange(of: polish.text) { _, _ in if locked || polish.busy { proxy.scrollTo("bottom", anchor: .bottom) } }
        }
    }
    private var resultActions: some View {
        HStack(spacing: 18) {
            Button { copyCurrent() } label: { Image(systemName: "doc.on.doc") }.help("复制").accessibilityLabel("复制润色结果")
            Button { saveCurrent() } label: { Image(systemName: "arrow.down.to.line") }.help("保存 TXT").accessibilityLabel("保存润色 TXT")
            Button { showingEditor = true } label: { Image(systemName: "pencil") }.disabled(locked || !polish.canEdit).help("编辑").accessibilityLabel("编辑润色文字")
        }.buttonStyle(.plain).font(.system(size: 14)).foregroundStyle(.secondary)
    }
    private var composer: some View {
        VStack(alignment: .leading, spacing: 16) {
            TextField("添加上下文", text: $polish.requirements, axis: .vertical)
                .lineLimit(2...5)
                .font(.system(size: 16)).textFieldStyle(.plain).disabled(locked)
                .onChange(of: polish.requirements) { _, _ in polish.topicChanged() }
            if polish.contextIsTooLong {
                Text("上下文最多 \(PolishController.maximumContextCharacters) 字").font(.system(size: 13)).foregroundStyle(.red)
            }
            HStack(spacing: 12) {
                Button { showingContext = true } label: { Label("上下文", systemImage: "text.alignleft") }
                    .buttonStyle(ChatChipStyle(selected: false)).disabled(locked)
                Button { polish.enabled.toggle(); polish.enabledChanged() } label: { Label("润色", systemImage: "sparkles") }
                    .buttonStyle(ChatChipStyle(selected: polish.enabled)).accessibilityValue(polish.enabled ? "开启" : "关闭")
                Spacer(minLength: 4)
                if model.loading || model.draining {
                    ProgressView().controlSize(.small)
                } else if model.running {
                    AudioActivity(level: model.level)
                    Text("聆听中").font(.system(size: 13)).foregroundStyle(.secondary)
                } else if polish.preparing {
                    ProgressView().controlSize(.small)
                    Text("准备中").font(.system(size: 13)).foregroundStyle(.secondary)
                } else if polish.hasWork && polish.enabled {
                    if polish.busy { ProgressView().controlSize(.small) }
                    Button(polish.paused ? "继续" : "暂停") { polish.togglePause() }.buttonStyle(.plain).font(.system(size: 13))
                }
                if polish.enabled && !polish.ready && !polish.preparing {
                    Button("准备润色") { polish.prepare(download: true) }.buttonStyle(.plain).font(.system(size: 13))
                }
                if !model.ready && !model.loading {
                    Button("下载语音模型") { showingSettings = true }.buttonStyle(.plain)
                }
                Button {
                    if model.running { model.stop() } else { model.start() }
                } label: {
                    Image(systemName: model.running ? "stop.fill" : "mic.fill")
                        .font(.system(size: 17, weight: .semibold)).foregroundStyle(ChatPalette.canvas)
                        .frame(width: 40, height: 40).background(Color.primary).clipShape(Circle())
                }.buttonStyle(.plain).disabled(!model.ready || model.draining || (!model.running && polish.enabled && polish.contextIsTooLong) || polish.savingContext)
                    .keyboardShortcut("r", modifiers: [.command])
                    .help(model.running ? "停止" : "开始听写").accessibilityLabel(model.running ? "停止听写" : "开始听写")
            }
        }.padding(18).background(ChatPalette.secondary).clipShape(RoundedRectangle(cornerRadius: 25))
            .overlay(RoundedRectangle(cornerRadius: 25).stroke(ChatPalette.border, lineWidth: 0.5))
            .frame(maxWidth: 760).frame(maxWidth: .infinity)
    }
    private func copyCurrent() {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(currentText, forType: .string)
    }
    private func saveCurrent() {
        let snapshot = currentText
        let panel = NSSavePanel(); panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = showingOriginal || polish.text.isEmpty ? "原文.txt" : "润色.txt"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do { try snapshot.write(to: url, atomically: true, encoding: .utf8); exportError = nil }
            catch { exportError = error.localizedDescription }
        }
    }
}

private struct ChatChipStyle: ButtonStyle {
    let selected: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 11).padding(.vertical, 7)
            .background(Color.primary.opacity(configuration.isPressed ? 0.12 : (selected ? 0.08 : 0)))
            .clipShape(Capsule())
    }
}

@MainActor private struct ChatSidebar: View {
    @ObservedObject var polish: PolishController
    let locked: Bool
    let newSession: () -> Void
    let settings: () -> Void
    let topic: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 8) {
                AppMark().frame(width: 32, height: 30)
                Text("本地听写").font(.system(size: 15, weight: .semibold))
                Spacer()
            }.padding(.top, 9)
            Button(action: newSession) { Label("新听写", systemImage: "square.and.pencil").frame(maxWidth: .infinity, alignment: .leading) }
                .buttonStyle(.plain).font(.system(size: 14, weight: .medium)).padding(.horizontal, 8).padding(.vertical, 7).disabled(locked)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("上下文").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                        Spacer()
                        Button(action: topic) { Image(systemName: "plus") }.buttonStyle(.plain).disabled(locked).accessibilityLabel("管理上下文")
                    }.padding(.horizontal, 8).padding(.bottom, 8)
                    ForEach(polish.topics) { item in
                        Button { polish.selectTopic(item.id) } label: {
                            Text(item.name).font(.system(size: 14)).lineLimit(1).help(item.name)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.vertical, 10)
                                .background(polish.topicName == item.name ? Color.primary.opacity(0.065) : Color.clear)
                                .clipShape(RoundedRectangle(cornerRadius: 9))
                        }.buttonStyle(.plain).disabled(locked || polish.savingContext)
                    }
                }
            }
            Spacer(minLength: 0)
            Button(action: settings) { Label("设置", systemImage: "gearshape").font(.system(size: 14)).padding(8) }.buttonStyle(.plain)
        }.padding(.horizontal, 15).padding(.bottom, 14)
            .background(ChatPalette.secondary).overlay(alignment: .trailing) { Rectangle().fill(ChatPalette.border).frame(width: 0.5) }
    }
}

private struct AudioActivity: View {
    let level: Float
    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<4) { index in
                Capsule().fill(Color.primary.opacity(0.75)).frame(width: 3, height: max(4, min(22, CGFloat(level) * 230 * (index % 2 == 0 ? 1 : 0.7))))
            }
        }.frame(width: 24, height: 24).animation(.easeOut(duration: 0.12), value: level).accessibilityLabel("麦克风音量")
    }
}

private struct ChatError: View {
    let message: String
    let action: (() -> Void)?
    let dismiss: (() -> Void)?
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle")
            Text(message).font(.system(size: 14)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            if let action = action { Button("重试", action: action).buttonStyle(.plain) }
            if let dismiss = dismiss { Button(action: dismiss) { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("关闭提示") }
        }.padding(14).background(Color.red.opacity(0.06)).clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
