// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Darwin
import Foundation
import mokume

/// つまみの変化を、時刻付きの 1 行に畳む (#4130)。
///
/// **読むのは子の応答 (`.mokume/params/report.json`) だけである。** 書き手 (窓のつまみ・`--remote` の
/// 受け口・MCP) の側で書かないのは、範囲へ収められた値まで含めて、子が実際に持った値を書くため。
/// 誰が動かしたかは、応答が echo する要求の識別子の頭で読む (``KnobWriter``)。
///
/// - **echo が変わった応答の差分だけを書く。** echo が変わらずに値が動くのは、スケッチ自身の代入か、
///   作り直しで子が入れ替わったときで、つまみを動かしたのではない
/// - **動いている間は書かない。** 名前ごとに最初の値と最新の値を持ち、``settle`` の間動かなかったら
///   1 行に畳む (スライダーを 1 回引いて離すと 1 行)。元の値へ戻したなら書かない
/// - 純粋な値で、時刻は呼ぶ側が渡す。読み書きの駆動は ``KnobChangeWatcher``
nonisolated struct KnobChangeLog {
    /// 動かなくなってから畳むまでの間。
    static let settle: TimeInterval = 0.5

    /// 畳んだ 1 件。
    struct Change: Equatable {
        let name: String
        let from: ParamValue
        let to: ParamValue
        /// 最後に値が動いたのを読んだ時刻。
        let at: Date
        /// `window`・`phone`・`other`。
        let writer: String
    }

    private struct Move {
        let from: ParamValue
        var to: ParamValue
        var writer: String
        var last: Date
    }

    /// 前の応答の値。まだ 1 枚も読んでいなければ `nil`。
    private var baseline: [String: ParamValue]?
    private var lastEcho: String?
    /// 動いている名前。畳む順を保つため、最初に動いた順に並べる。
    private var moving: [(name: String, move: Move)] = []
    /// 名前の欄の幅。見たことのある名前の最大で、行どうしの桁を揃える (縮めない)。
    private(set) var nameWidth = 0
    /// つまみごとの値の欄の幅。見たことのある綴りの最大で、同じつまみの行どうしの桁を揃える (縮めない)。
    private(set) var valueWidths: [String: Int] = [:]

    /// 応答を 1 枚読んだ。
    ///
    /// - Parameters:
    ///   - echo: 応答が echo した要求の識別子。
    ///   - values: 応答の宣言の、名前ごとのいまの値 (読めなかった宣言は除いて渡す)。
    mutating func observe(echo: String?, values: [String: ParamValue], at now: Date) {
        defer {
            baseline = values
            lastEcho = echo
        }
        nameWidth = max(nameWidth, values.keys.map(\.count).max() ?? 0)
        for (name, value) in values {
            valueWidths[name] = max(valueWidths[name] ?? 0, KnobText.value(of: value).count)
        }
        guard let baseline, let echo, echo != lastEcho else { return }
        let writer = KnobWriter(echo: echo)?.rawValue ?? "other"
        for (name, value) in values.sorted(by: { $0.key < $1.key }) {
            // 新しく現れた名前・型の変わった名前は、動かしたのではなく宣言が変わった
            guard let before = baseline[name], before != value, before.typeName == value.typeName else { continue }
            if let index = moving.firstIndex(where: { $0.name == name }) {
                moving[index].move.to = value
                moving[index].move.writer = writer
                moving[index].move.last = now
            } else {
                moving.append((name, Move(from: before, to: value, writer: writer, last: now)))
            }
        }
    }

    /// ``settle`` の間動かなかった名前を畳んで返す。`all` なら待たずに全部 (終わるとき)。
    mutating func flush(at now: Date, all: Bool = false) -> [Change] {
        var settled: [Change] = []
        moving.removeAll { entry in
            guard all || now.timeIntervalSince(entry.move.last) >= Self.settle else { return false }
            if entry.move.from != entry.move.to {
                settled.append(
                    Change(
                        name: entry.name, from: entry.move.from, to: entry.move.to, at: entry.move.last,
                        writer: entry.move.writer))
            }
            return true
        }
        return settled
    }

    /// 1 行に綴る: `12:03:04.512  radius  0.40 → 0.55  (phone)`。
    ///
    /// 値の綴りは窓のつまみと同じ (``KnobText``) で、`valueWidth` へ右寄せする (同じつまみの行で
    /// 桁が揃う)。`colored` なら時刻と書き手を薄く、名前を太くする — 端末でない出力先には制御文字を出さない。
    static func line(
        _ change: Change, nameWidth: Int, valueWidth: Int = 0, colored: Bool, zone: TimeZone = .current
    ) -> String {
        let name = change.name.padding(toLength: max(nameWidth, change.name.count), withPad: " ", startingAt: 0)
        let time = clock(change.at, in: zone)
        func aligned(_ value: ParamValue) -> String {
            let text = KnobText.value(of: value)
            return String(repeating: " ", count: max(0, valueWidth - text.count)) + text
        }
        let values = "\(aligned(change.from)) → \(aligned(change.to))"
        let writer = "(\(change.writer))"
        guard colored else { return "\(time)  \(name)  \(values)  \(writer)" }
        return "\(dim)\(time)\(reset)  \(bold)\(name)\(reset)  \(values)  \(dim)\(writer)\(reset)"
    }

    /// `HH:mm:ss.SSS` (24 時間制)。書式の地域設定に左右されないよう、成分から組む。
    static func clock(_ date: Date, in zone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.hour, .minute, .second, .nanosecond], from: date)
        return String(
            format: "%02d:%02d:%02d.%03d", parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0,
            (parts.nanosecond ?? 0) / 1_000_000)
    }

    private static let dim = "\u{1B}[2m"
    private static let bold = "\u{1B}[1m"
    private static let reset = "\u{1B}[0m"
}

/// ``KnobChangeLog`` を、つまみの面の応答を見張って回す。
///
/// 自分の直列の列で 50 ms ごとに応答を改訂の印 (``FileStamp``) で見て、変わっていれば読む (受け口の
/// `RemoteServer` と同じ読み方)。`run` は子を待つ間 main を塞ぐので main には載せない。
nonisolated final class KnobChangeWatcher: @unchecked Sendable {
    private let queue = DispatchQueue(label: "mokume.knob-change-log")
    private let reportURL: URL
    private let colored: Bool
    private let write: @Sendable (String) -> Void
    private var log = KnobChangeLog()
    private var stamp: FileStamp?
    private var timer: DispatchSourceTimer?

    /// - Parameter write: 1 行を書く口。既定は見張りの行と同じく、速さの行を消してから標準出力へ。
    init(
        facet: URL, colored: Bool = isatty(STDOUT_FILENO) != 0,
        write: @escaping @Sendable (String) -> Void = { WatchCommand.say($0) }
    ) {
        reportURL = WorkDirectory.reportURL(under: facet)
        self.colored = colored
        self.write = write
    }

    /// 見張りを起こして返す。
    static func start(facet: URL) -> KnobChangeWatcher {
        let watcher = KnobChangeWatcher(facet: facet)
        watcher.start()
        return watcher
    }

    func start() {
        queue.sync {
            guard timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(50), leeway: .milliseconds(10))
            timer.setEventHandler { [weak self] in self?.tick(at: Date()) }
            self.timer = timer
            timer.resume()
        }
    }

    /// 止める。動いている途中の変化は待たずに書く (終わる直前に動かした値を落とさない)。
    func stop() {
        queue.sync {
            guard let timer else { return }
            timer.cancel()
            self.timer = nil
            readIfChanged(at: Date())
            emit(log.flush(at: Date(), all: true))
        }
    }

    /// 1 拍。検査からは列の外で直に呼ぶ。
    func tick(at now: Date) {
        readIfChanged(at: now)
        emit(log.flush(at: now))
    }

    private func readIfChanged(at now: Date) {
        guard let modified = FileStamp.of(reportURL), modified != stamp else { return }
        guard let data = try? Data(contentsOf: reportURL),
            let report = try? JSONDecoder().decode(RemoteKnobs.Report.self, from: data)
        else { return }  // 書きかけ・読めない外枠は確定させず、次の拍で読み直す
        stamp = modified
        var values: [String: ParamValue] = [:]
        for case .declaration(let declaration) in report.params { values[declaration.name] = declaration.value }
        log.observe(echo: report.id, values: values, at: now)
    }

    private func emit(_ changes: [KnobChangeLog.Change]) {
        for change in changes {
            write(
                KnobChangeLog.line(
                    change, nameWidth: log.nameWidth, valueWidth: log.valueWidths[change.name] ?? 0,
                    colored: colored))
        }
    }
}
