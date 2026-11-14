// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import CoreFoundation
import Foundation
import MokumeDiagnostics

/// 記録を流して照らす係 (`mokume replay <記録>`・#3571)。
///
/// ## 誰が起こすか
///
/// **道具が決め、環境変数で子へ渡す** (``StartupReads/replay``・`MOKUME_RENDER` と同じ形)。値は記録のファイルの
/// 絶対パスで、子はウィンドウを開かず、観測・入力・つまみの区画も開かず (#1619)、画面を持たない全速の駆動
/// (``FullSpeedFrameDriver``) で回る。作品のコードは 1 行も変えない。
///
/// ## 何を当て、何を照らすか
///
/// 記録の単位は `advance()` の 1 回 (``ReplayRecorder``)。流す側も同じ単位で数え、入力を配る回 (記録の `step`) ごとに、
///
/// - **当てる**: その回に届いた入力 (届いた生の形のまま `InputState.enqueue` へ — 捨てる判定は同じ層で起きる)・
///   外から書かれたつまみの値・時刻を指定した観測の秒。開始の状態 (つまみの値・作者の時計の秒と止めているか) は
///   `setup()` の前に当てる
/// - **照らす**: その回のフレーム番号・描いたか・`expose` の値・画素のハッシュ (記録に在る枚だけ) を、**記録時の値と**
///   (ADR-0045 決定 10。流したものどうしを比べない)。最後に描いた枚の番号とハッシュも照らす
///
/// 最初に食い違った回のフレーム番号を名乗り、結果を `.mokume/replay/report.json` (`Schemas/replay-report.schema.json`)
/// に書く。照合がすべて一致すれば 0、食い違った・流せなかったなら 0 以外で終わる (終わらせるのは ``SketchApplication``)。
///
/// ## 速さを測る
///
/// フレームごとに `advance()` 1 回の時間 (CPU の側。描いた枚の組み立てと投入まで) を残し、いちばん重いフレームを名乗る。
/// 全体の時間は、最初の枚の前から最後の枚の絵を読み戻し終える (GPU の完了) まで。
final class ReplayPlayer {
    /// 結果のファイルの名前 (区画 `replay` の下)。
    static let reportName = "report.json"
    /// 結果の書式の版。
    static let reportVersion = 1
    /// 入力を配る回に届かないまま進めてよい `advance()` の数。越えたら流せないと名乗って止める。
    static let stallLimit = 10_000

    /// 照らした結果の 1 件 (最初に食い違ったもの)。
    struct Mismatch: Encodable, Equatable {
        /// 入力を配った回の通し番号 (記録の `step`)。開始の状態・最後の枚の食い違いでは `nil`。
        let step: Int?
        /// 記録のフレーム番号 (記録に無い回では流した側のフレーム番号)。
        let frame: Int
        /// 何が食い違ったか: `frame`・`drew`・`expose`・`pixelHash`・`step`・`last`・`params`。
        let what: String
        /// `expose` の名前・つまみの名前。
        let name: String?
        /// 記録の値と、流した値 (人に読む形)。無いものは `nil`。
        let recorded: String?
        let replayed: String?
    }

    /// フレームごとの時間。
    struct FrameTime: Encodable, Equatable {
        let frame: Int
        let seconds: Double
    }

    /// `.mokume/replay/report.json` の中身。
    struct Report: Encodable {
        struct Timing: Encodable {
            /// 最初の枚の前から、最後の枚の絵を読み戻し終えるまで (秒)。
            let seconds: Double
            /// いちばん重いフレーム。1 枚も描かなければ無い。
            let heaviest: FrameTime?
            /// 描いたフレームごとの時間 (フレーム番号の順)。
            let frames: [FrameTime]
        }
        let schemaVersion: Int
        let record: String
        let id: String?
        let matched: Bool
        let steps: Int
        let frames: Int
        let mismatches: Int
        let firstMismatch: Mismatch?
        let unreproducible: [String]
        let problem: String?
        let timing: Timing
    }

    /// 打たれた記録の場所 (結果に載せる)。
    let source: String
    /// 読んだ記録。読めなければ `nil` で、``problem`` が理由を持つ。
    let record: ReplayRecord?
    /// 結果を書く先。`nil` なら書かない (検査)。
    let reportURL: URL?
    /// 流せなかった理由 (記録が読めない・大きさが違う・途中で止まった)。
    private(set) var problem: String?

    private let byOrdinal: [Int: ReplayRecord.Step]
    private let lastOrdinal: Int
    /// 次に入力を配る回の通し番号。
    private(set) var nextOrdinal = 0
    private var openOrdinal: Int?
    private var exposed: [String: ExposedValue] = [:]
    private(set) var firstMismatch: Mismatch?
    private(set) var mismatches = 0
    private var advances = 0
    private var frameTimes: [FrameTime] = []
    private var began: Double?
    /// 書いた結果。**1 度だけ書く。**
    private(set) var report: Report?

    init(record: ReplayRecord, source: String, reportURL: URL?) {
        self.record = record
        self.source = source
        self.reportURL = reportURL
        var byOrdinal: [Int: ReplayRecord.Step] = [:]
        for step in record.steps { byOrdinal[step.step] = step }
        self.byOrdinal = byOrdinal
        self.lastOrdinal = record.steps.last?.step ?? -1
    }

    /// 流せない頼み。最初の回の前に結果を書いて終わる。
    init(source: String, problem: String, reportURL: URL?) {
        self.record = nil
        self.source = source
        self.reportURL = reportURL
        self.problem = problem
        self.byOrdinal = [:]
        self.lastOrdinal = -1
    }

    /// 結果を書く既定の先 (`<区画の基準>/.mokume/replay/report.json`)。道具も同じ場所を読む。
    static var defaultReport: URL {
        WorkDirectory.facet("replay").appendingPathComponent(reportName)
    }

    // MARK: - 起動

    /// 起動の環境から読む。**無ければ `nil`。** 読んだら環境から消す (``ReplayRequest/startup(environment:unset:say:)``
    /// と同じ — 合図はこのプロセスのもので、スケッチが起こす子へ継がせない)。
    ///
    /// **在って読めない値・読めない記録も、`nil` にしない。** ウィンドウへ倒すと、`mokume replay` を打った人の前で
    /// 作品がふつうに走り出す。理由を持った係を返し、``SketchApplication`` が最初の回の前に結果を書いて 0 以外で終わる。
    ///
    /// **環境を読むのはここだけ** — 一覧 (``StartupReads``) が読み場所としてこのファイルを名指している。
    static func startup(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        unset: (String) -> Void = { unsetenv($0) },
        reportURL: URL? = ReplayPlayer.defaultReport
    ) -> ReplayPlayer? {
        guard let given = environment[StartupReads.replay.key] else { return nil }
        unset(StartupReads.replay.key)
        guard given.hasPrefix("/"), given.count > 1 else {
            return ReplayPlayer(
                source: given,
                problem: "\(StartupReads.replay.key) is not the absolute path of a record (\(given)). "
                    + "Pass the record to mokume replay",
                reportURL: reportURL)
        }
        do {
            let record = try ReplayRecord.read(from: URL(fileURLWithPath: given))
            return ReplayPlayer(record: record, source: given, reportURL: reportURL)
        } catch {
            return ReplayPlayer(source: given, problem: error.reason, reportURL: reportURL)
        }
    }

    /// 作者の時計の開始を当てる口。**最初の枚の秒が 0 でないか止めている記録だけ** (`watch --keep-time` で作り直した
    /// 世代)。前の世代を外挿せず、記録の秒と止めているかをそのまま返す。書く先は持たない。
    var clockStart: ClockHandover? {
        guard let record, record.startSeconds != 0 || record.startPaused else { return nil }
        let snapshot = ClockHandover.Snapshot(
            seconds: record.startSeconds, isHeld: record.startPaused, isStill: false, rate: nil, at: 0,
            writer: 0, generation: 0)
        return ClockHandover(
            read: { .found(snapshot) }, write: { _ in }, isAlive: { _ in false }, warn: { _ in })
    }

    /// 流す前に、記録と作品が噛み合うかを見る。**噛み合わなければ流さない** (``problem``)。
    func check(width: Int, height: Int) {
        guard let record, problem == nil else { return }
        if record.width != width || record.height != height {
            problem =
                "The record was taken at \(record.width)×\(record.height) and this sketch draws at "
                + "\(width)×\(height), so its pictures cannot match"
        }
    }

    /// 記録が名乗った再現を保証しない理由を、流す側でも 1 度ずつ名乗る。
    func announceUnreproducible() {
        for reason in record?.unreproducible ?? [] {
            Diagnostics.warn("Replaying: the record says \(reason)")
        }
    }

    // MARK: - 当てる

    /// 開始のつまみの値を当てる。**保存を戻した後 (流す側は保存を持たない)・`setup()` の前。**
    func applyStart(to registry: ParamRegistry) {
        guard let record, problem == nil else { return }
        for param in record.startParams where registry.write(param.value, to: param.name) == nil {
            differ(
                Mismatch(
                    step: nil, frame: 0, what: "params", name: param.name, recorded: Self.describe(param.value),
                    replayed: nil))
        }
    }

    /// 次の回で時刻を指定した観測の枚を描くなら、その秒。
    var upcomingObserveTime: Float? {
        guard problem == nil else { return nil }
        return byOrdinal[nextOrdinal]?.observeTime
    }

    /// 入力を配る回が始まった。**記録のこの回のつまみの値を書き、入力を合流点へ積む。** 1 回の `advance()` で 1 度だけ。
    func beginStep(input: InputState, registry: ParamRegistry) {
        guard openOrdinal == nil, problem == nil else { return }
        let ordinal = nextOrdinal
        openOrdinal = ordinal
        nextOrdinal += 1
        guard let step = byOrdinal[ordinal] else { return }
        for param in step.params where registry.write(param.value, to: param.name) == nil {
            differ(
                Mismatch(
                    step: ordinal, frame: step.frame, what: "params", name: param.name,
                    recorded: Self.describe(param.value), replayed: nil))
        }
        for event in step.inputs { input.enqueue(event) }
    }

    /// `expose` された値。同じ名前は後のものが勝つ。
    func noteExposed(_ name: String, _ value: ExposedValue) {
        exposed[name] = value
    }

    /// フレームの頭で、差し出された値を捨てる (記録と同じ位置)。
    func clearExposed() { exposed.removeAll(keepingCapacity: true) }

    /// 回が終わった。**記録のこの回と照らす。**
    ///
    /// - Parameter hash: 画素のハッシュ。記録のこの回がハッシュを持つときだけ呼ぶ。
    func endStep(frame: Int, drew: Bool, drawFailed: Bool, hash: () -> String?) {
        guard let ordinal = openOrdinal else { return }
        openOrdinal = nil
        let values = exposed
        exposed.removeAll(keepingCapacity: true)
        guard problem == nil else { return }
        if drawFailed { Diagnostics.warn("Replaying: frame \(frame) failed to draw") }
        guard let expected = byOrdinal[ordinal] else {
            // 記録に無い回 (止めた作品で何も起きなかった回) に、流した側では何かが起きた
            if drew || drawFailed || !values.isEmpty {
                differ(
                    Mismatch(
                        step: ordinal, frame: frame, what: "step", name: nil, recorded: "nothing happened",
                        replayed: drew ? "drew frame \(frame)" : "exposed \(values.keys.sorted().joined(separator: ", "))"))
            }
            return
        }
        if expected.frame != frame {
            return differ(
                Mismatch(
                    step: ordinal, frame: expected.frame, what: "frame", name: nil, recorded: "\(expected.frame)",
                    replayed: "\(frame)"))
        }
        if expected.drew != drew {
            return differ(
                Mismatch(
                    step: ordinal, frame: expected.frame, what: "drew", name: nil, recorded: "\(expected.drew)",
                    replayed: "\(drew)"))
        }
        for name in Set(expected.expose.keys).union(values.keys).sorted() {
            let recorded = expected.expose[name]
            let replayed = values[name]?.paramValue
            guard !Self.same(recorded, replayed) else { continue }
            return differ(
                Mismatch(
                    step: ordinal, frame: expected.frame, what: "expose", name: name,
                    recorded: recorded.map(Self.describe), replayed: replayed.map(Self.describe)))
        }
        if let recorded = expected.pixelHash {
            let replayed = hash()
            if replayed != recorded {
                return differ(
                    Mismatch(
                        step: ordinal, frame: expected.frame, what: "pixelHash", name: nil, recorded: recorded,
                        replayed: replayed ?? "could not be read back"))
            }
        }
    }

    // MARK: - 進み

    /// `advance()` を 1 回始める。最初の 1 回の時刻が全体の時間の起点になる。
    func beginAdvance(at time: Double) {
        if began == nil { began = time }
        advances += 1
        // 入力を配る回に届かないまま進み続ける (止まった・観測を待ち続ける) なら、流せないと名乗る
        if problem == nil, advances - nextOrdinal > Self.stallLimit {
            problem =
                "The replay stopped reaching the sketch's input: \(Self.stallLimit) frames passed without a step "
                + "(at step \(nextOrdinal) of \(lastOrdinal + 1))"
        }
    }

    /// 描いた枚の時間 (`advance()` 1 回ぶん)。
    func noteFrameTime(frame: Int, seconds: Double) {
        frameTimes.append(FrameTime(frame: frame, seconds: seconds))
    }

    /// 記録の回をすべて流し終えたか、流せなくなったか。
    var isFinished: Bool { problem != nil || (openOrdinal == nil && nextOrdinal > lastOrdinal) }

    /// 流し終えた。**最後の枚を照らし、結果を書く。** 2 度目からは何もしない。
    ///
    /// - Parameters:
    ///   - frame: 流した側が最後に描いた枚の番号。
    ///   - lastHash: 最後の枚の画素のハッシュ。記録が最後の枚を持つときだけ呼ぶ。
    ///   - now: いまの時刻 (全体の時間の終わり)。
    ///   - stoppedEarly: 終わりきる前に止められたなら、その理由。
    @discardableResult
    func finish(frame: Int, lastHash: () -> String?, now: Double, stoppedEarly: String? = nil) -> Report {
        if let report { return report }
        if problem == nil, let stoppedEarly, !isFinished { problem = stoppedEarly }
        if problem == nil, let last = record?.last {
            if last.frame != frame {
                differ(
                    Mismatch(
                        step: nil, frame: last.frame, what: "last", name: nil, recorded: "frame \(last.frame)",
                        replayed: "frame \(frame)"))
            } else {
                let replayed = lastHash()
                if replayed != last.pixelHash {
                    differ(
                        Mismatch(
                            step: nil, frame: last.frame, what: "last", name: nil, recorded: last.pixelHash,
                            replayed: replayed ?? "could not be read back"))
                }
            }
        }
        let heaviest = frameTimes.max { $0.seconds < $1.seconds }
        let report = Report(
            schemaVersion: Self.reportVersion, record: source, id: record?.id,
            matched: problem == nil && mismatches == 0, steps: min(nextOrdinal, lastOrdinal + 1), frames: frame,
            mismatches: mismatches, firstMismatch: firstMismatch, unreproducible: record?.unreproducible ?? [],
            problem: problem,
            timing: Report.Timing(
                seconds: max(0, now - (began ?? now)), heaviest: heaviest, frames: frameTimes))
        self.report = report
        write(report)
        return report
    }

    /// 結果を人へ 1 行で言う (道具の端末へ出る)。
    static func summary(of report: Report) -> String {
        let place = report.record
        if let problem = report.problem { return "Could not replay \(place): \(problem)" }
        let timing = report.timing
        let heaviest = timing.heaviest.map {
            "; the heaviest frame was \($0.frame) at \(Self.milliseconds($0.seconds))"
        }
        let seconds = String(format: "%.2f", timing.seconds)
        guard let first = report.firstMismatch else {
            return "Replayed \(report.frames) frames of \(place) in \(seconds) s\(heaviest ?? ""): every check matched the record"
        }
        var what = first.what
        if let name = first.name { what += " \(name)" }
        let values = "recorded \(first.recorded ?? "nothing"), replayed \(first.replayed ?? "nothing")"
        return "The replay of \(place) first differed from the record at frame \(first.frame): \(what) (\(values)). "
            + "\(report.mismatches) check\(report.mismatches == 1 ? "" : "s") differed in all"
    }

    // MARK: - 内側

    private func differ(_ mismatch: Mismatch) {
        if firstMismatch == nil { firstMismatch = mismatch }
        mismatches += 1
    }

    private func write(_ report: Report) {
        guard let reportURL else { return }
        do {
            try FileManager.default.createDirectory(
                at: reportURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try AtomicFile.writeJSON(report, to: reportURL)
        } catch {
            Diagnostics.warn("Could not write the replay report to \(reportURL.path): \(Diagnostics.reason(error))")
        }
    }

    /// 値が同じか。**有限でない数は記録に残らない** (``SketchRuntime/expose(_:_:)`` が溜めない) ので、数はそのまま比べる。
    private static func same(_ recorded: ParamValue?, _ replayed: ParamValue?) -> Bool {
        recorded == replayed
    }

    /// 値を人に読む形にする (`{"type", "value"}` の値だけ)。
    static func describe(_ value: ParamValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        guard let data = try? encoder.encode(ParamValue.Body(value)) else { return "\(value)" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func milliseconds(_ seconds: Double) -> String {
        String(format: "%.1f ms", seconds * 1000)
    }
}
