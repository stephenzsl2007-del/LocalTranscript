import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers

final class CaptureSession {
    private let engine = AVAudioEngine()
    private let processing = DispatchQueue(label: "localtranscript.pcm", qos: .userInitiated)
    private let slots = DispatchSemaphore(value: 32)
    private let inference: DispatchQueue
    private let whisper: WhisperEngine
    private let segmenter = Segmenter()
    private var converter: PCMConverter?
    private var pending = 0
    private var failed = false
    private var language: String
    var onChunkState: ((Int, Bool) -> Void)?
    var onResult: ((Int, [Cue], Bool, Double) -> Void)?
    var onError: ((String) -> Void)?
    var onLevel: ((Float) -> Void)?
    var onInferenceBusy: ((Bool) -> Void)?
    init(whisper: WhisperEngine, inference: DispatchQueue, language: String, threshold: Float) {
        self.whisper = whisper; self.inference = inference; self.language = language
        segmenter.threshold = threshold
        segmenter.onLevel = { [weak self] value in self?.onLevel?(value) }
        segmenter.onChunk = { [weak self] id, offset, samples, final in
            guard let self = self, !self.failed else { return }
            if !final && self.pending > 0 { return } // Coalesce drafts, retain every final.
            if self.pending >= 8 { self.fail("识别积压超过 8 段，已停止采集。请等待定稿后重新开始。"); return }
            self.pending += 1
            self.onInferenceBusy?(true)
            self.onChunkState?(id, final)
            self.inference.async {
                let start = Date()
                do {
                    let cues = try self.whisper.transcribe(samples, offset: offset, language: self.language)
                    self.onResult?(id, cues, final, Date().timeIntervalSince(start))
                } catch { self.onError?(error.localizedDescription) }
                self.processing.async { self.pending -= 1; self.onInferenceBusy?(self.pending > 0) }
            }
        }
    }
    private func fail(_ message: String) {
        guard !failed else { return }; failed = true; onError?(message)
    }
    func start() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw TranscriptError.message("没有可用麦克风，请检查系统声音输入设置。") }
        converter = try PCMConverter(format)
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            guard let self = self else { return }
            // Bound queued audio copies to ~1.4 s at 48 kHz. Never block the audio callback.
            guard self.slots.wait(timeout: .now()) == .success else {
                self.processing.async { self.fail("音频处理跟不上采集，已停止。请关闭高负载程序后重试。") }; return
            }
            guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { self.slots.signal(); return }
            copy.frameLength = buffer.frameLength
            let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
            let target = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
            for i in 0..<source.count { memcpy(target[i].mData!, source[i].mData!, Int(source[i].mDataByteSize)) }
            self.processing.async {
                defer { self.slots.signal() }
                guard !self.failed else { return }
                do { try self.segmenter.feed(self.converter!.convert(copy)) }
                catch { self.fail(error.localizedDescription) }
            }
        }
        do { engine.prepare(); try engine.start() }
        catch { input.removeTap(onBus: 0); throw error }
    }
    func stop(completion: @escaping () -> Void) {
        engine.stop(); engine.inputNode.removeTap(onBus: 0)
        processing.async {
            if let c = self.converter, let empty = AVAudioPCMBuffer(pcmFormat: c.input, frameCapacity: 1) {
                do { try self.segmenter.feed(c.convert(empty, end: true)) }
                catch { self.onError?(error.localizedDescription) }
            }
            self.segmenter.flush()
            self.inference.async { DispatchQueue.main.async(execute: completion) }
        }
    }
}

@MainActor final class TranscriptModel: ObservableObject {
    let polish: PolishController
    init(polish: PolishController) {
        self.polish = polish
        loadEngine()
    }
    @Published private(set) var speechModel = ModelCatalog.selectedSpeech
    @Published private(set) var downloadingSpeech = false
    @Published var modelDownloadStatus = ""
    @Published var status = "正在加载本地 small 模型…"
    @Published var ready = false
    @Published var loading = true
    @Published var running = false
    @Published var draining = false
    @Published var cues: [Cue] = []
    @Published var draft = ""
    @Published var language = "auto"
    @Published var threshold: Double = 0.008
    @Published var level: Float = 0
    @Published var lastLatency: Double = 0
    @Published var permission = ""
    @Published var errorMessage: String?
    private let inference = DispatchQueue(label: "localtranscript.whisper", qos: .userInitiated)
    private var whisper: WhisperEngine?
    private var capture: CaptureSession?
    private var currentDraft = -1
    private var routeObserver: NSObjectProtocol?
    private var activity: NSObjectProtocol?
    private var permissionPending = false
    private func loadEngine() {
        refreshPermission()
        guard FileManager.default.fileExists(atPath: modelPath()) else {
            loading = false; ready = false; status = "尚未下载语音模型"; return
        }
        inference.async {
            do {
                let engine = try WhisperEngine(path: modelPath())
                DispatchQueue.main.async { self.whisper = engine; self.ready = true; self.loading = false; self.status = "就绪 · 完全离线" }
            } catch { DispatchQueue.main.async { self.loading = false; self.status = "模型不可用"; self.errorMessage = error.localizedDescription } }
        }
    }
    func useSpeechModel(_ id: String) {
        guard !running, !draining, !loading, ModelCatalog.installed(id) else { return }
        loading = true; ready = false; errorMessage = nil
        inference.async {
            do {
                let candidate = try WhisperEngine(path: ModelCatalog.speechPath(id))
                DispatchQueue.main.async {
                    self.whisper = candidate; self.speechModel = id
                    UserDefaults.standard.set(id, forKey: "models.speech")
                    self.ready = true; self.loading = false; self.status = "就绪"
                }
            } catch {
                DispatchQueue.main.async { self.loading = false; self.ready = self.whisper != nil; self.errorMessage = error.localizedDescription }
            }
        }
    }
    func downloadSpeechModel(_ id: String) {
        guard !downloadingSpeech else { return }
        downloadingSpeech = true; modelDownloadStatus = "正在下载并校验…"
        Task {
            defer { downloadingSpeech = false }
            do {
                try await ModelCatalog.downloadSpeech(id)
                modelDownloadStatus = "已下载"
                if !running && !draining { useSpeechModel(id) }
            } catch { modelDownloadStatus = error.localizedDescription }
        }
    }
    func refreshPermission() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: permission = "麦克风已授权"
        case .notDetermined: permission = "开始时请求麦克风权限"
        default: permission = "麦克风未授权 · 请在系统设置中允许"
        }
    }
    func start() {
        guard ready, !running, !draining, !permissionPending else { return }
        errorMessage = nil
        permissionPending = true
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async {
                self.permissionPending = false; self.refreshPermission()
                guard granted else { self.errorMessage = "请到系统设置 → 隐私与安全性 → 麦克风，允许 LocalTranscript，然后重新开始。"; return }
                self.begin()
            }
        }
    }
    private func begin() {
        guard let whisper = whisper else { return }
        cues = []; draft = ""; currentDraft = -1; lastLatency = 0
        polish.beginSession()
        let session = CaptureSession(whisper: whisper, inference: inference, language: language, threshold: Float(threshold))
        session.onChunkState = { id, final in DispatchQueue.main.async {
            self.currentDraft = final ? -1 : id
            if final { self.draft = "" }
        } }
        session.onResult = { id, result, final, latency in DispatchQueue.main.async {
            self.lastLatency = latency
            if final { self.cues += result; self.polish.append(result) }
            else if self.currentDraft == id && self.running { self.draft = result.map(\.text).joined() }
        } }
        session.onError = { message in DispatchQueue.main.async { self.errorMessage = message; if self.running { self.stop() } } }
        session.onInferenceBusy = { value in DispatchQueue.main.async { self.polish.setASRBusy(value) } }
        // Throttle the level meter to ~10 Hz without dispatching every audio frame.
        var frames = 0
        session.onLevel = { value in frames += 1; if frames % 5 == 0 { DispatchQueue.main.async { self.level = value } } }
        do {
            try session.start(); capture = session; running = true; status = "正在聆听 · 停顿约 0.8 秒后定稿"
            activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "本地麦克风转录")
            routeObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self = self, self.running else { return }
                    self.errorMessage = "音频设备配置已变化，已停止。请检查输入设备后重新开始。"; self.stop()
                }
            }
        } catch { polish.endSession(); errorMessage = error.localizedDescription; status = "无法启动麦克风" }
    }
    func stop() {
        guard running else { return }; running = false; draining = true; status = "正在完成剩余转录…"
        if let observer = routeObserver { NotificationCenter.default.removeObserver(observer); routeObserver = nil }
        capture?.stop {
            self.polish.endSession()
            self.capture = nil; self.draining = false; self.draft = ""; self.level = 0
            self.status = self.errorMessage == nil ? "已停止 · 定稿可复制或保存" : "已停止 · 请查看提示"
            if let activity = self.activity { ProcessInfo.processInfo.endActivity(activity); self.activity = nil }
        }
    }
    func newSession() {
        guard !running, !draining else { return }
        polish.beginSession(); polish.endSession()
        cues = []; draft = ""; errorMessage = nil; lastLatency = 0; level = 0
        status = ready ? "就绪" : "正在加载…"
    }
    func copy() { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(Export.txt(cues), forType: .string) }
    func save(srt: Bool) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = srt ? [UTType(filenameExtension: "srt") ?? .plainText] : [.plainText]
        panel.nameFieldStringValue = "转录-\(Date().formatted(.iso8601).replacingOccurrences(of: ":", with: "-"))" + (srt ? ".srt" : ".txt")
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do { try (srt ? Export.srt(self.cues) : Export.txt(self.cues)).write(to: url, atomically: true, encoding: .utf8) }
            catch { self.errorMessage = "保存失败：\(error.localizedDescription)" }
        }
    }
}

@MainActor struct AppMark: View {
    private var mark: NSImage? {
        Bundle.main.url(forResource: "LocalTranscriptMark", withExtension: "png").flatMap { NSImage(contentsOf: $0) }
    }
    var body: some View {
        if let mark = mark {
            Image(nsImage: mark).resizable().renderingMode(.template).scaledToFit().foregroundStyle(.primary)
        } else {
            Image(systemName: "waveform").resizable().scaledToFit().foregroundStyle(.primary)
        }
    }
}

struct TranscriptApp: App {
    var body: some Scene { WindowGroup("本地听写") { TranscriptView() } }
}

@main enum Entry {
    @MainActor static func main() async {
        if CommandLine.arguments.contains("--model-catalog-test") || CommandLine.arguments.contains("--model-download-test") {
            do { try await runModelCatalogTests(download: CommandLine.arguments.contains("--model-download-test")); exit(0) }
            catch { fputs("ERROR: \(error.localizedDescription)\n", stderr); exit(1) }
        }
        if CommandLine.arguments.contains("--context-naming-integration") {
            do { try await runContextNamingIntegration(); exit(0) }
            catch { fputs("ERROR: \(error.localizedDescription)\n", stderr); exit(1) }
        }
        if CommandLine.arguments.contains("--context-integration") {
            do { try await runContextIntegration(); exit(0) }
            catch { fputs("ERROR: \(error.localizedDescription)\n", stderr); exit(1) }
        }
        if CommandLine.arguments.contains("--polish-runtime-test") {
            do { try await runPolishRuntimeTest(); exit(0) }
            catch { fputs("ERROR: \(error.localizedDescription)\n", stderr); exit(1) }
        }
        if CommandLine.arguments.contains("--polish-test") || CommandLine.arguments.contains("--polish-integration") {
            do { try await runPolishTests(integration: CommandLine.arguments.contains("--polish-integration")); exit(0) }
            catch { fputs("ERROR: \(error.localizedDescription)\n", stderr); exit(1) }
        }
        if CommandLine.arguments.contains("--permission-status") {
            print("microphoneAuthorization=\(AVCaptureDevice.authorizationStatus(for: .audio).rawValue) (0=notDetermined, 1=restricted, 2=denied, 3=authorized)"); exit(0)
        }
        if CommandLine.arguments.contains("--self-test") || CommandLine.arguments.contains("--transcribe") {
            do { try runTests(); exit(0) } catch { fputs("ERROR: \(error.localizedDescription)\n", stderr); exit(1) }
        }
        if let icon = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"), let image = NSImage(contentsOf: icon) {
            NSApplication.shared.applicationIconImage = image
        }
        NSApplication.shared.setActivationPolicy(.regular)
        TranscriptApp.main()
    }
}
