import Benchmark
import Dispatch
import Foundation
import SyntaxEditorCore
import SyntaxEditorReferenceSamples

let benchmarks: @Sendable () -> Void = {
    HighlightBenchmarkSuite(environment: ProcessInfo.processInfo.environment).register()
}

private struct HighlightBenchmarkSuite: Sendable {
    let environment: [String: String]

    func register() {
        let options = HighlightBenchmarkOptions(environment: environment)
        for benchmarkCase in HighlightBenchmarkCase.cases(options: options) {
            let workload = BenchmarkWorkload(benchmarkCase: benchmarkCase)
            registerHighlightBenchmarks(workload: workload, options: options)
            registerTypingBenchmarks(workload: workload, options: options)
        }
    }

    private func registerHighlightBenchmarks(
        workload: BenchmarkWorkload,
        options: HighlightBenchmarkOptions
    ) {
        Benchmark(
            benchmarkName(workload: workload, scenario: "highlight/full-reset"),
            configuration: configuration(workload: workload, options: options)
        ) { benchmark in
            await HighlightBenchmarkRunner.fullReset(
                benchmark: benchmark,
                workload: workload
            )
        }

        Benchmark(
            benchmarkName(workload: workload, scenario: "highlight/incremental-update"),
            configuration: configuration(workload: workload, options: options)
        ) { benchmark in
            await HighlightBenchmarkRunner.incrementalUpdate(
                benchmark: benchmark,
                workload: workload
            )
        }

        guard workload.language.supportsSyntaxHighlighting else { return }

        if workload.language.emitsSyntacticFastPass {
            Benchmark(
                benchmarkName(workload: workload, scenario: "highlight/full-reset/fast-pass"),
                configuration: configuration(workload: workload, options: options, phase: "fast-pass")
            ) { benchmark in
                await HighlightBenchmarkRunner.phasedFullReset(
                    benchmark: benchmark,
                    workload: workload,
                    targetPhase: .syntacticFastPass
                )
            }
        }

        Benchmark(
            benchmarkName(workload: workload, scenario: "highlight/full-reset/complete"),
            configuration: configuration(workload: workload, options: options, phase: "complete")
        ) { benchmark in
            await HighlightBenchmarkRunner.phasedFullReset(
                benchmark: benchmark,
                workload: workload,
                targetPhase: .complete
            )
        }

        if workload.language.emitsSyntacticFastPass {
            Benchmark(
                benchmarkName(workload: workload, scenario: "highlight/incremental/fast-pass"),
                configuration: configuration(workload: workload, options: options, phase: "fast-pass")
            ) { benchmark in
                await HighlightBenchmarkRunner.phasedIncrementalUpdate(
                    benchmark: benchmark,
                    workload: workload,
                    targetPhase: .syntacticFastPass
                )
            }
        }

        Benchmark(
            benchmarkName(workload: workload, scenario: "highlight/incremental/complete"),
            configuration: configuration(workload: workload, options: options, phase: "complete")
        ) { benchmark in
            await HighlightBenchmarkRunner.phasedIncrementalUpdate(
                benchmark: benchmark,
                workload: workload,
                targetPhase: .complete
            )
        }
    }

    private func registerTypingBenchmarks(
        workload: BenchmarkWorkload,
        options: HighlightBenchmarkOptions
    ) {
        if options.typingEdits > 0 {
            Benchmark(
                benchmarkName(workload: workload, scenario: "typing/update-sequence"),
                configuration: configuration(workload: workload, options: options)
            ) { benchmark in
                await HighlightBenchmarkRunner.typingUpdateSequence(
                    benchmark: benchmark,
                    workload: workload,
                    editCount: options.typingEdits,
                    anchor: options.typingAnchor
                )
            }
        }

        guard workload.language.emitsSyntacticFastPass, options.typeText.isEmpty == false else {
            return
        }

        Benchmark(
            benchmarkName(workload: workload, scenario: "typing/cancelled-fast-pass"),
            configuration: configuration(workload: workload, options: options)
        ) { benchmark in
            await HighlightBenchmarkRunner.cancelledFastPassTyping(
                benchmark: benchmark,
                workload: workload,
                typeText: options.typeText,
                typeAfter: options.typeAfter,
                repeats: options.typeRepeat
            )
        }
    }

    private func configuration(
        workload: BenchmarkWorkload,
        options: HighlightBenchmarkOptions,
        phase: String? = nil
    ) -> Benchmark.Configuration {
        var tags = [
            "case": workload.name,
            "language": workload.language.identifier,
            "lines": workload.lineCount.description,
            "repeat": workload.repeatSource.description,
        ]
        if let phase {
            tags["phase"] = phase
        }

        return .init(
            metrics: HighlightBenchmarkMetrics.all,
            tags: tags,
            warmupIterations: 0,
            maxDuration: .seconds(60),
            maxIterations: options.iterations
        )
    }

    private func benchmarkName(workload: BenchmarkWorkload, scenario: String) -> String {
        "\(workload.name)/\(scenario)"
    }
}

private enum HighlightBenchmarkRunner {
    static func fullReset(
        benchmark: Benchmark,
        workload: BenchmarkWorkload
    ) async {
        let engine = SyntaxHighlighterEngine()
        benchmark.startMeasurement()
        let result = await engine.reset(
            source: workload.source,
            language: workload.language,
            revision: 0
        )
        benchmark.stopMeasurement()
        recordMetadata(benchmark, source: workload.source, result: result)
    }

    static func incrementalUpdate(
        benchmark: Benchmark,
        workload: BenchmarkWorkload
    ) async {
        let engine = SyntaxHighlighterEngine()
        _ = await engine.reset(source: workload.source, language: workload.language, revision: 0)

        benchmark.startMeasurement()
        let result = await update(
            engine: engine,
            workload: workload,
            revision: 1
        )
        benchmark.stopMeasurement()
        recordMetadata(benchmark, source: workload.updatedSource, result: result)
    }

    static func phasedFullReset(
        benchmark: Benchmark,
        workload: BenchmarkWorkload,
        targetPhase: SyntaxEditorHighlighting.Result.Phase
    ) async {
        let engine = SyntaxHighlighterEngine()
        benchmark.startMeasurement()
        let stream = await engine.resetPhases(
            source: workload.source,
            language: workload.language,
            revision: 0
        )
        await measurePhase(
            benchmark: benchmark,
            stream: stream,
            source: workload.source,
            targetPhase: targetPhase
        )
    }

    static func phasedIncrementalUpdate(
        benchmark: Benchmark,
        workload: BenchmarkWorkload,
        targetPhase: SyntaxEditorHighlighting.Result.Phase
    ) async {
        let engine = SyntaxHighlighterEngine()
        _ = await engine.reset(source: workload.source, language: workload.language, revision: 0)

        benchmark.startMeasurement()
        let stream: AsyncStream<SyntaxEditorHighlighting.Result>
        if let mutation = workload.mutation {
            stream = await engine.updatePhases(
                source: workload.updatedSource,
                language: workload.language,
                mutation: mutation,
                revision: 1
            )
        } else {
            stream = await engine.resetPhases(
                source: workload.updatedSource,
                language: workload.language,
                revision: 1
            )
        }
        await measurePhase(
            benchmark: benchmark,
            stream: stream,
            source: workload.updatedSource,
            targetPhase: targetPhase
        )
    }

    static func typingUpdateSequence(
        benchmark: Benchmark,
        workload: BenchmarkWorkload,
        editCount: Int,
        anchor: TypingAnchor
    ) async {
        var currentSource = typingBenchmarkSeededSource(
            workload.source,
            language: workload.language,
            anchor: anchor
        )
        let engine = SyntaxHighlighterEngine()
        var lastResult = await engine.reset(
            source: currentSource,
            language: workload.language,
            revision: 0
        )
        var latencies: [Int] = []
        latencies.reserveCapacity(editCount)

        benchmark.startMeasurement()
        for editIndex in 0..<editCount {
            let updatedSource = typingEditSource(from: currentSource)
            let mutation = SyntaxEditorTextChange.Replacement.singleReplacement(
                from: currentSource,
                to: updatedSource
            )

            let start = DispatchTime.now().uptimeNanoseconds
            if let mutation {
                lastResult = await engine.update(
                    source: updatedSource,
                    language: workload.language,
                    mutation: mutation,
                    revision: editIndex + 1
                )
            } else {
                lastResult = await engine.reset(
                    source: updatedSource,
                    language: workload.language,
                    revision: editIndex + 1
                )
            }
            latencies.append(elapsedNanoseconds(since: start))
            currentSource = updatedSource
        }
        benchmark.stopMeasurement()

        for latency in latencies {
            benchmark.measurement(HighlightBenchmarkMetrics.typingEditLatencyNanoseconds, latency)
        }
        recordMetadata(benchmark, source: currentSource, result: lastResult)
    }

    static func cancelledFastPassTyping(
        benchmark: Benchmark,
        workload: BenchmarkWorkload,
        typeText: String,
        typeAfter: String?,
        repeats: Int
    ) async {
        var currentSource = workload.source
        var caret = insertionPoint(in: currentSource, typeAfter: typeAfter)
        let insertions = Array(repeating: Array(typeText), count: repeats).flatMap { $0 }
        guard insertions.isEmpty == false else {
            benchmark.error("typing/cancelled-fast-pass requires at least one inserted character")
            return
        }

        let engine = SyntaxHighlighterEngine()
        _ = await engine.reset(source: currentSource, language: workload.language, revision: 0)

        var fastPassLatencies: [Int] = []
        fastPassLatencies.reserveCapacity(insertions.count)
        var finalCompleteResult: SyntaxEditorHighlighting.Result?
        var finalSettleLatency: Int?
        var revision = 1
        var stoppedMeasurement = false

        benchmark.startMeasurement()
        for index in insertions.indices {
            let insertion = String(insertions[index])
            let mutation = SyntaxEditorTextChange.Replacement(
                location: caret,
                length: 0,
                replacement: insertion
            )
            let nextSource = (currentSource as NSString).replacingCharacters(
                in: NSRange(location: caret, length: 0),
                with: insertion
            )
            let request = SyntaxEditorHighlighting.Request(
                source: nextSource,
                language: workload.language,
                revision: revision,
                operation: .update(mutation)
            )

            let start = DispatchTime.now().uptimeNanoseconds
            let stream = await engine.replaceCurrentRequest(with: request)
            var iterator = stream.makeAsyncIterator()
            let firstResult = await iterator.next()
            fastPassLatencies.append(elapsedNanoseconds(since: start))

            if firstResult == nil {
                benchmark.stopMeasurement()
                benchmark.error("typing/cancelled-fast-pass produced no result")
                return
            }
            if firstResult?.phase != .syntacticFastPass {
                benchmark.stopMeasurement()
                benchmark.error("typing/cancelled-fast-pass produced \(String(describing: firstResult?.phase)) instead of syntacticFastPass")
                return
            }

            if index == insertions.index(before: insertions.endIndex) {
                benchmark.stopMeasurement()
                stoppedMeasurement = true
                let settleStart = DispatchTime.now().uptimeNanoseconds
                while let result = await iterator.next() {
                    if result.phase == .complete {
                        finalCompleteResult = result
                    }
                }
                finalSettleLatency = elapsedNanoseconds(since: settleStart)
            }

            currentSource = nextSource
            caret += (insertion as NSString).length
            revision += 1
        }
        if stoppedMeasurement == false {
            benchmark.stopMeasurement()
        }

        for latency in fastPassLatencies {
            benchmark.measurement(HighlightBenchmarkMetrics.typingFastPassLatencyNanoseconds, latency)
        }
        if let finalSettleLatency {
            benchmark.measurement(HighlightBenchmarkMetrics.typingSettleLatencyNanoseconds, finalSettleLatency)
        }

        let settled: SyntaxEditorHighlighting.Result
        if let finalCompleteResult {
            settled = finalCompleteResult
        } else {
            settled = await engine.update(
                source: currentSource,
                language: workload.language,
                mutation: SyntaxEditorTextChange.Replacement(location: 0, length: 0, replacement: ""),
                revision: revision
            )
        }
        let settledTokens = await engine.currentTokens()
        let freshEngine = SyntaxHighlighterEngine()
        _ = await freshEngine.reset(source: currentSource, language: workload.language, revision: 0)
        let freshTokens = await freshEngine.currentTokens()
        let matchesFresh = settledTokens == freshTokens
        let completeRefreshRanges = finalCompleteResult?.refreshRanges ?? settled.refreshRanges
        let completeRefreshTotalLength = completeRefreshRanges.reduce(0) { $0 + $1.length }

        benchmark.measurement(HighlightBenchmarkMetrics.settleEqualsFresh, matchesFresh ? 1 : 0)
        benchmark.measurement(
            HighlightBenchmarkMetrics.typingCompleteRefreshRangeCount,
            completeRefreshRanges.count
        )
        benchmark.measurement(
            HighlightBenchmarkMetrics.typingCompleteRefreshTotalLength,
            completeRefreshTotalLength
        )
        if matchesFresh == false {
            benchmark.error("typing/cancelled-fast-pass did not settle to a fresh highlight result")
        }
        recordMetadata(
            benchmark,
            source: currentSource,
            tokenCount: settledTokens.count,
            refreshRanges: settled.refreshRanges
        )
    }

    private static func measurePhase(
        benchmark: Benchmark,
        stream: AsyncStream<SyntaxEditorHighlighting.Result>,
        source: String,
        targetPhase: SyntaxEditorHighlighting.Result.Phase
    ) async {
        var selectedResult: SyntaxEditorHighlighting.Result?
        var stoppedMeasurement = false

        for await result in stream {
            guard result.phase == targetPhase else {
                continue
            }

            if selectedResult == nil || targetPhase != .syntacticFastPass {
                selectedResult = result
            }
            if targetPhase == .syntacticFastPass, stoppedMeasurement == false {
                benchmark.stopMeasurement()
                stoppedMeasurement = true
            }
        }

        if stoppedMeasurement == false {
            benchmark.stopMeasurement()
        }
        guard let selectedResult else {
            benchmark.error("Missing \(targetPhase) result")
            return
        }
        recordMetadata(benchmark, source: source, result: selectedResult)
    }

    private static func update(
        engine: SyntaxHighlighterEngine,
        workload: BenchmarkWorkload,
        revision: Int
    ) async -> SyntaxEditorHighlighting.Result {
        if let mutation = workload.mutation {
            await engine.update(
                source: workload.updatedSource,
                language: workload.language,
                mutation: mutation,
                revision: revision
            )
        } else {
            await engine.reset(
                source: workload.updatedSource,
                language: workload.language,
                revision: revision
            )
        }
    }

    private static func recordMetadata(
        _ benchmark: Benchmark,
        source: String,
        result: SyntaxEditorHighlighting.Result
    ) {
        recordMetadata(
            benchmark,
            source: source,
            tokenCount: result.tokens.count,
            refreshRanges: result.refreshRanges
        )
    }

    private static func recordMetadata(
        _ benchmark: Benchmark,
        source: String,
        tokenCount: Int,
        refreshRanges: [NSRange]
    ) {
        let refreshRange = unionRefreshRange(refreshRanges)
        benchmark.measurement(HighlightBenchmarkMetrics.utf16Length, (source as NSString).length)
        benchmark.measurement(HighlightBenchmarkMetrics.lineCount, sourceLineCount(source))
        benchmark.measurement(HighlightBenchmarkMetrics.tokenCount, tokenCount)
        benchmark.measurement(HighlightBenchmarkMetrics.refreshLocation, refreshRange.location)
        benchmark.measurement(HighlightBenchmarkMetrics.refreshLength, refreshRange.length)
    }

    private static func unionRefreshRange(_ ranges: [NSRange]) -> NSRange {
        guard let first = ranges.first else {
            return NSRange(location: 0, length: 0)
        }
        var lower = first.location
        var upper = first.upperBound
        for range in ranges.dropFirst() {
            lower = min(lower, range.location)
            upper = max(upper, range.upperBound)
        }
        return NSRange(location: lower, length: upper - lower)
    }

    private static func elapsedNanoseconds(since start: UInt64) -> Int {
        Int(DispatchTime.now().uptimeNanoseconds - start)
    }
}

private struct BenchmarkWorkload: Sendable {
    let name: String
    let language: SyntaxLanguage
    let source: String
    let updatedSource: String
    let mutation: SyntaxEditorTextChange.Replacement?
    let lineCount: Int
    let repeatSource: Int

    init(benchmarkCase: HighlightBenchmarkCase) {
        let baseSource = benchmarkCase.resource.loadString()
        let repeatCount = benchmarkCase.repeatSource ?? repeatCountForApproximateLineCount(
            benchmarkCase.minimumLineCount,
            baseSource,
            language: benchmarkCase.language
        )

        name = benchmarkCase.name
        language = benchmarkCase.language
        source = amplifiedSource(baseSource, count: repeatCount, language: benchmarkCase.language)
        updatedSource = incrementalEditSource(from: source, language: benchmarkCase.language)
        mutation = SyntaxEditorTextChange.Replacement.singleReplacement(
            from: source,
            to: updatedSource
        )
        lineCount = sourceLineCount(source)
        repeatSource = repeatCount
    }
}

private struct HighlightBenchmarkCase: Sendable {
    let name: String
    let language: SyntaxLanguage
    let resource: BenchmarkResource
    let repeatSource: Int?
    let minimumLineCount: Int?

    private static let bundledMinimumLineCount = 10_000
    private static let largeMinimumLineCount = 50_000

    static func cases(options: HighlightBenchmarkOptions) -> [Self] {
        if let filePath = options.externalFile {
            let language = options.language ?? inferredLanguage(forFilePath: filePath)
            return [
                Self(
                    name: "external",
                    language: language,
                    resource: .externalFile(filePath),
                    repeatSource: options.repeatSource ?? 1,
                    minimumLineCount: nil
                ),
            ]
        }

        let cases: [Self] = [
            Self.reference("reference-plain-text", "Reference.txt", .plainText),
            Self.reference("reference-css", "Reference.css", .css),
            Self.reference("reference-html", "Reference.html", .html),
            Self.reference("reference-javascript", "Reference.js", .javascript),
            Self.reference("reference-json", "Reference.json", .json),
            Self.reference("reference-objective-c", "Reference.m", .objectiveC),
            Self.reference("reference-swift", "Reference.swift", .swift),
            Self.reference("reference-toml", "Reference.toml", .toml),
            Self.reference("reference-xml", "Reference.xml", .xml),
            Self.fixture("fixture-swift-structural-edit", "bench-structural-edit.swift"),
            Self.fixture("fixture-swift-comment-edit", "bench-comment-edit.swift"),
            Self.fixture(
                "fixture-swift-structural-edit-large",
                "bench-structural-edit.swift",
                minimumLineCount: largeMinimumLineCount
            ),
            Self.reference(
                "reference-objective-c-large",
                "Reference.m",
                .objectiveC,
                minimumLineCount: largeMinimumLineCount
            ),
        ]

        guard let repeatSource = options.repeatSource else { return cases }
        return cases.map {
            Self(
                name: $0.name,
                language: $0.language,
                resource: $0.resource,
                repeatSource: repeatSource,
                minimumLineCount: nil
            )
        }
    }

    private static func reference(
        _ name: String,
        _ fileName: String,
        _ language: SyntaxLanguage,
        minimumLineCount: Int = bundledMinimumLineCount
    ) -> Self {
        Self(
            name: name,
            language: language,
            resource: .referenceSample(fileName: fileName),
            repeatSource: nil,
            minimumLineCount: minimumLineCount
        )
    }

    private static func fixture(
        _ name: String,
        _ fileName: String,
        minimumLineCount: Int = bundledMinimumLineCount
    ) -> Self {
        Self(
            name: name,
            language: .swift,
            resource: .bundled(subdirectory: "Fixtures", fileName: fileName),
            repeatSource: nil,
            minimumLineCount: minimumLineCount
        )
    }
}

private enum BenchmarkResource: Sendable {
    case referenceSample(fileName: String)
    case bundled(subdirectory: String, fileName: String)
    case externalFile(String)

    func loadString() -> String {
        let url = switch self {
        case .referenceSample(let fileName):
            referenceSampleURL(fileName: fileName)
        case .bundled(let subdirectory, let fileName):
            bundledResourceURL(subdirectory: subdirectory, fileName: fileName)
        case .externalFile(let path):
            externalFileURL(path)
        }

        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            fatalError("Failed to load benchmark source at \(url.path): \(error)")
        }
    }

    private func referenceSampleURL(fileName: String) -> URL {
        guard let url = ReferenceSample.url(named: fileName) else {
            fatalError("Missing reference sample \(fileName)")
        }
        return url
    }

    private func bundledResourceURL(subdirectory: String, fileName: String) -> URL {
        guard let resourceURL = Bundle.module.resourceURL else {
            fatalError("Benchmark resources are unavailable")
        }

        let candidates = [
            resourceURL
                .appendingPathComponent("Resources", isDirectory: true)
                .appendingPathComponent(subdirectory, isDirectory: true)
                .appendingPathComponent(fileName),
            resourceURL
                .appendingPathComponent(subdirectory, isDirectory: true)
                .appendingPathComponent(fileName),
        ]

        guard let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            fatalError("Missing benchmark resource \(subdirectory)/\(fileName)")
        }
        return url
    }

    private func externalFileURL(_ path: String) -> URL {
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path)
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(path)
    }
}

private struct HighlightBenchmarkOptions: Sendable {
    let externalFile: String?
    let language: SyntaxLanguage?
    let repeatSource: Int?
    let iterations: Int
    let typingEdits: Int
    let typingAnchor: TypingAnchor
    let typeText: String
    let typeAfter: String?
    let typeRepeat: Int

    init(environment: [String: String]) {
        externalFile = environment.value("FILE")
        language = environment.value("LANGUAGE").flatMap(SyntaxLanguage.init(identifier:))
        repeatSource = environment.positiveInt("REPEAT_SOURCE")
        iterations = environment.positiveInt("ITERATIONS") ?? 20
        typingEdits = environment.nonNegativeInt("TYPING_EDITS") ?? 20
        typingAnchor = environment.value("TYPING_ANCHOR")
            .map { TypingAnchor(rawValue: $0.lowercased()) ?? .end } ?? .end
        typeText = environment.value("TYPE_TEXT")?
            .replacingOccurrences(of: "\\n", with: "\n") ?? "Benchmark"
        typeAfter = environment.value("TYPE_AFTER")?
            .replacingOccurrences(of: "\\n", with: "\n")
        typeRepeat = environment.positiveInt("TYPE_REPEAT") ?? 1
    }
}

private enum HighlightBenchmarkMetrics {
    static let utf16Length = BenchmarkMetric.custom("UTF16 length", useScalingFactor: false)
    static let tokenCount = BenchmarkMetric.custom("Token count", useScalingFactor: false)
    static let refreshLocation = BenchmarkMetric.custom("Refresh location", useScalingFactor: false)
    static let refreshLength = BenchmarkMetric.custom("Refresh length", useScalingFactor: false)
    static let lineCount = BenchmarkMetric.custom("Line count", useScalingFactor: false)
    static let settleEqualsFresh = BenchmarkMetric.custom("Settle equals fresh", useScalingFactor: false)
    static let typingEditLatencyNanoseconds = BenchmarkMetric.custom(
        "Typing edit latency ns",
        useScalingFactor: false
    )
    static let typingFastPassLatencyNanoseconds = BenchmarkMetric.custom(
        "Typing fast-pass latency ns",
        useScalingFactor: false
    )
    static let typingSettleLatencyNanoseconds = BenchmarkMetric.custom(
        "Typing settle latency ns",
        useScalingFactor: false
    )
    static let typingCompleteRefreshRangeCount = BenchmarkMetric.custom(
        "Typing complete refresh range count",
        useScalingFactor: false
    )
    static let typingCompleteRefreshTotalLength = BenchmarkMetric.custom(
        "Typing complete refresh total length",
        useScalingFactor: false
    )

    static let all: [BenchmarkMetric] = [
        .wallClock,
        .throughput,
        .cpuTotal,
        .instructions,
        utf16Length,
        lineCount,
        tokenCount,
        refreshLocation,
        refreshLength,
        settleEqualsFresh,
        typingEditLatencyNanoseconds,
        typingFastPassLatencyNanoseconds,
        typingSettleLatencyNanoseconds,
        typingCompleteRefreshRangeCount,
        typingCompleteRefreshTotalLength,
    ]
}

private enum TypingAnchor: String, Sendable {
    case start
    case middle
    case end
}

private extension SyntaxLanguage {
    var emitsSyntacticFastPass: Bool {
        self == .swift || self == .objectiveC
    }
}

private extension [String: String] {
    func value(_ name: String) -> String? {
        self["SYNTAX_EDITOR_BENCHMARK_\(name)"]
    }

    func positiveInt(_ name: String) -> Int? {
        value(name).flatMap(Int.init).map { Swift.max(1, $0) }
    }

    func nonNegativeInt(_ name: String) -> Int? {
        value(name).flatMap(Int.init).map { Swift.max(0, $0) }
    }
}

private func incrementalEditSource(from source: String, language: SyntaxLanguage) -> String {
    if source.contains("Reference highlighting surface") {
        return source.replacingOccurrences(
            of: "Reference highlighting surface",
            with: "Reference highlighting surface benchmark",
            options: [],
            range: source.range(of: "Reference highlighting surface")
        )
    }
    if let range = source.range(of: "ReferenceTokenBase + 1") {
        return source.replacingOccurrences(
            of: "ReferenceTokenBase + 1",
            with: "ReferenceTokenBase + 2",
            options: [],
            range: range
        )
    }
    if let range = source.range(of: "ReferenceItem") {
        return source.replacingOccurrences(
            of: "ReferenceItem",
            with: "ReferenceItemBenchmark",
            options: [],
            range: range
        )
    }

    switch language {
    case .plainText:
        return source + "\nbenchmark edit\n"
    case .assemblyARM:
        return source + "\n// benchmark edit\n"
    case .css:
        return source + "\n/* benchmark edit */\n"
    case .html:
        return replacingFirstOccurrence(
            in: source,
            of: "Reference Preview",
            with: "Reference Benchmark"
        ) ?? inserting("<!-- benchmark edit -->", before: "</body>", in: source)
    case .javascript:
        return source + "\n// benchmark edit\n"
    case .json:
        return replacingFirstOccurrence(
            in: source,
            of: "\"enabled\": true",
            with: "\"enabled\": false"
        ) ?? insertingJSONPropertyFallback(in: source)
    case .objectiveC:
        return source + "\n// benchmark edit\n"
    case .swift:
        return source + "\n// benchmark edit\n"
    case .toml:
        return replacingFirstOccurrence(
            in: source,
            of: "enabled = true",
            with: "enabled = false"
        ) ?? (source + "\n# benchmark edit\n")
    case .xml:
        return replacingFirstOccurrence(
            in: source,
            of: "<enabled>true</enabled>",
            with: "<enabled>false</enabled>"
        ) ?? inserting("<!-- benchmark edit -->", before: "</benchmark-documents>", in: source)
    }
}

private let typingValueMarker = "ReferenceTypingBenchmarkValue = "

private func typingBenchmarkSeededSource(
    _ source: String,
    language: SyntaxLanguage,
    anchor: TypingAnchor
) -> String {
    guard source.contains(typingValueMarker) == false else { return source }
    let insertion = switch language {
    case .objectiveC:
        """

        NSInteger ReferenceTypingBenchmark(void) {
            NSInteger ReferenceTypingBenchmarkValue = 1;
            return ReferenceTypingBenchmarkValue;
        }
        """
    case .swift:
        """

        func referenceTypingBenchmark() -> Int {
            let ReferenceTypingBenchmarkValue = 1
            return ReferenceTypingBenchmarkValue
        }
        """
    default:
        "\n// \(typingValueMarker)1\n"
    }
    return insertingTypingBenchmark(insertion, into: source, anchor: anchor)
}

private func insertingTypingBenchmark(
    _ insertion: String,
    into source: String,
    anchor: TypingAnchor
) -> String {
    switch anchor {
    case .start:
        insertion + "\n" + source
    case .middle:
        insertingAtMiddleLine(insertion, into: source)
    case .end:
        source + insertion
    }
}

private func insertingAtMiddleLine(_ insertion: String, into source: String) -> String {
    let utf16Length = (source as NSString).length
    guard utf16Length > 0 else { return insertion }
    let nsSource = source as NSString
    let middle = utf16Length / 2
    let lineRange = nsSource.lineRange(for: NSRange(location: middle, length: 0))
    let index = String.Index(utf16Offset: lineRange.location, in: source)
    return String(source[..<index]) + insertion + "\n" + String(source[index...])
}

private func typingEditSource(from source: String) -> String {
    guard let markerRange = source.range(of: typingValueMarker) else {
        return source + " "
    }
    let valueStart = markerRange.upperBound
    var valueEnd = valueStart
    while valueEnd < source.endIndex, source[valueEnd].isNumber {
        valueEnd = source.index(after: valueEnd)
    }
    let currentValue = Int(source[valueStart..<valueEnd]) ?? 1
    let nextValue = currentValue == 9 ? 1 : currentValue + 1
    return source.replacingCharacters(in: valueStart..<valueEnd, with: String(nextValue))
}

private func insertionPoint(in source: String, typeAfter: String?) -> Int {
    if let typeAfter {
        let markerRange = (source as NSString).range(of: typeAfter)
        if markerRange.location != NSNotFound {
            return markerRange.upperBound
        }
    }
    return (source as NSString).length / 2
}

private func repeatedSource(_ source: String, count: Int) -> String {
    guard count > 1 else { return source }
    return Array(repeating: source, count: count).joined(separator: "\n\n")
}

private func amplifiedSource(_ source: String, count: Int, language: SyntaxLanguage) -> String {
    guard count > 1 else { return source }

    switch language {
    case .html:
        return amplifiedHTMLSource(source, count: count)
    case .json:
        return amplifiedJSONSource(source, count: count)
    case .toml:
        return amplifiedTOMLSource(source, count: count)
    case .xml:
        return amplifiedXMLSource(source, count: count)
    default:
        return repeatedSource(source, count: count)
    }
}

private func repeatCountForApproximateLineCount(
    _ minimumLineCount: Int?,
    _ source: String,
    language: SyntaxLanguage
) -> Int {
    guard let minimumLineCount else {
        return 1
    }

    let lineEstimate = amplifiedLineEstimate(source, language: language)
    let repeatedLines = max(1, lineEstimate.repeatedLines)
    let remainingLines = max(1, minimumLineCount - lineEstimate.fixedLines)
    return max(1, (remainingLines + repeatedLines - 1) / repeatedLines)
}

private func amplifiedLineEstimate(
    _ source: String,
    language: SyntaxLanguage
) -> (fixedLines: Int, repeatedLines: Int) {
    switch language {
    case .html:
        guard
            let bodyOpen = source.range(of: "<body>"),
            let bodyClose = source.range(of: "</body>", options: .backwards)
        else {
            return (0, sourceLineCount(source) + 2)
        }

        let fixedSource = String(source[..<bodyOpen.upperBound]) + String(source[bodyClose.lowerBound...])
        let body = String(source[bodyOpen.upperBound..<bodyClose.lowerBound])
        return (
            sourceLineCount(fixedSource),
            sourceLineCount(body) + 1
        )
    case .json:
        return (
            3,
            sourceLineCount(source.trimmingCharacters(in: .whitespacesAndNewlines)) + 1
        )
    case .toml:
        return (
            0,
            sourceLineCount(source.trimmingCharacters(in: .whitespacesAndNewlines)) + 3
        )
    case .xml:
        let body = xmlBodyWithoutDeclaration(source)
        return (
            source.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<?xml") ? 4 : 3,
            sourceLineCount(body) + 1
        )
    default:
        return (0, sourceLineCount(source) + 2)
    }
}

private func amplifiedHTMLSource(_ source: String, count: Int) -> String {
    guard
        let bodyOpen = source.range(of: "<body>"),
        let bodyClose = source.range(of: "</body>", options: .backwards)
    else {
        return repeatedSource(source, count: count)
    }

    let prefix = String(source[..<bodyOpen.upperBound])
    let body = String(source[bodyOpen.upperBound..<bodyClose.lowerBound])
    let suffix = String(source[bodyClose.lowerBound...])
    return prefix + Array(repeating: body, count: count).joined(separator: "\n") + suffix
}

private func amplifiedJSONSource(_ source: String, count: Int) -> String {
    let element = indentMultiline(source.trimmingCharacters(in: .whitespacesAndNewlines), spaces: 4)
    return "[\n" + Array(repeating: element, count: count).joined(separator: ",\n") + "\n]\n"
}

private func amplifiedTOMLSource(_ source: String, count: Int) -> String {
    let document = source
        .replacingOccurrences(of: "[package]", with: "[documents.package]")
        .replacingOccurrences(of: "[theme]", with: "[documents.theme]")
        .replacingOccurrences(of: "[[items]]", with: "[[documents.items]]")
        .trimmingCharacters(in: .whitespacesAndNewlines)

    let documents = (0..<count).map { index in
        "[[documents]]\nindex = \(index)\n" + document
    }
    return documents.joined(separator: "\n\n") + "\n"
}

private func amplifiedXMLSource(_ source: String, count: Int) -> String {
    var body = source.trimmingCharacters(in: .whitespacesAndNewlines)
    var declaration: String?
    if body.hasPrefix("<?xml"), let declarationRange = body.range(of: "?>") {
        declaration = String(body[..<declarationRange.upperBound])
        body = String(body[declarationRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    let repeatedElements = Array(repeating: indentMultiline(body, spaces: 4), count: count)
        .joined(separator: "\n")
    let document = "<benchmark-documents>\n" + repeatedElements + "\n</benchmark-documents>\n"
    if let declaration {
        return declaration + "\n" + document
    }
    return document
}

private func xmlBodyWithoutDeclaration(_ source: String) -> String {
    var body = source.trimmingCharacters(in: .whitespacesAndNewlines)
    if body.hasPrefix("<?xml"), let declarationRange = body.range(of: "?>") {
        body = String(body[declarationRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return body
}

private func indentMultiline(_ source: String, spaces: Int) -> String {
    let prefix = String(repeating: " ", count: spaces)
    return source.split(separator: "\n", omittingEmptySubsequences: false)
        .map { prefix + String($0) }
        .joined(separator: "\n")
}

private func replacingFirstOccurrence(
    in source: String,
    of target: String,
    with replacement: String
) -> String? {
    guard let range = source.range(of: target) else { return nil }
    return source.replacingCharacters(in: range, with: replacement)
}

private func inserting(_ insertion: String, before marker: String, in source: String) -> String {
    guard let markerRange = source.range(of: marker, options: .backwards) else {
        return source + "\n" + insertion + "\n"
    }
    return String(source[..<markerRange.lowerBound]) + insertion + "\n" + String(source[markerRange.lowerBound...])
}

private func insertingJSONPropertyFallback(in source: String) -> String {
    guard let closeBrace = source.range(of: "}", options: .backwards) else {
        return source
    }

    let prefix = String(source[..<closeBrace.lowerBound])
    let suffix = String(source[closeBrace.lowerBound...])
    let needsComma = prefix.contains(":")
    return prefix + (needsComma ? "," : "") + "\n  \"benchmarkEdit\": true\n" + suffix
}

private func sourceLineCount(_ source: String) -> Int {
    guard source.isEmpty == false else { return 0 }
    return source.utf8.reduce(1) { partialResult, byte in
        byte == 10 ? partialResult + 1 : partialResult
    }
}

private func inferredLanguage(forFilePath filePath: String) -> SyntaxLanguage {
    switch URL(fileURLWithPath: filePath).pathExtension.lowercased() {
    case "css":
        .css
    case "html", "htm":
        .html
    case "js", "mjs", "cjs":
        .javascript
    case "json":
        .json
    case "m", "h":
        .objectiveC
    case "toml":
        .toml
    case "txt", "text":
        .plainText
    case "xml":
        .xml
    default:
        .swift
    }
}
