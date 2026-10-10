import AppKit
import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import Tokenizers
import Translation

// MARK: - The two optional downloads

/// The translation models Murmur can download — see `TranslateInto` for which one translates what. Both are Apache 2.0,
/// pinned to the exact revision that was measured, and live in Application Support/Murmur/Translation. Both revisions'
/// tokenizer_config.json name their tokenizer class, so swift-transformers never reaches for its own fallback configs —
/// a resource bundle that isn't inside Murmur.app.
enum TranslationModel: String, CaseIterable, Sendable {
    case gemma, euroLLM

    var name: String { self == .gemma ? "Gemma 4" : "EuroLLM" }
    var engine: TranslateInto.Engine { self == .gemma ? .gemma : .euroLLM }

    private var repository: String {
        self == .gemma ? "mlx-community/gemma-4-e4b-it-4bit" : "stelterlab/EuroLLM-9B-Instruct-MLX-4bit"
    }
    private var revision: String {
        self == .gemma ? "475b9088d29754a3379866cf5aeb6b41acd313c2" : "38b6a2993c2942dad5efb406198b10ba5250545d"
    }

    /// Every file the model needs, with its size in bytes (from the Hub's listing of that revision).
    var files: [(name: String, bytes: Int64)] {
        switch self {
        case .gemma:
            return [("config.json", 6_628), ("generation_config.json", 208), ("tokenizer_config.json", 2_740),
                    ("tokenizer.json", 32_169_626), ("chat_template.jinja", 17_336),
                    ("model.safetensors.index.json", 240_961), ("model.safetensors", 5_146_800_534)]
        case .euroLLM:
            return [("config.json", 866), ("special_tokens_map.json", 557), ("tokenizer_config.json", 47_270),
                    ("tokenizer.json", 15_783_334), ("model.safetensors.index.json", 68_681),
                    ("model.safetensors", 5_148_790_797)]
        }
    }

    var totalBytes: Int64 { files.reduce(0) { $0 + $1.bytes } }

    /// "5.1 GB"
    var sizeLabel: String { String(format: "%.0f GB", Double(totalBytes) / 1e9) }

    func url(of file: String) -> URL {
        URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(file)")!
    }

    var directory: URL {
        AppPaths.supportDirectory.appendingPathComponent("Translation/\(rawValue)", isDirectory: true)
    }

    private var completeMarker: URL { directory.appendingPathComponent(".complete") }

    /// Every file is there, at its full size.
    var isDownloaded: Bool { FileManager.default.fileExists(atPath: completeMarker.path) }

    /// Fetches every file into a staging folder and moves it in place only once all of them arrived whole, so a
    /// half-finished download is never mistaken for a model. `progress` gets the bytes received so far.
    func download(progress: @escaping @Sendable (Int64) -> Void) async throws {
        let manager = FileManager.default
        let staging = directory.deletingLastPathComponent().appendingPathComponent(".\(rawValue)-download")
        try? manager.removeItem(at: staging)
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: staging) }

        let free = (try? AppPaths.supportDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? .max
        guard free > totalBytes + 1_000_000_000 else { throw TranslationDownloadError.noSpace(totalBytes) }

        var done: Int64 = 0
        for file in files {
            let base = done
            let destination = staging.appendingPathComponent(file.name)
            try await FileDownload.fetch(url(of: file.name), to: destination) { progress(base + $0) }
            let size = (try? manager.attributesOfItem(atPath: destination.path)[.size] as? Int64) ?? -1
            guard size == file.bytes else { throw TranslationDownloadError.incomplete(file.name) }
            done += file.bytes
            progress(done)
        }
        try? manager.removeItem(at: directory)
        try manager.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
        try manager.moveItem(at: staging, to: directory)
        manager.createFile(atPath: completeMarker.path, contents: Data())
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

enum TranslationDownloadError: LocalizedError {
    case noSpace(Int64), incomplete(String), http(Int)

    var errorDescription: String? {
        switch self {
        case .noSpace(let bytes):
            "Not enough free space — it needs about \(String(format: "%.0f", Double(bytes) / 1e9 + 1)) GB."
        case .incomplete: "The download was cut short — try again."
        case .http(let status): "The download didn’t start (\(status)) — try again later."
        }
    }
}

/// One file over URLSession with progress, written straight to `destination`.
private final class FileDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let progress: @Sendable (Int64) -> Void
    private var continuation: CheckedContinuation<Void, Error>?
    private var moveError: Error?

    private init(destination: URL, progress: @escaping @Sendable (Int64) -> Void) {
        self.destination = destination
        self.progress = progress
    }

    static func fetch(_ url: URL, to destination: URL, progress: @escaping @Sendable (Int64) -> Void) async throws {
        let download = FileDownload(destination: destination, progress: progress)
        let session = URLSession(configuration: .default, delegate: download, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.downloadTask(with: url)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                download.continuation = continuation
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        progress(totalBytesWritten)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            moveError = TranslationDownloadError.http(http.statusCode)
            return
        }
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            moveError = error
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error ?? moveError { continuation?.resume(throwing: error) } else { continuation?.resume() }
        continuation = nil
    }
}

// MARK: - What Settings and the bar show

/// The two downloads' state, for Settings ▸ Dictation and the bar — one shared instance, so a download started in
/// Settings keeps going (and keeps showing) wherever you are.
@MainActor
final class TranslationModels: ObservableObject {
    static let shared = TranslationModels()

    enum State: Equatable {
        case absent
        case downloading(received: Int64)
        case ready
        case failed(String)
    }

    @Published private(set) var states: [TranslationModel: State] = [:]
    /// Pairs macOS's translator has installed, by "from-to" — read when Translate into changes.
    @Published private(set) var appleInstalled: Set<String> = []
    /// Pairs macOS can translate after downloading its language (System Settings ▸ General ▸ Language & Region).
    @Published private(set) var appleSupported: Set<String> = []
    private var tasks: [TranslationModel: Task<Void, Never>] = [:]

    private init() {
        for model in TranslationModel.allCases { states[model] = model.isDownloaded ? .ready : .absent }
    }

    func state(_ model: TranslationModel) -> State { states[model] ?? .absent }
    func isReady(_ model: TranslationModel) -> Bool { state(model) == .ready }

    func download(_ model: TranslationModel) {
        guard tasks[model] == nil, !isReady(model) else { return }
        states[model] = .downloading(received: 0)
        tasks[model] = Task { [weak self] in
            var lastShown = Date.distantPast
            do {
                try await model.download { received in
                    Task { @MainActor [weak self] in
                        // A few updates a second is plenty for "1.2 of 5 GB".
                        guard Date().timeIntervalSince(lastShown) > 0.25 || received == model.totalBytes else { return }
                        lastShown = Date()
                        self?.states[model] = .downloading(received: received)
                    }
                }
                self?.states[model] = .ready
            } catch is CancellationError {
                self?.states[model] = .absent
            } catch {
                self?.states[model] = .failed(error.localizedDescription)
            }
            self?.tasks[model] = nil
        }
    }

    func cancel(_ model: TranslationModel) {
        tasks[model]?.cancel()
    }

    /// Asks macOS which pairs its translator can do — installed now, or after its own language download.
    func refreshApple(from: String, to: String) async {
        let status = await LanguageAvailability().status(
            from: Locale.Language(identifier: from), to: Locale.Language(identifier: to))
        let key = "\(from)-\(to)"
        switch status {
        case .installed:
            appleInstalled.insert(key)
            appleSupported.insert(key)
        case .supported:
            appleInstalled.remove(key)
            appleSupported.insert(key)
        default:
            appleInstalled.remove(key)
            appleSupported.remove(key)
        }
    }

    func appleCanTranslate(from: String, to: String) -> Bool { appleInstalled.contains("\(from)-\(to)") }
    func appleNeedsDownload(from: String, to: String) -> Bool {
        appleSupported.contains("\(from)-\(to)") && !appleInstalled.contains("\(from)-\(to)")
    }

    /// The translator for a pair right now.
    func engine(from: String, to: String) -> TranslateInto.Engine? {
        TranslateInto.engine(from: from, to: to, gemma: isReady(.gemma), euroLLM: isReady(.euroLLM),
                             apple: appleCanTranslate(from: from, to: to))
    }
}

// MARK: - Translating

/// Translates with whichever translator `TranslateInto.engine` picks and checks the result. A model is loaded on first
/// use (or ahead of time, when the dictation key goes down) and let go after ten idle minutes — Gemma 4 holds about
/// 4.5 GB while it's loaded.
actor Translator {
    static let shared = Translator()

    enum Outcome: Sendable {
        case translated(String, TranslateInto.Engine)
        case kept(TranslateInto.Problem)
    }

    private var loaded: (model: TranslationModel, container: ModelContainer)?
    private var loading: (model: TranslationModel, task: Task<ModelContainer, Error>)?
    private var lastUse = Date()
    private var idleTimer: Task<Void, Never>?

    /// Translates `text`, checks it, and says why not when it can't be used. `markers` are snippet placeholders that
    /// must come through untouched.
    func translate(_ text: String, from: String, to: String, engine: TranslateInto.Engine?,
                   markers: [String] = []) async -> Outcome {
        guard let engine else { return .kept(.unavailable) }
        let output: String
        do {
            switch engine {
            case .apple: output = try await Self.appleTranslate(text, from: from, to: to)
            case .gemma: output = try await generate(.gemma, prompt: TranslateInto.gemmaPrompt(text, to: to), source: text)
            case .euroLLM:
                output = try await generate(
                    .euroLLM, prompt: TranslateInto.euroLLMPrompt(text, from: from, to: to), source: text)
            }
        } catch {
            return .kept(.failed)
        }
        let tidied = TranslateInto.tidy(output)
        if let problem = TranslateInto.problem(source: text, output: tidied, from: from, to: to, markers: markers) {
            return .kept(problem)
        }
        return .translated(tidied, engine)
    }

    /// Gemma 4 rewriting a piece of text to a prompt in its own chat format (`SpokenCommand.gemmaPrompt`) — greedy,
    /// like a translation. The raw answer, tidied of the model's end markers. `room`: tokens allowed on top of three
    /// times the source's, for an answer that carries labels of its own (a prompt's section names, an email's subject).
    func rewrite(prompt: String, source: String, room: Int = 48) async throws -> String {
        TranslateInto.tidy(try await generate(.gemma, prompt: prompt, source: source, room: room))
    }

    /// Loads the model ahead of the dictation, so the translation doesn't wait for it.
    func prewarm(_ model: TranslationModel) async {
        _ = try? await container(for: model)
    }

    @MainActor
    private static func appleTranslate(_ text: String, from: String, to: String) async throws -> String {
        let session = TranslationSession(
            installedSource: Locale.Language(identifier: from), target: Locale.Language(identifier: to))
        return try await session.translate(text).targetText
    }

    private func container(for model: TranslationModel) async throws -> ModelContainer {
        if let loaded, loaded.model == model { return loaded.container }
        if let loading, loading.model == model { return try await loading.task.value }
        loaded = nil
        // MLX's GPU kernels: in Murmur.app they're in Contents/Resources (codesign won't seal a plain file next to the
        // binary); a build run from .build finds the copy next to itself on its own.
        if let kernels = Bundle.main.url(forResource: "mlx", withExtension: "metallib"), GPU.metallib == nil {
            GPU.metallib = kernels
        }
        Memory.clearCache()
        // A small reusable-buffer cache: the weights are what's big, and they're kept anyway.
        Memory.cacheLimit = 256 * 1024 * 1024
        let task = Task { () throws -> ModelContainer in
            try await LLMModelFactory.shared.loadContainer(from: model.directory, using: TokenizerLoader())
        }
        loading = (model, task)
        defer { loading = nil }
        let container = try await task.value
        loaded = (model, container)
        return container
    }

    private func generate(_ model: TranslationModel, prompt: String, source: String, room: Int = 48) async throws -> String {
        let container = try await container(for: model)
        lastUse = Date()
        defer { scheduleUnload() }
        let addsBOS = model == .euroLLM
        return try await container.perform { (context: ModelContext) async throws -> String in
            var tokens = context.tokenizer.encode(text: prompt, addSpecialTokens: false)
            if addsBOS, let bos = context.tokenizer.bosToken.flatMap(context.tokenizer.convertTokenToId) {
                tokens.insert(bos, at: 0)
            }
            let sourceTokens = context.tokenizer.encode(text: source, addSpecialTokens: false).count
            // Greedy, as measured; room for a translation up to three times the tokens of what was said.
            let parameters = GenerateParameters(maxTokens: min(1200, sourceTokens * 3 + room), temperature: 0)
            var output = ""
            for await event in try MLXLMCommon.generate(
                input: LMInput(tokens: MLXArray(tokens)), parameters: parameters, context: context) {
                if let chunk = event.chunk {
                    output += chunk
                    if ["<turn|>", "<end_of_turn>", "<|im_end|>"].contains(where: output.contains) { break }
                }
            }
            return output
        }
    }

    private func scheduleUnload() {
        idleTimer?.cancel()
        idleTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(600))
            guard !Task.isCancelled else { return }
            await self?.unloadIfIdle()
        }
    }

    private func unloadIfIdle() {
        guard Date().timeIntervalSince(lastUse) >= 590 else { return }
        loaded = nil
        Memory.clearCache()
    }
}

/// swift-transformers' tokenizer, as the one mlx-swift-lm asks for — the same bridge its MLXHuggingFace macro writes.
private struct TokenizerLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        TokenizerBridge(try await AutoTokenizer.from(modelFolder: directory))
    }
}

private struct TokenizerBridge: MLXLMCommon.Tokenizer {
    let upstream: any Tokenizers.Tokenizer

    init(_ upstream: any Tokenizers.Tokenizer) { self.upstream = upstream }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }
    func convertTokenToId(_ token: String) -> Int? { upstream.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { upstream.convertIdToToken(id) }
    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
                           additionalContext: [String: any Sendable]?) throws -> [Int] {
        try upstream.applyChatTemplate(messages: messages, tools: tools, additionalContext: additionalContext)
    }
}
