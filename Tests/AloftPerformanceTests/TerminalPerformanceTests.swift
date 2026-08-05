import AppKit
import CryptoKit
import Darwin
import Foundation
import Observation
import SwiftTerm
import XCTest
@testable import AloftApp

@MainActor
final class TerminalPerformanceTests: XCTestCase {
    private var repetitions: Int {
        let value = ProcessInfo.processInfo.environment[
            "ALOFT_PERFORMANCE_REPETITIONS"
        ].flatMap(Int.init) ?? 5
        return max(1, value)
    }

    private var firstPTYByteCount: Int {
        performanceByteCount(
            environmentKey: "ALOFT_PERFORMANCE_PTY_BYTES",
            defaultValue: 4_000_000
        )
    }

    private var restartPTYByteCount: Int {
        performanceByteCount(
            environmentKey:
                "ALOFT_PERFORMANCE_PTY_RESTART_BYTES",
            defaultValue: 500_000
        )
    }

    private var maximumNewSamples: Int {
        let value = ProcessInfo.processInfo.environment[
            "ALOFT_PERFORMANCE_MAX_NEW_SAMPLES"
        ].flatMap(Int.init) ?? 1
        return max(0, value)
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment[
                "ALOFT_RUN_PERFORMANCE_TESTS"
            ] == "1",
            "Run through script/run_terminal_benchmarks.sh"
        )
        try installSwiftTermResourcesForPerformanceTests()
    }

    func testReleaseSyntheticTerminalBenchmarkMatrix() throws {
        let outputURL = try performanceOutputURL()
        var report = try loadOrCreateReport(from: outputURL)
        try runSyntheticBenchmarks(
            report: &report,
            outputURL: outputURL
        )
        XCTAssertTrue(
            report.series
                .filter {
                    TerminalBenchmarkBackend(
                        rawValue: $0.backend
                    ) != nil
                }
                .allSatisfy {
                    (1...repetitions)
                        .contains($0.samples.count)
                }
        )
        try write(report, to: outputURL)
    }

    func testReleasePerformanceReportIsComplete() throws {
        let report = try loadOrCreateReport(
            from: performanceOutputURL()
        )
        let expectedSyntheticSeries =
            TerminalBenchmarkWorkload.allCases.count
                * TerminalBenchmarkBackend.allCases.count
        let expectedEndToEndSeries =
            TerminalEndToEndBackend.allCases.count
        XCTAssertEqual(
            report.series.count,
            expectedSyntheticSeries + expectedEndToEndSeries
        )
        XCTAssertTrue(
            report.series.allSatisfy {
                $0.samples.count == repetitions
            }
        )
    }

    func testReleaseEndToEndTerminalBenchmarkMatrix()
        async throws {
        let outputURL = try performanceOutputURL()
        var report = try loadOrCreateReport(from: outputURL)
        try await runEndToEndBenchmarks(
            report: &report,
            outputURL: outputURL
        )
        XCTAssertTrue(
            report.series
                .filter {
                    TerminalEndToEndBackend(
                        rawValue: $0.backend
                    ) != nil
                }
                .allSatisfy {
                    (1...repetitions)
                        .contains($0.samples.count)
                }
        )
        try write(report, to: outputURL)
    }

    private func runSyntheticBenchmarks(
        report: inout TerminalBenchmarkReport,
        outputURL: URL
    ) throws {
        for workload in selectedWorkloads {
            let payload = workload.makePayload()
            let chunks = payload.chunks(ofCount: 64 * 1_024)
            let digest = SHA256.hash(data: payload)
                .map { String(format: "%02x", $0) }
                .joined()
            if !report.payloads.contains(
                where: { $0.name == workload.rawValue }
            ) {
                report.payloads.append(
                    TerminalBenchmarkPayload(
                        name: workload.rawValue,
                        byteCount: payload.count,
                        sha256: digest
                    )
                )
            }

            for backend in selectedBackends {
                print(
                    "benchmark workload=\(workload.rawValue) "
                        + "backend=\(backend.rawValue)"
                )
                var samples = report.series.first {
                    $0.workload == workload.rawValue
                        && $0.backend == backend.rawValue
                }?.samples ?? []
                var newSampleCount = 0
                while samples.count < repetitions,
                      newSampleCount < maximumNewSamples {
                    let repetition = samples.count + 1
                    let sample = try autoreleasepool {
                        try measure(
                            chunks: chunks,
                            totalBytes: payload.count,
                            backend: backend,
                            repetition: repetition
                        )
                    }
                    samples.append(sample)
                    newSampleCount += 1
                    print(
                        "  repetition=\(repetition) "
                            + "wall=\(sample.wallSeconds) "
                            + "bytesPerSecond=\(sample.bytesPerSecond)"
                    )
                    report.series.removeAll {
                        $0.workload == workload.rawValue
                            && $0.backend == backend.rawValue
                    }
                    report.series.append(
                        TerminalBenchmarkSeries(
                            workload: workload.rawValue,
                            backend: backend.rawValue,
                            samples: samples,
                            median: .median(of: samples),
                            worst: .worst(of: samples)
                        )
                    )
                    try write(report, to: outputURL)
                }
            }
        }
    }

    private func runEndToEndBenchmarks(
        report: inout TerminalBenchmarkReport,
        outputURL: URL
    ) async throws {
        guard ProcessInfo.processInfo.environment[
            "ALOFT_PERFORMANCE_SKIP_END_TO_END"
        ] != "1" else {
            return
        }
        for backend in selectedEndToEndBackends {
            print("benchmark end-to-end backend=\(backend.rawValue)")
            var samples = report.series.first {
                $0.workload == "continuous_controls_pty"
                    && $0.backend == backend.rawValue
            }?.samples ?? []
            var newSampleCount = 0
            while samples.count < repetitions,
                  newSampleCount
                    < maximumNewSamples {
                let repetition = samples.count + 1
                let sample = try await measureEndToEnd(
                    backend: backend,
                    repetition: repetition
                )
                samples.append(sample)
                newSampleCount += 1
                report.series.removeAll {
                    $0.workload == "continuous_controls_pty"
                        && $0.backend == backend.rawValue
                }
                report.series.append(
                    TerminalBenchmarkSeries(
                        workload: "continuous_controls_pty",
                        backend: backend.rawValue,
                        samples: samples,
                        median: .median(of: samples),
                        worst: .worst(of: samples)
                    )
                )
                try write(report, to: outputURL)
            }
        }
    }

    private var selectedWorkloads: [TerminalBenchmarkWorkload] {
        selected(
            TerminalBenchmarkWorkload.allCases,
            environmentKey: "ALOFT_PERFORMANCE_WORKLOAD"
        )
    }

    private var selectedBackends: [TerminalBenchmarkBackend] {
        selected(
            TerminalBenchmarkBackend.allCases,
            environmentKey: "ALOFT_PERFORMANCE_BACKEND"
        )
    }

    private var selectedEndToEndBackends:
        [TerminalEndToEndBackend] {
        selected(
            TerminalEndToEndBackend.allCases,
            environmentKey:
                "ALOFT_PERFORMANCE_END_TO_END_BACKEND"
        )
    }

    private func selected<Value>(
        _ values: [Value],
        environmentKey: String
    ) -> [Value] where Value: RawRepresentable,
        Value.RawValue == String {
        guard let selected = ProcessInfo.processInfo
            .environment[environmentKey] else {
            return values
        }
        return values.filter { $0.rawValue == selected }
    }

    private func measure(
        chunks: [Data],
        totalBytes: Int,
        backend: TerminalBenchmarkBackend,
        repetition: Int
    ) throws -> TerminalBenchmarkSample {
        switch backend {
        case .outputPipeline:
            measureOutputPipeline(
                chunks: chunks,
                totalBytes: totalBytes,
                repetition: repetition
            )
        case .swiftTermCoreGraphics:
            try measureSwiftTerm(
                chunks: chunks,
                totalBytes: totalBytes,
                backend: backend,
                repetition: repetition,
                usesMetal: false
            )
        case .swiftTermMetal:
            try measureSwiftTerm(
                chunks: chunks,
                totalBytes: totalBytes,
                backend: backend,
                repetition: repetition,
                usesMetal: true
            )
        }
    }

    private func measureOutputPipeline(
        chunks: [Data],
        totalBytes: Int,
        repetition: Int
    ) -> TerminalBenchmarkSample {
        var pipeline = OutputPipeline(
            entryID: UUID(
                uuidString:
                    "00000000-0000-0000-0000-000000000001"
            )!,
            keywords: ["ERROR", "ready", "👩🏽‍💻"],
            lineLimit: 20_000
        )
        let usageBefore = processUsage()
        let wallStart = DispatchTime.now().uptimeNanoseconds
        var worstStallNanoseconds: UInt64 = 0
        let timestamp = Date(timeIntervalSince1970: 0)

        for chunk in chunks {
            let stallStart = DispatchTime.now().uptimeNanoseconds
            _ = pipeline.consume(chunk, at: timestamp)
            worstStallNanoseconds = max(
                worstStallNanoseconds,
                DispatchTime.now().uptimeNanoseconds - stallStart
            )
        }

        let wallNanoseconds =
            DispatchTime.now().uptimeNanoseconds - wallStart
        let usageAfter = processUsage()
        return TerminalBenchmarkSample(
            repetition: repetition,
            wallSeconds: seconds(wallNanoseconds),
            bytesPerSecond:
                Double(totalBytes) / seconds(wallNanoseconds),
            processCPUSeconds:
                usageAfter.cpuSeconds - usageBefore.cpuSeconds,
            peakResidentBytes: usageAfter.peakResidentBytes,
            worstMainThreadStallSeconds:
                seconds(worstStallNanoseconds),
            worstDisplaySubmissionIntervalSeconds: nil,
            scrollResponseSeconds: nil,
            rawPTYDrainBytesPerSecond: nil,
            readToDisplaySubmissionLatencySeconds: nil
        )
    }

    private func measureSwiftTerm(
        chunks: [Data],
        totalBytes: Int,
        backend: TerminalBenchmarkBackend,
        repetition: Int,
        usesMetal: Bool
    ) throws -> TerminalBenchmarkSample {
        let showsWindow =
            ProcessInfo.processInfo.environment[
                "ALOFT_PERFORMANCE_SHOW_WINDOWS"
            ] == "1"
        let view = ReadOnlySwiftTermView(
            frame: NSRect(x: 0, y: 0, width: 1_200, height: 800)
        )
        view.changeScrollback(20_000)
        let window = NSWindow(
            contentRect: view.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.animationBehavior = .none
        window.contentView = view
        if showsWindow {
            window.orderFrontRegardless()
        }
        defer {
            if showsWindow {
                window.orderOut(nil)
            }
            PerformanceFixtureLifetime
                .retainUntilProcessExit(view, window)
        }
        try view.setUseMetal(usesMetal)
        if usesMetal {
            XCTAssertTrue(
                view.isUsingMetalRenderer,
                "\(backend.rawValue) did not activate Metal"
            )
        } else {
            XCTAssertFalse(view.isUsingMetalRenderer)
        }

        let usageBefore = processUsage()
        let wallStart = DispatchTime.now().uptimeNanoseconds
        var worstStallNanoseconds: UInt64 = 0
        var displaySubmissionIntervals: [UInt64] = []
        var priorDisplaySubmission = wallStart

        for (index, chunk) in chunks.enumerated() {
            let stallStart = DispatchTime.now().uptimeNanoseconds
            let bytes = Array(chunk)
            view.feed(byteArray: bytes[...])
            worstStallNanoseconds = max(
                worstStallNanoseconds,
                DispatchTime.now().uptimeNanoseconds - stallStart
            )
            if index.isMultiple(of: 32) {
                window.displayIfNeeded()
                let submission =
                    DispatchTime.now().uptimeNanoseconds
                displaySubmissionIntervals.append(
                    submission - priorDisplaySubmission
                )
                priorDisplaySubmission = submission
            }
        }
        window.displayIfNeeded()
        let wallNanoseconds =
            DispatchTime.now().uptimeNanoseconds - wallStart

        let scrollStart = DispatchTime.now().uptimeNanoseconds
        view.doCommand(
            by: #selector(NSResponder.scrollPageUp(_:))
        )
        view.doCommand(
            by: #selector(NSResponder.scrollPageDown(_:))
        )
        window.displayIfNeeded()
        let scrollNanoseconds =
            DispatchTime.now().uptimeNanoseconds - scrollStart
        let usageAfter = processUsage()

        return TerminalBenchmarkSample(
            repetition: repetition,
            wallSeconds: seconds(wallNanoseconds),
            bytesPerSecond:
                Double(totalBytes) / seconds(wallNanoseconds),
            processCPUSeconds:
                usageAfter.cpuSeconds - usageBefore.cpuSeconds,
            peakResidentBytes: usageAfter.peakResidentBytes,
            worstMainThreadStallSeconds:
                seconds(worstStallNanoseconds),
            worstDisplaySubmissionIntervalSeconds:
                displaySubmissionIntervals.max().map(seconds),
            scrollResponseSeconds: seconds(scrollNanoseconds),
            rawPTYDrainBytesPerSecond: nil,
            readToDisplaySubmissionLatencySeconds: nil
        )
    }

    private func measureEndToEnd(
        backend: TerminalEndToEndBackend,
        repetition: Int
    ) async throws -> TerminalBenchmarkSample {
        let firstMarker = "ALOFT_PERF_FIRST_DONE"
        let secondMarker = "ALOFT_PERF_SECOND_DONE"
        let tracker = PTYBenchmarkTracker(
            markers: [firstMarker, secondMarker]
        )
        let supervisor = ProcessSupervisor()
        let holder = PTYBenchmarkSurfaceHolder(
            backend: backend,
            tracker: tracker
        )
        let processClient = RuntimeProcessClient(
            start: { entry, generation, outputHandler in
                tracker.recordGeneration(generation)
                return try await supervisor.start(
                    entry: entry,
                    generation: generation
                ) { data in
                    tracker.recordPTYRead(data)
                    outputHandler.handler(data)
                }
            },
            write: { entryID, generation, data in
                try await supervisor.write(
                    entryID: entryID,
                    generation: generation,
                    data: data
                )
            },
            resize: { entryID, generation, size in
                try await supervisor.resize(
                    entryID: entryID,
                    generation: generation,
                    size: size
                )
            },
            stop: { entryID, timeout in
                try await supervisor.stop(
                    entryID: entryID,
                    timeout: timeout
                )
            },
            refresh: { entryID in
                try await supervisor.refresh(entryID: entryID)
            },
            snapshots: {
                try await supervisor.snapshots()
            }
        )
        let runtimeStore = RuntimeStore(
            supervisor: supervisor,
            processClient: processClient,
            terminalSurfaceFactory: holder.factory
        )
        var entry = CommandEntry(
            id: UUID(),
            name: "PTY Performance",
            cwd: "/tmp",
            command: PTYBenchmarkCommand.make(
                byteCount: firstPTYByteCount,
                marker: firstMarker
            ),
            shell: "/bin/zsh",
            keywords: ["ALOFT_PERF"],
            order: 0
        )
        let runtime = runtimeStore.runtime(for: entry.id)
        let textObserver: PTYTextProjectionObserver? =
            backend == .text
                ? PTYTextProjectionObserver(
                    runtime: runtime,
                    tracker: tracker
                )
                : nil
        defer { _ = textObserver }

        let usageBefore = processUsage()
        let wallStart = DispatchTime.now().uptimeNanoseconds
        do {
            print("  end-to-end stage=start")
            let startResult = await runtimeStore.start(entry)
            try requireBenchmarkSuccess(startResult)
            print("  end-to-end stage=started")
            if let surface = holder.surface {
                surface.resize(
                    TerminalSize(
                        columns: 121,
                        rows: 41,
                        pixelWidth: 1_210,
                        pixelHeight: 820
                    )!,
                    generation: tracker.requiredGeneration
                )
            }
            try await waitForMarker(
                firstMarker,
                tracker: tracker,
                runtime: runtime,
                backend: backend,
                timeout: .seconds(30)
            )
            print("  end-to-end stage=first-marker")
            if let surface = holder.surface {
                await surface.waitUntilIdle()
            }
            let scrollResponseSeconds =
                holder.measureScrollResponse()

            entry.command = PTYBenchmarkCommand.make(
                byteCount: restartPTYByteCount,
                marker: secondMarker
            )
            print("  end-to-end stage=restart")
            let restartResult = await runtimeStore.restart(
                entry,
                timeout: .seconds(2)
            )
            try requireBenchmarkSuccess(restartResult)
            print("  end-to-end stage=restarted")
            try await waitForMarker(
                secondMarker,
                tracker: tracker,
                runtime: runtime,
                backend: backend,
                timeout: .seconds(15)
            )
            print("  end-to-end stage=second-marker")
            if let surface = holder.surface {
                await surface.waitUntilIdle()
            }
            print("  end-to-end stage=stop")
            let stopResult = await runtimeStore.stop(
                entry,
                timeout: .seconds(2)
            )
            try requireBenchmarkSuccess(stopResult)
            print("  end-to-end stage=stopped")

            if let surface = holder.surface {
                await surface.waitUntilIdle()
            }
            let wallNanoseconds =
                DispatchTime.now().uptimeNanoseconds - wallStart
            let usageAfter = processUsage()
            let rawThroughput = tracker.rawPTYBytesPerSecond
            PerformanceFixtureLifetime.retainUntilProcessExit(
                supervisor,
                runtimeStore,
                holder
            )
            return TerminalBenchmarkSample(
                repetition: repetition,
                wallSeconds: seconds(wallNanoseconds),
                bytesPerSecond: rawThroughput,
                processCPUSeconds:
                    usageAfter.cpuSeconds
                        - usageBefore.cpuSeconds,
                peakResidentBytes: usageAfter.peakResidentBytes,
                worstMainThreadStallSeconds:
                    tracker.worstMainThreadStallSeconds,
                worstDisplaySubmissionIntervalSeconds:
                    tracker
                        .worstDisplaySubmissionIntervalSeconds,
                scrollResponseSeconds: scrollResponseSeconds,
                rawPTYDrainBytesPerSecond: rawThroughput,
                readToDisplaySubmissionLatencySeconds:
                    tracker
                        .worstReadToDisplaySubmissionLatencySeconds
            )
        } catch {
            _ = await runtimeStore.stop(
                entry,
                timeout: .seconds(2)
            )
            runtimeStore.disposeAllTerminalSurfaces()
            if let surface = holder.surface {
                await surface.waitUntilIdle()
            }
            holder.close()
            throw error
        }
    }

    private func waitForMarker(
        _ marker: String,
        tracker: PTYBenchmarkTracker,
        runtime: EntryRuntime,
        backend: TerminalEndToEndBackend,
        timeout: Duration
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            let rawMarkerArrived = tracker.hasMarker(marker)
            let projectionArrived = backend != .text
                || runtime.output.displayText.contains(marker)
            if rawMarkerArrived && projectionArrived {
                return
            }
            await Task.yield()
        }
        throw TerminalBenchmarkError.markerTimedOut(marker)
    }

    private func requireBenchmarkSuccess(
        _ result: EntryActionResult
    ) throws {
        guard result.isSuccess else {
            throw TerminalBenchmarkError.actionFailed(
                result.errorDescription ?? "unknown"
            )
        }
    }

    private func performanceByteCount(
        environmentKey: String,
        defaultValue: Int
    ) -> Int {
        let value = ProcessInfo.processInfo
            .environment[environmentKey]
            .flatMap(Int.init) ?? defaultValue
        return max(1, value)
    }

    private func performanceOutputURL() throws -> URL {
        let environment = ProcessInfo.processInfo.environment
        let path = environment["ALOFT_PERFORMANCE_OUTPUT"]
            ?? FileManager.default.currentDirectoryPath
                + "/artifacts/performance/"
                + "terminal-benchmark.json"
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        return url
    }

    private func loadOrCreateReport(
        from outputURL: URL
    ) throws -> TerminalBenchmarkReport {
        if FileManager.default.fileExists(
            atPath: outputURL.path
        ) {
            return try JSONDecoder().decode(
                TerminalBenchmarkReport.self,
                from: Data(contentsOf: outputURL)
            )
        }
        return TerminalBenchmarkReport(
            schemaVersion: 1,
            generatedAt: ISO8601DateFormatter()
                .string(from: Date()),
            buildConfiguration: "release",
            swiftTermVersion: "1.15.0",
            repetitions: repetitions,
            payloads: [],
            series: []
        )
    }

    private func write(
        _ report: TerminalBenchmarkReport,
        to outputURL: URL
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [
            .prettyPrinted,
            .sortedKeys,
            .withoutEscapingSlashes,
        ]
        try encoder.encode(report).write(
            to: outputURL,
            options: .atomic
        )
    }
}

private enum TerminalBenchmarkBackend:
    String,
    CaseIterable {
    case outputPipeline = "output_pipeline"
    case swiftTermCoreGraphics = "swiftterm_core_graphics"
    case swiftTermMetal = "swiftterm_metal"
}

private enum TerminalEndToEndBackend:
    String,
    CaseIterable {
    case text = "text_pty"
    case swiftTermCoreGraphics = "swiftterm_core_graphics_pty"
    case swiftTermMetal = "swiftterm_metal_pty"
}

private enum TerminalBenchmarkWorkload:
    String,
    CaseIterable {
    case plainUTF8 = "plain_utf8_100mb"
    case ansiProgress = "ansi_progress_100mb"
    case cursorAddressing = "cursor_addressing"
    case unicodeEmoji = "unicode_emoji"
    case continuousControls = "continuous_controls"

    var byteCount: Int {
        switch self {
        case .plainUTF8, .ansiProgress:
            100_000_000
        case .cursorAddressing, .unicodeEmoji,
             .continuousControls:
            16_000_000
        }
    }

    func makePayload() -> Data {
        let pattern: Data
        switch self {
        case .plainUTF8:
            pattern = Data(
                (
                    "2026-07-29T00:00:00Z INFO worker=aloft "
                        + String(repeating: "x", count: 192)
                        + "\n"
                ).utf8
            )
        case .ansiProgress:
            pattern = Data(
                (
                    "\u{1b}[31mERROR\u{1b}[0m build step "
                        + String(repeating: "y", count: 128)
                        + "\rprogress=042%\u{1b}[K\n"
                ).utf8
            )
        case .cursorAddressing:
            pattern = Data(
                (
                    "\u{1b}[2J\u{1b}[H"
                        + (1...24).map {
                            "\u{1b}[\($0);1Hrow-\($0)-"
                                + String(
                                    repeating: "#",
                                    count: 64
                                )
                        }.joined()
                ).utf8
            )
        case .unicodeEmoji:
            pattern = Data(
                (
                    "Cafe\u{301} 한글 العربية "
                        + "👩🏽‍💻👨‍👩‍👧‍👦🏳️‍🌈 "
                        + "क्षि မြန်မာ\n"
                ).utf8
            )
        case .continuousControls:
            pattern = Data(
                (
                    "\u{1b}[36mstream\u{1b}[0m "
                        + "ready 👩🏽‍💻 "
                        + String(repeating: "z", count: 96)
                        + "\rframe=00042\u{1b}[K\n"
                ).utf8
            )
        }
        return Data.repeating(pattern, count: byteCount)
    }
}

private struct TerminalBenchmarkReport: Codable {
    let schemaVersion: Int
    let generatedAt: String
    let buildConfiguration: String
    let swiftTermVersion: String
    let repetitions: Int
    var payloads: [TerminalBenchmarkPayload]
    var series: [TerminalBenchmarkSeries]
}

private struct TerminalBenchmarkPayload: Codable {
    let name: String
    let byteCount: Int
    let sha256: String
}

private struct TerminalBenchmarkSeries: Codable {
    let workload: String
    let backend: String
    let samples: [TerminalBenchmarkSample]
    let median: TerminalBenchmarkAggregate
    let worst: TerminalBenchmarkAggregate
}

private struct TerminalBenchmarkSample: Codable {
    let repetition: Int
    let wallSeconds: Double
    let bytesPerSecond: Double
    let processCPUSeconds: Double
    let peakResidentBytes: UInt64
    let worstMainThreadStallSeconds: Double
    let worstDisplaySubmissionIntervalSeconds: Double?
    let scrollResponseSeconds: Double?
    let rawPTYDrainBytesPerSecond: Double?
    let readToDisplaySubmissionLatencySeconds: Double?
}

private struct TerminalBenchmarkAggregate: Codable {
    let wallSeconds: Double
    let bytesPerSecond: Double
    let processCPUSeconds: Double
    let peakResidentBytes: UInt64
    let worstMainThreadStallSeconds: Double
    let worstDisplaySubmissionIntervalSeconds: Double?
    let scrollResponseSeconds: Double?
    let rawPTYDrainBytesPerSecond: Double?
    let readToDisplaySubmissionLatencySeconds: Double?

    static func median(
        of samples: [TerminalBenchmarkSample]
    ) -> Self {
        Self(
            wallSeconds: samples.map(\.wallSeconds).median,
            bytesPerSecond: samples.map(\.bytesPerSecond).median,
            processCPUSeconds:
                samples.map(\.processCPUSeconds).median,
            peakResidentBytes:
                samples.map(\.peakResidentBytes).median,
            worstMainThreadStallSeconds:
                samples
                    .map(\.worstMainThreadStallSeconds)
                    .median,
            worstDisplaySubmissionIntervalSeconds:
                samples
                    .compactMap(
                        \.worstDisplaySubmissionIntervalSeconds
                    )
                    .optionalMedian,
            scrollResponseSeconds:
                samples
                    .compactMap(\.scrollResponseSeconds)
                    .optionalMedian,
            rawPTYDrainBytesPerSecond:
                samples
                    .compactMap(\.rawPTYDrainBytesPerSecond)
                    .optionalMedian,
            readToDisplaySubmissionLatencySeconds:
                samples
                    .compactMap(
                        \.readToDisplaySubmissionLatencySeconds
                    )
                    .optionalMedian
        )
    }

    static func worst(
        of samples: [TerminalBenchmarkSample]
    ) -> Self {
        Self(
            wallSeconds: samples.map(\.wallSeconds).max() ?? 0,
            bytesPerSecond:
                samples.map(\.bytesPerSecond).min() ?? 0,
            processCPUSeconds:
                samples.map(\.processCPUSeconds).max() ?? 0,
            peakResidentBytes:
                samples.map(\.peakResidentBytes).max() ?? 0,
            worstMainThreadStallSeconds:
                samples
                    .map(\.worstMainThreadStallSeconds)
                    .max() ?? 0,
            worstDisplaySubmissionIntervalSeconds:
                samples
                    .compactMap(
                        \.worstDisplaySubmissionIntervalSeconds
                    )
                    .max(),
            scrollResponseSeconds:
                samples
                    .compactMap(\.scrollResponseSeconds)
                    .max(),
            rawPTYDrainBytesPerSecond:
                samples
                    .compactMap(\.rawPTYDrainBytesPerSecond)
                    .min(),
            readToDisplaySubmissionLatencySeconds:
                samples
                    .compactMap(
                        \.readToDisplaySubmissionLatencySeconds
                    )
                    .max()
        )
    }
}

@MainActor
private final class PTYBenchmarkSurfaceHolder {
    private let backend: TerminalEndToEndBackend
    private let tracker: PTYBenchmarkTracker
    private(set) var surface: SwiftTermSurface?
    private var window: NSWindow?

    init(
        backend: TerminalEndToEndBackend,
        tracker: PTYBenchmarkTracker
    ) {
        self.backend = backend
        self.tracker = tracker
    }

    var factory: TerminalSurfaceFactory? {
        guard backend != .text else {
            return nil
        }
        return TerminalSurfaceFactory {
            [weak self] _, callbacks in
            guard let self else {
                throw TerminalBenchmarkError.surfaceHolderReleased
            }
            return self.install(callbacks: callbacks)
        }
    }

    func measureScrollResponse() -> Double? {
        guard let surface,
              let view = surface.nativeView
                as? ReadOnlySwiftTermView,
              let window else {
            return nil
        }
        let start = DispatchTime.now().uptimeNanoseconds
        view.doCommand(
            by: #selector(NSResponder.scrollPageUp(_:))
        )
        view.doCommand(
            by: #selector(NSResponder.scrollPageDown(_:))
        )
        window.displayIfNeeded()
        return seconds(
            DispatchTime.now().uptimeNanoseconds - start
        )
    }

    func close() {
        surface = nil
        window?.contentView = nil
        window?.orderOut(nil)
        window?.close()
        window = nil
    }

    private func install(
        callbacks: TerminalSurfaceCallbacks
    ) -> any TerminalSurface {
        let base: SwiftTermSurface
        switch backend {
        case .text:
            preconditionFailure(
                "Text PTY benchmark requested a terminal surface."
            )
        case .swiftTermCoreGraphics:
            base = SwiftTermSurface(
                callbacks: callbacks,
                metalActivation: { view in
                    try view.setUseMetal(false)
                    return false
                }
            )
        case .swiftTermMetal:
            base = SwiftTermSurface(callbacks: callbacks)
        }
        let measuring = PTYBenchmarkTerminalSurface(
            base: base,
            tracker: tracker
        )
        let window = NSWindow(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: 1_200,
                height: 800
            ),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.animationBehavior = .none
        window.contentView = base.nativeView
        self.window = window
        surface = base
        return measuring
    }
}

private final class PTYBenchmarkTerminalSurface:
    TerminalSurface,
    @unchecked Sendable {
    private let base: SwiftTermSurface
    private let tracker: PTYBenchmarkTracker

    init(
        base: SwiftTermSurface,
        tracker: PTYBenchmarkTracker
    ) {
        self.base = base
        self.tracker = tracker
    }

    @MainActor
    var nativeView: NSView {
        base.nativeView
    }

    @MainActor
    var rendererState: TerminalRendererState {
        base.rendererState
    }

    @MainActor
    var onRendererStateChange:
        ((TerminalRendererState) -> Void)? {
        get { base.onRendererStateChange }
        set { base.onRendererStateChange = newValue }
    }

    func prepare(generation: UUID) {
        base.prepare(generation: generation)
    }

    func feed(_ data: Data, generation: UUID) {
        tracker.recordDisplaySubmission()
        base.feed(data, generation: generation)
    }

    func promote(generation: UUID, at timestamp: Date) {
        base.promote(generation: generation, at: timestamp)
    }

    func discard(generation: UUID) {
        base.discard(generation: generation)
    }

    func resize(_ size: TerminalSize, generation: UUID) {
        base.resize(size, generation: generation)
    }

    func clear() {
        base.clear()
    }

    func dispose() {
        base.dispose()
    }
}

private final class PTYBenchmarkTracker:
    @unchecked Sendable {
    private let lock = NSLock()
    private let markerData: [String: Data]
    private var foundMarkers: Set<String> = []
    private var tail = Data()
    private var rawBytes = 0
    private var firstReadNanoseconds: UInt64?
    private var lastReadNanoseconds: UInt64?
    private var latestReadNanoseconds: UInt64?
    private var priorSubmissionNanoseconds: UInt64?
    private var displaySubmissionIntervals: [UInt64] = []
    private var readToSubmissionLatencies: [UInt64] = []
    private var mainThreadStalls: [UInt64] = []
    private var generation: UUID?

    init(markers: [String]) {
        markerData = Dictionary(
            uniqueKeysWithValues: markers.map {
                ($0, Data($0.utf8))
            }
        )
    }

    func recordGeneration(_ generation: UUID) {
        lock.withLock {
            self.generation = generation
        }
    }

    func recordPTYRead(_ data: Data) {
        let now = DispatchTime.now().uptimeNanoseconds
        lock.withLock {
            firstReadNanoseconds =
                firstReadNanoseconds ?? now
            lastReadNanoseconds = now
            latestReadNanoseconds = now
            rawBytes += data.count

            var searchable = tail
            searchable.append(data)
            for (marker, bytes) in markerData
                where !foundMarkers.contains(marker) {
                if searchable.range(of: bytes) != nil {
                    foundMarkers.insert(marker)
                }
            }
            tail = Data(searchable.suffix(512))
        }
        DispatchQueue.main.async { [weak self] in
            self?.recordMainThreadResponse(
                scheduledAt: now
            )
        }
    }

    func recordDisplaySubmission() {
        lock.withLock {
            let now =
                DispatchTime.now().uptimeNanoseconds
            if let latestReadNanoseconds {
                readToSubmissionLatencies.append(
                    now - latestReadNanoseconds
                )
            }
            if let priorSubmissionNanoseconds {
                displaySubmissionIntervals.append(
                    now - priorSubmissionNanoseconds
                )
            }
            priorSubmissionNanoseconds = now
        }
    }

    func hasMarker(_ marker: String) -> Bool {
        lock.withLock { foundMarkers.contains(marker) }
    }

    var requiredGeneration: UUID {
        lock.withLock {
            guard let generation else {
                preconditionFailure(
                    "The PTY benchmark did not start a generation."
                )
            }
            return generation
        }
    }

    var rawPTYBytesPerSecond: Double {
        lock.withLock {
            guard let firstReadNanoseconds,
                  let lastReadNanoseconds else {
                return 0
            }
            return Double(rawBytes) / seconds(
                max(1, lastReadNanoseconds - firstReadNanoseconds)
            )
        }
    }

    var worstMainThreadStallSeconds: Double {
        lock.withLock {
            mainThreadStalls.max().map(seconds) ?? 0
        }
    }

    var worstDisplaySubmissionIntervalSeconds: Double? {
        lock.withLock {
            displaySubmissionIntervals.max().map(seconds)
        }
    }

    var worstReadToDisplaySubmissionLatencySeconds: Double? {
        lock.withLock {
            readToSubmissionLatencies.max().map(seconds)
        }
    }

    private func recordMainThreadResponse(
        scheduledAt nanoseconds: UInt64
    ) {
        let delay =
            DispatchTime.now().uptimeNanoseconds - nanoseconds
        lock.withLock {
            mainThreadStalls.append(delay)
        }
    }
}

@MainActor
private final class PTYTextProjectionObserver {
    private let runtime: EntryRuntime
    private let tracker: PTYBenchmarkTracker

    init(
        runtime: EntryRuntime,
        tracker: PTYBenchmarkTracker
    ) {
        self.runtime = runtime
        self.tracker = tracker
        arm()
    }

    private func arm() {
        withObservationTracking {
            _ = runtime.output
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else {
                    return
                }
                self.tracker.recordDisplaySubmission()
                self.arm()
            }
        }
    }
}

private enum PTYBenchmarkCommand {
    static func make(
        byteCount: Int,
        marker: String
    ) -> String {
        """
        /usr/bin/yes 'ALOFT-PERF-0123456789-abcdefghijklmnopqrstuvwxyz' \
        | /usr/bin/head -c \(byteCount)
        printf '\\n\(marker)\\n'
        /bin/sleep 30
        """
    }
}

private enum TerminalBenchmarkError: Error {
    case actionFailed(String)
    case markerTimedOut(String)
    case surfaceHolderReleased
    case swiftTermResourceMissing(String)
}

@MainActor
private enum PerformanceFixtureLifetime {
    static func retainUntilProcessExit(
        _ objects: AnyObject...
    ) {
        for object in objects {
            _ = Unmanaged.passRetained(object)
        }
    }
}

private func installSwiftTermResourcesForPerformanceTests()
    throws {
    let bundleName = "SwiftTerm_SwiftTerm.bundle"
    let testBundle = Bundle(
        for: TerminalPerformanceTests.self
    )
    let sourceURL = testBundle.bundleURL
        .deletingLastPathComponent()
        .appendingPathComponent(bundleName)
    guard FileManager.default.fileExists(
        atPath: sourceURL.path
    ) else {
        throw TerminalBenchmarkError
            .swiftTermResourceMissing(sourceURL.path)
    }
    let resourceDirectory = try XCTUnwrap(
        testBundle.resourceURL
    )
    let sourceShaderURL = sourceURL
        .appendingPathComponent("Shaders.metal")
    guard FileManager.default.fileExists(
        atPath: sourceShaderURL.path
    ) else {
        throw TerminalBenchmarkError
            .swiftTermResourceMissing(sourceShaderURL.path)
    }
    let destinationURL = resourceDirectory
        .appendingPathComponent("Shaders.metal")
    if FileManager.default.fileExists(
        atPath: destinationURL.path
    ) {
        let values = try destinationURL.resourceValues(
            forKeys: [.isRegularFileKey]
        )
        if values.isRegularFile == true {
            return
        }
        try FileManager.default.removeItem(
            at: destinationURL
        )
    }
    try FileManager.default.createDirectory(
        at: resourceDirectory,
        withIntermediateDirectories: true
    )
    try FileManager.default.copyItem(
        at: sourceShaderURL,
        to: destinationURL
    )
}

private extension Data {
    static func repeating(
        _ pattern: Data,
        count: Int
    ) -> Data {
        precondition(!pattern.isEmpty)
        var result = Data(capacity: count)
        while result.count + pattern.count <= count {
            result.append(pattern)
        }
        let remaining = count - result.count
        if remaining > 0 {
            result.append(pattern.prefix(remaining))
        }
        return result
    }

    func chunks(ofCount chunkSize: Int) -> [Data] {
        precondition(chunkSize > 0)
        return stride(from: 0, to: count, by: chunkSize).map {
            offset in
            Data(self[offset..<Swift.min(offset + chunkSize, count)])
        }
    }
}

private extension Array where Element == Double {
    var median: Double {
        let sorted = sorted()
        guard !sorted.isEmpty else { return 0 }
        return sorted[sorted.count / 2]
    }

    var optionalMedian: Double? {
        isEmpty ? nil : median
    }
}

private extension Array where Element == UInt64 {
    var median: UInt64 {
        let sorted = sorted()
        guard !sorted.isEmpty else { return 0 }
        return sorted[sorted.count / 2]
    }
}

private struct ProcessUsage {
    let cpuSeconds: Double
    let peakResidentBytes: UInt64
}

private func processUsage() -> ProcessUsage {
    var usage = rusage()
    let result = getrusage(RUSAGE_SELF, &usage)
    precondition(result == 0)
    return ProcessUsage(
        cpuSeconds:
            timevalSeconds(usage.ru_utime)
                + timevalSeconds(usage.ru_stime),
        peakResidentBytes: UInt64(max(0, usage.ru_maxrss))
    )
}

private func timevalSeconds(_ value: timeval) -> Double {
    Double(value.tv_sec)
        + Double(value.tv_usec) / 1_000_000
}

private func seconds(_ nanoseconds: UInt64) -> Double {
    max(Double(nanoseconds) / 1_000_000_000, .leastNonzeroMagnitude)
}
