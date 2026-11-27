import Foundation

@MainActor func runModelCatalogTests(download: Bool) async throws {
    try require(Set(ModelCatalog.speech.map(\.id)) == Set(["tiny", "base", "small"]), "speech registry")
    try require(ModelCatalog.polish.count == 2, "polish registry")
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try Data("abc".utf8).write(to: temp); defer { try? FileManager.default.removeItem(at: temp) }
    try ModelCatalog.verify(temp, sha1: "a9993e364706816aba3e25717850c26c9cd0d89d")
    do { try ModelCatalog.verify(temp, sha1: "invalid"); throw TranscriptError.message("bad hash accepted") }
    catch TranscriptError.message(let message) { try require(message != "bad hash accepted", message) }
    if download {
        try await ModelCatalog.downloadSpeech("tiny")
        try require(ModelCatalog.installed("tiny"), "tiny download installed")
        let engine = try WhisperEngine(path: ModelCatalog.speechPath("tiny"))
        _ = try engine.transcribe(Array(repeating: Float(0), count: 16000), offset: 0, language: "auto")
        try await OllamaRuntime.shared.prepare(download: true, modelName: "qwen2.5:1.5b") { print($0) }
        let name = try await LocalPolishClient(model: "qwen2.5:1.5b").contextName(for: "整理软件项目的例会记录，保留进展和待办事项。")
        try require(!name.isEmpty && name.count <= 10, "alternate polish model inference")
        print("Alternate model generated name: \(name)")
    }
    print("PASS model registry, checksum rejection" + (download ? ", downloaded tiny inference and alternate polish model inference" : ""))
}
