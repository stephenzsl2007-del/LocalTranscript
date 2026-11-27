import Foundation
import AVFoundation

func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw TranscriptError.message("验证失败：" + message) }
}
func runTests() throws {
    if CommandLine.arguments.contains("--self-test") {
        var ring = FloatRing(capacity: 4)
        try ring.append([1, 2, 3]); try require(ring.take(2) == [1, 2], "ring first read")
        try ring.append([4, 5, 6]); try require(ring.take(4) == [3, 4, 5, 6], "ring wrap")
        do { try ring.append([1, 2, 3, 4, 5]); throw TranscriptError.message("overflow was not detected") }
        catch TranscriptError.message(let s) { try require(s != "overflow was not detected", s) }
        let s = Segmenter()
        var finals = 0; var drafts = 0; var starts: [Double] = []
        s.onChunk = { _, offset, _, final in if final { finals += 1; starts.append(offset) } else { drafts += 1 } }
        try s.feed(Array(repeating: 0, count: 16000)); try require(finals == 0 && drafts == 0, "silence rejected")
        let tone = (0..<48000).map { Float(sin(Double($0) * 0.08)) * 0.08 }
        try s.feed(tone); try s.feed(Array(repeating: 0, count: 16000)); s.flush()
        try require(finals == 1 && drafts >= 1, "VAD draft/final")
        try require(abs(starts[0] - 0.7) < 0.03, "pre-roll timestamp")
        let tail = Segmenter(); var tailFinal = false
        tail.onChunk = { _, _, _, final in if final { tailFinal = true } }
        try tail.feed(Array(tone.prefix(8001))); tail.flush(); try require(tailFinal, "stop flush short speech")
        let long = Segmenter(); var chunks = 0
        long.onChunk = { _, _, _, final in if final { chunks += 1 } }
        try long.feed(Array(repeating: Float(0.1), count: 16000 * 22)); long.flush()
        try require(chunks == 3, "hard chunk limit")
        let cue = Cue(start: 1.234, end: 2.567, text: "你好 Hello")
        try require(Export.srt([cue]).contains("00:00:01,234 --> 00:00:02,567\n你好 Hello"), "SRT Unicode/timestamps")
        // 48 kHz stereo -> 16 kHz mono, including converter tail.
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: false)!
        let converter = try PCMConverter(format)
        var total = 0
        for _ in 0..<10 {
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800)!
            buffer.frameLength = 4800
            for channel in 0..<2 { for i in 0..<4800 { buffer.floatChannelData![channel][i] = Float(sin(Double(i) * 0.04)) * 0.1 } }
            total += try converter.convert(buffer).count
        }
        let empty = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1)!
        total += try converter.convert(empty, end: true).count
        try require(abs(total - 16000) < 100, "resampling duration: \(total)")
        print("PASS ring wrap/overflow, silence gate, draft/final, stop flush, long chunking, Unicode SRT, 48k stereo resampling (\(total) samples)")
        return
    }
    guard let index = CommandLine.arguments.firstIndex(of: "--transcribe"), CommandLine.arguments.count > index + 1 else {
        throw TranscriptError.message("用法：LocalTranscript --transcribe audio.wav [--cpu] [--language zh|en|auto] [--output output-prefix]")
    }
    func option(_ flag: String) -> String? {
        guard let i = CommandLine.arguments.firstIndex(of: flag), i + 1 < CommandLine.arguments.count else { return nil }
        return CommandLine.arguments[i + 1]
    }
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
    let converter = try PCMConverter(file.processingFormat)
    let segmenter = Segmenter()
    let whisper = try WhisperEngine(path: modelPath(), gpu: !CommandLine.arguments.contains("--cpu"))
    var cues: [Cue] = []; var failure: Error?; var seconds = 0.0; var jobs = 0
    segmenter.onChunk = { _, offset, samples, final in
        guard final else { return }
        let begin = Date()
        do { cues += try whisper.transcribe(samples, offset: offset, language: option("--language") ?? "auto") }
        catch { failure = error }
        seconds += Date().timeIntervalSince(begin); jobs += 1
    }
    while file.framePosition < file.length {
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096)!
        try file.read(into: buffer)
        try segmenter.feed(converter.convert(buffer))
    }
    let empty = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1)!
    try segmenter.feed(converter.convert(empty, end: true)); segmenter.flush()
    if let failure = failure { throw failure }
    print(Export.txt(cues))
    let duration = Double(file.length) / file.processingFormat.sampleRate
    print(String(format: "audio=%.2fs inference=%.2fs RTF=%.3f chunks=%d cues=%d", duration, seconds, seconds / max(0.001, duration), jobs, cues.count))
    if let prefix = option("--output") {
        try Export.txt(cues).write(toFile: prefix + ".txt", atomically: true, encoding: .utf8)
        try Export.srt(cues).write(toFile: prefix + ".srt", atomically: true, encoding: .utf8)
    }
}
