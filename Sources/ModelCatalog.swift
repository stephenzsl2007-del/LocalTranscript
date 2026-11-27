import Foundation
import CryptoKit

struct SpeechModelOption: Identifiable {
    let id: String
    let title: String
    let sha1: String
}
enum ModelCatalog {
    static let speech = [
        SpeechModelOption(id: "tiny", title: "Whisper Tiny · 75 MiB", sha1: "bd577a113a864445d4c299885e0cb97d4ba92b5f"),
        SpeechModelOption(id: "base", title: "Whisper Base · 142 MiB", sha1: "465707469ff3a37a2b9b8d8f89f2f99de7299dac"),
        SpeechModelOption(id: "small", title: "Whisper Small · 466 MiB", sha1: "55356645c2b361a969dfd0ef2c5a50d530afd8d5")
    ]
    static let polish = ["qwen2.5:1.5b", "qwen3:4b-instruct"]
    static func polishTitle(_ id: String) -> String { id == "qwen2.5:1.5b" ? "Qwen 2.5 1.5B · 986 MB" : "Qwen3 4B Instruct · 2.5 GB" }
    static var selectedSpeech: String {
        let saved = UserDefaults.standard.string(forKey: "models.speech") ?? "small"
        return speech.contains { $0.id == saved } ? saved : "small"
    }
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("LocalTranscript/Models", isDirectory: true)
    }
    static func speechPath(_ id: String) -> String {
        let name = "ggml-\(id).bin"
        let candidates = [directory.appendingPathComponent(name), Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/\(name)"), Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("Models/\(name)")]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }?.path ?? candidates[0].path
    }
    static func installed(_ id: String) -> Bool { FileManager.default.fileExists(atPath: speechPath(id)) }
    static func verify(_ file: URL, sha1: String) throws {
        let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
        var hash = Insecure.SHA1()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty { hash.update(data: data) }
        let actual = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard actual == sha1 else { throw TranscriptError.message("模型校验失败，未安装。请重新下载。") }
    }
    static func downloadSpeech(_ id: String) async throws {
        guard let model = speech.first(where: { $0.id == id }) else { throw TranscriptError.message("不支持的语音模型。") }
        let url = URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-\(id).bin")!
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForResource = 3600
        let session = URLSession(configuration: configuration); defer { session.finishTasksAndInvalidate() }
        let (temporary, response) = try await session.download(from: url)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw TranscriptError.message("模型下载失败，请检查网络后重试。") }
        try Task.checkCancellation()
        try await Task.detached { try verify(temporary, sha1: model.sha1) }.value
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent("ggml-\(id).bin")
        if FileManager.default.fileExists(atPath: target.path) { _ = try FileManager.default.replaceItemAt(target, withItemAt: temporary) }
        else { try FileManager.default.moveItem(at: temporary, to: target) }
    }
}
