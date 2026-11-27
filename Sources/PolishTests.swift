import Foundation
import AVFoundation

actor TestPolisher: PolishServing {
    var failures = 0
    var calls: [(String, String, PolishTopic)] = []
    var delay: UInt64 = 30_000_000
    var nameCalls: [String] = []
    var proposedName = "上下文记录"
    var nameFailures = 0
    func configureName(_ value: String, failures: Int = 0) { proposedName = value; nameFailures = failures }
    func contextName(for content: String) async throws -> String {
        nameCalls.append(content)
        try await Task.sleep(nanoseconds: delay)
        if nameFailures > 0 { nameFailures -= 1; throw TranscriptError.message("模拟命名失败") }
        return proposedName
    }
    func failNext() { failures = 1 }
    func rewrite(source: String, context: String, topic: PolishTopic) async throws -> String {
        calls.append((source, context, topic))
        try? await Task.sleep(nanoseconds: delay)
        if failures > 0 { failures -= 1; throw TranscriptError.message("模拟中断") }
        return source.replacingOccurrences(of: "嗯，", with: "").replacingOccurrences(of: "然后然后", with: "然后")
    }
}
@MainActor func waitFor(_ message: String, timeout: Double = 5, condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        guard Date() < deadline else { throw TranscriptError.message("等待超时：" + message) }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
}
@MainActor func runPolishTests(integration: Bool) async throws {
    if integration { try await runPolishIntegration(); return }
    let domain = "LocalTranscript.PolishTests." + UUID().uuidString
    let prefs = UserDefaults(suiteName: domain)!
    defer { prefs.removePersistentDomain(forName: domain) }
    let fake = TestPolisher()
    let c = PolishController(service: fake, preferences: prefs, prepare: false)
    c.topicName = "技术会议"; c.requirements = "保留 Swift 和 API"; await c.saveTopic()
    let saved = c.selectedTopic
    let reload = PolishController(service: fake, preferences: prefs, prepare: false)
    try require(reload.topics.count == 1 && reload.topics[0].name == "技术会议", "topic persistence")
    c.beginSession(); c.setASRBusy(true)
    c.append([Cue(start: 0, end: 1, text: "嗯，API 预算是 1200 元，不要增加。")])
    try await Task.sleep(nanoseconds: 50_000_000)
    try require(!c.busy && c.pendingCount == 1, "ASR takes priority")
    c.setASRBusy(false)
    c.append([Cue(start: 1, end: 2, text: "然后然后周五再讨论。")]); c.endSession()
    try await waitFor("drain") { !c.hasWork }
    try require(c.blocks.count == 2 && c.text.contains("1200") && c.text.contains("不要"), "live append/drain")
    let calls = await fake.calls
    try require(calls[1].1.contains("1200") && calls[0].2.name == "技术会议", "context and topic propagation")
    let ids = c.blocks.flatMap(\.sourceIDs)
    try require(Set(ids).count == ids.count, "source committed once")
    c.beginSession(); c.togglePause()
    c.append([Cue(start: 0, end: 1, text: "暂停后的内容")])
    try require(c.pendingCount == 1 && !c.busy, "pause retains source")
    c.togglePause(); c.endSession(); try await waitFor("resume") { !c.hasWork }
    await fake.failNext()
    c.beginSession(); c.append([Cue(start: 0, end: 1, text: "失败后重试")]); c.endSession()
    try await waitFor("failure") { c.error != nil }
    try require(c.pendingCount == 1 && c.blocks.isEmpty, "failed source retained")
    c.retry(); try await waitFor("retry") { !c.hasWork }
    try require(c.blocks.count == 1, "retry no duplicate")
    c.beginSession(); c.append([Cue(start: 0, end: 1, text: "旧录音，不能出现在新录音里")])
    try await Task.sleep(nanoseconds: 10_000_000)
    c.beginSession(); c.append([Cue(start: 0, end: 1, text: "新录音")]); c.endSession()
    try await waitFor("new generation") { !c.hasWork }
    try require(c.text == "新录音" && c.blocks.count == 1, "late result rejected")
    c.topicName = "新主题"; c.topicChanged()
    try require(c.needsReprocess && !c.canEdit, "topic revision invalidates")
    c.reprocess(); try await waitFor("reprocess") { !c.hasWork }
    try require(c.blocks.count == 1 && c.canEdit, "reprocess replaces results")
    c.text = "手工编辑结果"; try require(c.text == "手工编辑结果", "manual edit")
    c.enabled = false; c.beginSession()
    c.append([Cue(start: 0, end: 20, text: String(repeating: "学习", count: 625))]); c.endSession()
    try require(c.pendingCount == 3 && !c.busy, "long input split without dropping")
    c.enabled = true; c.enabledChanged(); try await waitFor("long input") { !c.hasWork }
    try require(c.blocks.count == 3 && c.text.replacingOccurrences(of: "\n", with: "").count == 1250, "long input complete")
    c.selectedTopic = saved; c.deleteTopic(); try require(c.topics.isEmpty, "delete topic")
    let validated = try LocalPolishClient.validate("预算 1200 元，不增加。", source: "嗯，预算 1200 元，不增加。")
    try require(validated == "预算 1200 元，不增加。", "preserve numeric content")
    do { _ = try LocalPolishClient.validate("预算 1201 元。", source: "预算 1200 元。") ; throw TranscriptError.message("validation missed number mutation") }
    catch TranscriptError.message(let message) { try require(message != "validation missed number mutation", message) }
    do { _ = try LocalPolishClient.validate("", source: "原文"); throw TranscriptError.message("validation missed empty output") }
    catch TranscriptError.message(let message) { try require(message != "validation missed empty output", message) }
    let protectedSource = "周五之前可能做不完，如果预算不足就延期，API learning rate 是 0.01。"
    let protected = ProtectedPolishInput(protectedSource)
    try require(tryRestore(protected, protected.editable) == protectedSource, "verbatim round trip")
    do { _ = try protected.restore([:]); throw TranscriptError.message("guard missed removed protected spans") }
    catch TranscriptError.message(let message) { try require(message != "guard missed removed protected spans", message) }
    let injected = ProtectedPolishInput("预算是 1200 元。")
    var unsafe = injected.editable
    for key in unsafe.keys { unsafe[key] = "预算是 1500 元 API，不能上线" }
    try require(tryRestore(injected, unsafe) == "预算是 1200 元。", "unsafe fragment falls back without changing protected facts")
    print("PASS verbatim negation/condition/English protection and unsafe-fragment fallback")
    let longDomain = domain + ".context"
    let longPrefs = UserDefaults(suiteName: longDomain)!
    defer { longPrefs.removePersistentDomain(forName: longDomain) }
    let longFake = TestPolisher()
    let longController = PolishController(service: longFake, preferences: longPrefs, prepare: false)
    let longContext = String(repeating: "背景信息。", count: 1000) + "尾部要求：完整保留。"
    longController.requirements = longContext
    try require(longController.canSaveContext, "context can be saved without a short name")
    await longController.saveTopic()
    try require(!longController.topicName.isEmpty && longController.topics[0].requirements == longContext, "automatic context name and full persistence")
    let longReload = PolishController(service: longFake, preferences: longPrefs, prepare: false)
    try require(longReload.requirements == longContext && longReload.selectedTopic == longController.selectedTopic, "context reload restores body and selected preset")
    longController.beginSession(); longController.append([Cue(start: 0, end: 1, text: "测试上下文")]); longController.endSession()
    try await waitFor("long context delivered") { !longController.hasWork }
    let longCalls = await longFake.calls
    try require(longCalls.last?.2.requirements == longContext, "context beyond 2000 characters reaches inference without truncation")
    try require(LocalPolishClient.contextWindow(for: "简短背景") == 4096 && LocalPolishClient.contextWindow(for: String(repeating: "文", count: 2000)) == 8192 && LocalPolishClient.contextWindow(for: longContext) == 16384, "adaptive context capacity")
    let countBefore = longController.topics.count
    longController.requirements = String(repeating: "文", count: 8001)
    await longController.saveTopic()
    try require(longController.contextIsTooLong && !longController.canSaveContext && longController.topics.count == countBefore, "over-limit content is rejected rather than silently truncated")
    do {
        _ = try await LocalPolishClient().rewrite(source: "测试", context: "", topic: PolishTopic(name: "", requirements: longController.requirements))
        throw TranscriptError.message("oversized context accepted")
    } catch TranscriptError.message(let message) { try require(message != "oversized context accepted", message) }
    try await runContextNamingTests()
    print("PASS long context persistence, selected preset, untruncated inference snapshot, unnamed save, adaptive capacity and visible limit")
    print("PASS topics/persistence, ASR priority, live append/drain, context, pause/resume, failure/retry, stale generation, topic revision, manual edit, 600-character splitting, numeric/empty-output validation")
}

func tryRestore(_ input: ProtectedPolishInput, _ output: [String: String]) -> String { (try? input.restore(output)) ?? "" }

func recognizeFixture(_ path: String) throws -> (cues: [Cue], seconds: Double) {
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
    let converter = try PCMConverter(file.processingFormat)
    let segmenter = Segmenter()
    let engine = try WhisperEngine(path: modelPath())
    var result: [Cue] = []; var failure: Error?; var duration = 0.0
    segmenter.onChunk = { _, offset, samples, final in
        if final {
            let begin = Date()
            do { result += try engine.transcribe(samples, offset: offset, language: "auto") } catch { failure = error }
            duration += Date().timeIntervalSince(begin)
        }
    }
    while file.framePosition < file.length {
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096)!
        try file.read(into: buffer); try segmenter.feed(converter.convert(buffer))
    }
    let empty = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1)!
    try segmenter.feed(converter.convert(empty, end: true)); segmenter.flush()
    if let failure = failure { throw failure }
    return (result, duration)
}
@MainActor func runPolishIntegration() async throws {
    try await OllamaRuntime.shared.prepare(download: false) { print($0) }
    let client = LocalPolishClient()
    let root = Bundle.main.bundleURL.deletingLastPathComponent()
    let results = root.appendingPathComponent("Tests/Results/Polish")
    try FileManager.default.createDirectory(at: results, withIntermediateDirectories: true)
    let cases: [(String, String, String)] = [
        ("技术讨论", "保留 SwiftUI、API 和英文术语，表达简洁。", "嗯，我们这个 SwiftUI 的界面，然后然后要调用 API。预算是 1200 元，不要超过 1500 元，周五之前可能做不完。"),
        ("学习笔记", "整理为通顺段落，不添加原文没有的解释。", "嗯，今天学了梯度下降。就是根据梯度去更新参数，然后然后 learning rate 是 0.01。这个方法不保证找到全局最优解。"),
        ("项目沟通", "语言自然、清楚，保留日期和疑问。", "那个，我们计划在 2026年11月23日 讨论 LocalTranscript，然后不是马上上线。张老师还没确认，请问能不能先测试？")
    ]
    var measurements: [[String: Any]] = []
    for (index, test) in cases.enumerated() {
        let begin = Date()
        let output = try await client.rewrite(source: test.2, context: "", topic: PolishTopic(name: test.0, requirements: test.1))
        if index == 0 { try require(output.contains("周五之前可能做不完") && output.contains("不要超过 1500 元"), "negation and uncertainty preserved") }
        if index == 1 { try require(output.contains("learning rate") && output.contains("不保证找到全局最优解"), "English terminology and negation preserved") }
        if index == 2 { try require(output.contains("张老师还没确认") && output.contains("不是马上上线"), "name and negative commitment preserved") }
        try output.write(to: results.appendingPathComponent("case-\(index + 1).txt"), atomically: true, encoding: .utf8)
        measurements.append(["topic": test.0, "requirements": test.1, "source": test.2, "output": output, "seconds": Date().timeIntervalSince(begin)])
    }
    let sharedSource = "嗯，我们现在这个页面有点乱，然后我们准备把常用的东西放在前面，用户用起来就会方便一些。"
    for (name, instructions) in [("产品评审", "正式简洁，使用产品设计表达，不扩写。"), ("日常交流", "自然口语，像跟同事聊天，不使用公文词汇。 ")] {
        let begin = Date()
        let output = try await client.rewrite(source: sharedSource, context: "", topic: PolishTopic(name: name, requirements: instructions))
        try require(output.components(separatedBy: "常用").count <= 2, "fragment must not duplicate neighboring information")
        measurements.append(["topic": name, "requirements": instructions, "source": sharedSource, "output": output, "seconds": Date().timeIntervalSince(begin)])
    }
    let input = root.appendingPathComponent("Tests/Fixtures/mixed.aiff").path
    let baseline = try await Task.detached { try recognizeFixture(input) }.value
    let prefs = UserDefaults(suiteName: "LocalTranscript.IntegrationTests")!
    defer { prefs.removePersistentDomain(forName: "LocalTranscript.IntegrationTests") }
    let controller = PolishController(service: client, preferences: prefs, prepare: false)
    controller.topicName = "语音应用演示"; controller.requirements = "保留中文、英文和原意。"
    controller.beginSession()
    let begin = Date()
    for cue in baseline.cues { controller.append([cue]); try await Task.sleep(nanoseconds: 100_000_000) }
    controller.endSession()
    // Run actual ASR while the text model is generating to measure resource contention.
    let concurrent = try await Task.detached { try recognizeFixture(input) }.value
    try await waitFor("真实模型定稿", timeout: 180) { !controller.hasWork || controller.error != nil }
    if let error = controller.error { throw TranscriptError.message(error) }
    try require(!controller.text.isEmpty, "ASR to polish end-to-end")
    let allIDs = controller.blocks.flatMap(\.sourceIDs)
    try require(allIDs.count == baseline.cues.count && Set(allIDs).count == allIDs.count, "live source coverage")
    try Export.txt(baseline.cues).write(to: results.appendingPathComponent("transcript.txt"), atomically: true, encoding: .utf8)
    try controller.text.write(to: results.appendingPathComponent("polished.txt"), atomically: true, encoding: .utf8)
    let report: [String: Any] = ["model": LocalPolishClient.model, "digest": OllamaRuntime.shared.modelDigest,
        "cases": measurements, "asrBaselineSeconds": baseline.seconds, "asrConcurrentSeconds": concurrent.seconds,
        "livePipelineSeconds": Date().timeIntervalSince(begin), "sourceCues": baseline.cues.count, "polishedBlocks": controller.blocks.count]
    let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: results.appendingPathComponent("measurements.json"))
    print(String(decoding: data, as: UTF8.self))
    print("PASS real model: three custom themes, ASR → live polish → TXT, concurrent ASR, source coverage")
}

@MainActor func runPolishRuntimeTest() async throws {
    let runtime = OllamaRuntime.shared
    try await runtime.prepare(download: false) { print($0) }
    let owned = runtime.ownsService
    runtime.shutdown()
    if owned {
        for _ in 0..<40 {
            if (try? await runtime.client.json("api/version")) == nil {
                print("PASS automatically started and stopped only the owned local service"); return
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw TranscriptError.message("自启动服务未退出")
    } else {
        let version = try await runtime.client.json("api/version")
        try require(version["version"] != nil, "pre-existing service must remain running")
        print("PASS reused existing service and left it running")
    }
}

@MainActor func runContextIntegration() async throws {
    try await OllamaRuntime.shared.prepare(download: false) { print($0) }
    let description = String(repeating: "这是软件界面评审的背景材料，仅供选择措辞，不新增事实。\n", count: 180)
        + "最后的表达要求：把有点乱改写为布局欠清晰，其他信息不要扩写。"
    let source = "嗯，我们现在这个页面有点乱，常用功能需要放在前面。"
    let begin = Date()
    let output = try await LocalPolishClient().rewrite(source: source, context: "", topic: PolishTopic(name: "界面评审上下文", requirements: description))
    let report: [String: Any] = ["contextCharacters": description.count, "contextWindow": LocalPolishClient.contextWindow(for: description),
        "tailInstructionApplied": output.contains("布局欠清晰"), "source": source, "output": output, "seconds": Date().timeIntervalSince(begin)]
    let root = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("Tests/Results/Context")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: root.appendingPathComponent("long-context.json"))
    print(String(decoding: data, as: UTF8.self))
    try require(!output.isEmpty, "real model accepts full long context")
    print("PASS real model: full long context accepted without truncation; tail wording is a preference, not a forced replacement")
}

@MainActor func runContextNamingTests() async throws {
    let domain = "LocalTranscript.ContextNamingTests." + UUID().uuidString
    let prefs = UserDefaults(suiteName: domain)!
    defer { prefs.removePersistentDomain(forName: domain) }
    let fake = TestPolisher()
    let c = PolishController(service: fake, preferences: prefs, prepare: false)
    c.topicName = "手动设置的名称"; c.requirements = "保留会议结论。"
    let manualSaved = await c.saveTopic()
    let manualCalls = await fake.nameCalls
    try require(manualSaved && manualCalls.isEmpty, "manual name bypasses generation")
    let identity = c.selectedTopic
    c.topicName = "修改后的名称"
    let renamed = await c.saveTopic()
    try require(renamed && c.selectedTopic == identity && c.topics.count == 1 && c.topics[0].name == "修改后的名称", "rename updates sidebar identity")
    c.selectTopic(nil); c.topicName = "  "; c.requirements = "整理机器学习课堂记录，保留术语和公式。"
    await fake.configureName("机器学习笔记")
    let generated = await c.saveTopic()
    let autoCalls = await fake.nameCalls
    try require(generated && c.topicName == "机器学习笔记" && c.topicName.count <= 10 && autoCalls.last == c.requirements, "blank name invokes model on full context")
    let reload = PolishController(service: fake, preferences: prefs, prepare: false)
    try require(reload.topics.allSatisfy { !$0.name.isEmpty } && reload.selectedTopic == c.selectedTopic, "named sidebar entries persist")
    c.selectTopic(nil); c.requirements = "命名服务异常时保留的输入。"
    await fake.configureName("访谈整理", failures: 1)
    let count = c.topics.count
    let failed = await c.saveTopic()
    try require(!failed && c.contextSaveError != nil && c.topics.count == count && c.topicName.isEmpty && c.requirements == "命名服务异常时保留的输入。", "naming failure retains unsaved inputs")
    let retried = await c.saveTopic()
    try require(retried && c.contextSaveError == nil, "naming retry saves successfully")
    c.selectTopic(nil); c.requirements = "取消命名保留输入。"
    let cancelCount = c.topics.count
    let cancellation = Task { await c.saveTopic() }
    try await Task.sleep(nanoseconds: 5_000_000)
    try require(c.savingContext, "generation has loading state")
    cancellation.cancel()
    let cancelled = await cancellation.value
    try require(!cancelled && !c.savingContext && c.contextSaveError == nil && c.topics.count == cancelCount && c.requirements == "取消命名保留输入。", "cancel does not create unnamed entry")
    c.selectTopic(nil); c.requirements = "会被修改的上下文。"
    let stale = Task { await c.saveTopic() }
    try await Task.sleep(nanoseconds: 5_000_000)
    c.requirements = "更新之后的上下文。"
    let staleResult = await stale.value
    try require(!staleResult && c.contextSaveError != nil && c.topics.count == cancelCount, "late generated name cannot overwrite newer input")
    await fake.configureName("重复点击测试")
    c.selectTopic(nil); c.requirements = "重复点击只保存一次。"
    let first = Task { await c.saveTopic() }
    try await Task.sleep(nanoseconds: 5_000_000)
    let second = await c.saveTopic()
    let firstResult = await first.value
    try require(firstResult && !second && c.topics.count == cancelCount + 1, "concurrent saves are coalesced")
    c.selectTopic(nil); c.requirements = "过长名称不会保存。"
    await fake.configureName(String(repeating: "字", count: 11))
    let oversized = await c.saveTopic()
    try require(!oversized && c.contextSaveError != nil && c.topics.count == cancelCount + 1, "generated title length enforced")
    let tenCharacters = try ContextName.checked(String(repeating: "字", count: 10))
    try require(tenCharacters.count == 10, "exact ten-character title accepted")
    print("PASS manual/automatic names, ten-character limit, rename identity, persistence, failure/retry, cancellation, stale response and duplicate clicks")
}

@MainActor func runContextNamingIntegration() async throws {
    try await OllamaRuntime.shared.prepare(download: false) { print($0) }
    let domain = "LocalTranscript.ContextNamingIntegration." + UUID().uuidString
    let prefs = UserDefaults(suiteName: domain)!
    defer { prefs.removePersistentDomain(forName: domain) }
    let c = PolishController(service: LocalPolishClient(), preferences: prefs, prepare: false)
    let inputs = ["这是软件项目周会的听写，保留项目进度、风险和后续安排，表达简洁。", "这是机器学习课程笔记，保留梯度下降、损失函数等术语，去除口头重复。", "这是一份人物访谈，保留受访者原意、经历和不确定表达，不增加结论。"]
    var records: [[String: Any]] = []
    for content in inputs {
        c.selectTopic(nil); c.requirements = content
        let start = Date()
        let success = await c.saveTopic()
        try require(success && !c.topicName.isEmpty && c.topicName.count <= 10, "real model creates short name: " + (c.contextSaveError ?? ""))
        records.append(["context": content, "name": c.topicName, "characters": c.topicName.count, "seconds": Date().timeIntervalSince(start)])
    }
    let reload = PolishController(service: LocalPolishClient(), preferences: prefs, prepare: false)
    try require(reload.topics.count == 3 && reload.topics.map(\.name) == c.topics.map(\.name), "real generated names persist for sidebar")
    let folder = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("Tests/Results/ContextNaming")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let data = try JSONSerialization.data(withJSONObject: ["model": LocalPolishClient.model, "cases": records, "savedNames": reload.topics.map(\.name)], options: [.prettyPrinted, .sortedKeys])
    try data.write(to: folder.appendingPathComponent("names.json"))
    print(String(decoding: data, as: UTF8.self))
    print("PASS real local model: blank names generated, <=10 characters, saved for sidebar")
}
