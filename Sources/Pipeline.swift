import Foundation
import AVFoundation

struct Cue: Identifiable, Codable {
    var id = UUID()
    let start: Double
    let end: Double
    let text: String
}

enum TranscriptError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let s) = self { return s }; return nil }
}

// All access belongs to the processing queue. Fixed capacity; never silently overwrites.
struct FloatRing {
    private var data: [Float]
    private var head = 0
    private(set) var count = 0
    init(capacity: Int) { data = Array(repeating: 0, count: capacity) }
    mutating func append(_ samples: [Float]) throws {
        guard count + samples.count <= data.count else { throw TranscriptError.message("音频缓冲已满，请停止后重试。") }
        for value in samples { data[(head + count) % data.count] = value; count += 1 }
    }
    mutating func take(_ n: Int) -> [Float] {
        let n = min(n, count)
        let result = (0..<n).map { data[(head + $0) % data.count] }
        head = (head + n) % data.count; count -= n
        return result
    }
}

// 20 ms frames, 300 ms pre-roll, 800 ms silence endpoint, 10 s hard limit.
// The same scheduler is used for microphones and file-based end-to-end tests.
final class Segmenter {
    var threshold: Float = 0.008
    var onChunk: ((Int, Double, [Float], Bool) -> Void)?
    var onLevel: ((Float) -> Void)?
    private var ring = FloatRing(capacity: 16000 * 2)
    private var pre: [Float] = []
    private var active: [Float] = []
    private var clock = 0
    private var onset = 0
    private var silence = 0
    private var voice = 0
    private var draftAt = 32000
    private(set) var sequence = 0
    func feed(_ samples: [Float]) throws {
        // Slice arbitrary input sizes so the ring remains bounded for file import too.
        for offset in stride(from: 0, to: samples.count, by: 16000) {
            try ring.append(Array(samples[offset..<min(offset + 16000, samples.count)]))
            while ring.count >= 320 { frame(ring.take(320)) }
        }
    }
    private func frame(_ values: [Float]) {
        let rms = sqrt(values.reduce(Float(0)) { $0 + $1 * $1 } / Float(values.count))
        onLevel?(rms)
        let speech = rms >= threshold
        if active.isEmpty {
            if speech { active = pre; onset = clock - pre.count; silence = 0; voice = 0; draftAt = 32000 }
            else { pre += values; if pre.count > 4800 { pre.removeFirst(pre.count - 4800) }; clock += values.count; return }
        }
        active += values
        if speech { silence = 0; voice += values.count } else { silence += values.count }
        clock += values.count
        if silence >= 12800 || active.count >= 160000 { finish() }
        else if active.count >= draftAt && voice >= 4800 {
            onChunk?(sequence, Double(onset) / 16000, active, false)
            draftAt += 32000
        }
    }
    func finish() {
        if !active.isEmpty && voice >= 3200 {
            onChunk?(sequence, Double(onset) / 16000, active, true)
        }
        if !active.isEmpty { sequence += 1 }
        active.removeAll(keepingCapacity: true); pre.removeAll(keepingCapacity: true)
        voice = 0; silence = 0
    }
    func flush() {
        if ring.count > 0 {
            var tail = ring.take(ring.count)
            tail += Array(repeating: 0, count: 320 - tail.count)
            frame(tail)
        }
        finish()
    }
}

final class PCMConverter {
    let input: AVAudioFormat
    let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    private let converter: AVAudioConverter
    init(_ input: AVAudioFormat) throws {
        self.input = input
        guard let c = AVAudioConverter(from: input, to: output) else { throw TranscriptError.message("无法转换输入音频格式。") }
        converter = c
    }
    func convert(_ buffer: AVAudioPCMBuffer, end: Bool = false) throws -> [Float] {
        let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * 16000 / input.sampleRate)) + 4096
        let out = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity)!
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, state in
            if !supplied && buffer.frameLength > 0 { supplied = true; state.pointee = .haveData; return buffer }
            state.pointee = end ? .endOfStream : .noDataNow
            return nil
        }
        if status == .error { throw error ?? NSError(domain: "PCMConverter", code: 1) }
        return Array(UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength)))
    }
}

final class WhisperEngine {
    private let context: UnsafeMutableRawPointer
    init(path: String, gpu: Bool = true) throws {
        guard let c = lt_create(path, gpu ? 1 : 0) else { throw TranscriptError.message("模型加载失败：请检查 Models/ggml-small.bin。") }
        context = c
    }
    deinit { lt_destroy(context) }
    func transcribe(_ samples: [Float], offset: Double, language: String) throws -> [Cue] {
        // Whisper requires at least one second; padding also preserves short final utterances.
        let padded = samples + Array(repeating: Float(0), count: max(0, 16000 - samples.count))
        let n = padded.withUnsafeBufferPointer { ptr in language.withCString { lt_run(context, ptr.baseAddress, Int32(ptr.count), $0) } }
        guard n >= 0 else { throw TranscriptError.message("本地推理失败，请停止后重试。") }
        let duration = Double(samples.count) / 16000
        return (0..<n).compactMap { i in
            let text = String(cString: lt_text(context, i)).trimmingCharacters(in: .whitespacesAndNewlines)
            let start = min(duration, max(0, lt_start(context, i)))
            let end = min(duration, max(start, lt_end(context, i)))
            return text.isEmpty ? nil : Cue(start: offset + start, end: offset + max(start + 0.001, end), text: text)
        }
    }
}

enum Export {
    static func txt(_ cues: [Cue]) -> String { cues.map(\.text).joined(separator: "\n") + "\n" }
    static func stamp(_ t: Double) -> String {
        let ms = max(0, Int((t * 1000).rounded()))
        return String(format: "%02d:%02d:%02d,%03d", ms / 3600000, ms / 60000 % 60, ms / 1000 % 60, ms % 1000)
    }
    static func srt(_ cues: [Cue]) -> String {
        cues.enumerated().map { i, c in "\(i + 1)\n\(stamp(c.start)) --> \(stamp(c.end))\n\(c.text)\n" }.joined(separator: "\n")
    }
}

func modelPath() -> String {
    if let path = ProcessInfo.processInfo.environment["LOCAL_TRANSCRIPT_MODEL"] { return path }
    return ModelCatalog.speechPath(ModelCatalog.selectedSpeech)
}
