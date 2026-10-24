// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import MokumeDiagnostics
import QuartzCore
import Synchronization

/// 作り直しをまたいで、作者の時計を新しい世代へ渡す (`mokume watch --keep-time`・[#2414])。
///
/// `watch` は `.swift` を保存するたびに、スケッチを新しいプロセスで作り直す。既定では新しい世代の
/// ``SketchPart/time`` は 0 から始まる (``SketchPart/jumpTime(_:)`` の説明)。旗 `--keep-time` を付けた
/// 見張りは、子の環境に **1 つのファイルの場所** (``StartupReads/keepTime``) を渡す。場所を受けた世代は、
///
/// - 作者の時計 (止めた・飛んだぶんを含む秒と、止めているか・枚が止まっているか) を、**必要なときだけ**
///   そのファイルへ書く。置く段は main の外で走らせ、続けて頼まれたら最新のものだけを書く (``FileSink``)
/// - **`setup()` の前**に、前の世代が書いたものを読んで時計へ入れる。そのあと**最初の枚の時点**で、
///   `setup()` が時計に触っていなければ読み直して始め直す (``FrameTiming/advance(at:displayTime:)``)
///
/// 見張りは何も計算しない。**作り直しの間も前の世代は回り続ける**ので、新しい世代は最初の枚を出す時点
/// (`moment`) で「前の世代がいま描いていた秒」を求める (``Snapshot/start(at:writerIsAlive:)``)。ただし
/// 外挿するのは、前の世代が**枚を出し続けている**と言えるときだけである。止めている (`pauseTime()`)・
/// 枚が止まっている (`noLoop()`・外からの停止)・前の世代がもう居ない (落ちた)・進み方がまだ測れていない
/// ときは、足さずに書いた秒から始める。
///
/// **運ぶのは作者の時計の秒と、止めているかだけ** — ``SketchPart/frameCount``・乱数の列・``SketchPart/deltaTime``
/// で積んだ状態 (``Countdown`` を含む)・作者の変数は運ばない。**渡す秒は倍精度のまま** (作者に見せる単精度の
/// ``SketchPart/time`` ではない。長く回した見張りの作り直しの後も、周期の位相 ``SketchPart/phase(period:)`` が
/// 刻みを粗くしない)。
///
/// **書き手は世代で区別する。** 世代は書き手が生まれた時刻 (``generation``。端末の中のどのプロセスでも同じ
/// 時間軸) で、読めたかによらず、後から起きた世代ほど大きい。古い世代は書く直前にファイルの世代を見て、
/// **より新しい世代の書き手が生きていれば**書かずに見送る。前の世代は SIGTERM で止め終えるまで書き続けるので、
/// これが無いと新しい世代が別の秒で止めた直後に、前の世代の時計で上書きされうる。新しい世代の書き手が
/// 居なくなっていれば、見送りは取り消されて書く。
///
/// 場所を受けない実行 (旗の無い `watch`・`run`・`render`) は、何も読まず何も書かない。
///
/// [#2414]: https://github.com/mokume-metal/mokume/issues/2414
final class ClockHandover {
    /// 作者の時計が、実時間の時計か、フレーム番号から導く時計か。書く頻度と外挿の誤差の許し方が違う。
    nonisolated enum Kind: Equatable, Sendable {
        /// 実時間で進む。止めていなければ書いた後も実時間で進むので、外挿は正確である。
        case realtime
        /// フレーム番号で進む。重いフレームでは実時間より遅く進むので、測った進み方で外挿する。
        /// `interval` は 1 フレームぶんの秒。
        case frames(interval: Double)

        /// 外挿が実際の秒からこれ以上ずれたら、書き直す (秒)。フレームの時計は 1 フレーム以内を許す。
        var tolerance: Double {
            switch self {
            case .realtime: 0.001
            case .frames(let interval): max(0.001, interval)
            }
        }
    }

    /// 前の世代が書いた、作者の時計。
    nonisolated struct Snapshot: Codable, Equatable, Sendable {
        /// いまの書式の版。**読めない版は使わず**、読めなかったと言って 0 秒から始める。書式を変えるときは上げる。
        static let currentVersion = 1

        /// 書式の版。
        var version: Int = Snapshot.currentVersion
        /// 作者の時計の秒 (``FrameTiming/seconds``)。止めた・飛んだぶんを含む。
        var seconds: Double
        /// 止めているか (``SketchPart/pauseTime()``)。
        var isHeld: Bool
        /// 枚が止まっているか (``SketchPart/noLoop()`` で作者が止めた・外から止めた)。止まっている間、窓に出ているのは
        /// ``seconds`` の枚で、時計は進んで見えない。
        var isStill: Bool
        /// 止めていない間に、実時間 1 秒で進む作者の時計の秒。実時間の時計は 1、フレームの時計は測った値
        /// (重いフレームで 1 を下回る)。**まだ測れていなければ `nil`** で、外挿には使わない。
        var rate: Double?
        /// 書いた時刻 (`CACurrentMediaTime()`。端末の中のどのプロセスでも同じ時間軸)。
        var at: Double
        /// 書いたプロセスの番号。落ちて消えた世代の時間を足さないために、生きているかを見る。
        var writer: Int32
        /// 書いた世代 (``ClockHandover/generation``)。新しい世代の書いたファイルを、古い世代が上書きしない。
        var generation: Double

        /// 読める値か。壊れたファイルから非有限の秒を受け取ると、時計の原点が非有限になる。
        var isUsable: Bool {
            seconds.isFinite && at.isFinite && generation.isFinite && (rate.map { $0.isFinite && $0 >= 0 } ?? true)
        }

        /// 新しい世代の最初の枚 (時刻 `moment`) が始める、作者の時計の秒と、止めているか。
        ///
        /// - 止めていれば、止めた秒のまま
        /// - 枚が止まっていれば (``isStill``)、窓に出ている枚の秒のまま。止まっていた間の時間は足さない
        /// - 書き手がもう居なければ、書いた秒のまま (居ない間は進まない)。落ちた世代を、直した後に
        ///   消えていた時間ぶん先から始めない
        /// - 進み方がまだ測れていなければ (``rate`` が `nil`)、書いた秒のまま
        /// - それ以外は、書いた後に流れた時間に ``rate`` を掛けたぶん進める。**前の世代が最後の枚を描いてから
        ///   新しい世代が最初の枚を出すまで** (ビルドと起動) も、前の世代は回り続けているからである。時刻が
        ///   戻っていれば (`moment` が書いた時刻より前) 進めない
        func start(at moment: Double, writerIsAlive: Bool = true) -> (seconds: Double, isHeld: Bool) {
            if isHeld { return (seconds, true) }
            guard !isStill, writerIsAlive, let rate else { return (seconds, false) }
            return (seconds + rate * max(0, moment - at), false)
        }
    }

    /// 読んだ結果。
    nonisolated enum Reading: Equatable, Sendable {
        /// ファイルが無い。最初の世代では当たり前なので、言わない。
        case absent
        /// ファイルはあるが使えない (読めない・壊れている・非有限・読めない版)。理由は人に読める 1 句。
        case unusable(reason: String)
        case found(Snapshot)
    }

    /// 前の世代が書いたものと、その書き手が生きているか。
    nonisolated struct Predecessor: Equatable, Sendable {
        var snapshot: Snapshot
        var writerIsAlive: Bool

        func start(at moment: Double) -> (seconds: Double, isHeld: Bool) {
            snapshot.start(at: moment, writerIsAlive: writerIsAlive)
        }
    }

    private let read: () -> Reading
    private let write: (Snapshot) -> Void
    private let isAlive: (Int32) -> Bool
    private let warn: (String) -> Void
    private let writer: Int32
    private let path: String?
    private var warnedUnusable = false
    private var lastWritten: Snapshot?
    /// この世代の番号。**生まれた時刻**なので、読めたかによらず後の世代ほど大きい。
    let generation: Double
    /// フレームの時計の進み方を測る窓の起点 (フレーム番号と時刻)。止めている間・種類が変わったときに捨てる。
    private var rateAnchor: (frames: Int, at: Double)?
    /// 測れた進み方。まだ測れていなければ `nil`。
    private var measuredRate: Double?

    /// 外挿が合っている間も書き直す間隔 (秒)。フレームの時計は、この間隔で進み方の測り直しが届く。
    static let refreshInterval: Double = 0.5
    /// 状態が変わらない書き直しの下限の間隔 (秒)。毎枚 `jumpTime` する作品でも、書くのは 1 秒に 20 回までになる。
    /// 止めた・枚が止まったなどの状態の変わり目は、この間隔に縛られない。
    static let minimumWriteGap: Double = 0.05

    /// - Parameters:
    ///   - read: 前の世代が書いたものを読む。**検査から差し替える。**
    ///   - write: 書く先。**検査から差し替える。** 本番は置く段を main の外へ渡すだけで、すぐ戻る。
    ///   - isAlive: 番号のプロセスが生きているか。
    ///   - warn: 人への知らせの出口。
    ///   - writer: 自分のプロセスの番号。
    ///   - generation: この世代の番号。
    ///   - path: ファイルの場所 (知らせの文面に入れる)。
    init(
        read: @escaping () -> Reading, write: @escaping (Snapshot) -> Void,
        isAlive: @escaping (Int32) -> Bool = ClockHandover.processIsAlive,
        warn: @escaping (String) -> Void = Diagnostics.warn,
        writer: Int32 = getpid(), generation: Double = CACurrentMediaTime(), path: String? = nil
    ) {
        self.read = read
        self.write = write
        self.isAlive = isAlive
        self.warn = warn
        self.writer = writer
        self.generation = generation
        self.path = path
    }

    /// ファイルを読み、同じファイルへ書く。置く段は main の外 (``FileSink``)。
    convenience init(path: String, warn: @escaping @Sendable (String) -> Void = Diagnostics.warn) {
        let sink = FileSink(path: path, warn: warn)
        self.init(
            read: { Self.read(path: path) }, write: { sink.submit($0) }, warn: warn, path: path)
    }

    /// 起動の環境から作る。**無ければ `nil`。** 読んだら環境から消す (``ShaderOrigin/startup()`` と同じ) —
    /// 合図はこのプロセスを起こした見張りが渡したもので、このプロセスがさらに起こす子のものではない。
    /// **ここではファイルを読まない** — 読むのは `setup()` の前と最初の枚の時点である。
    ///
    /// **環境を読むのはここだけ** — 一覧 (``StartupReads``) が読み場所としてこのファイルを名指している。
    static func startup(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        unset: (String) -> Void = { unsetenv($0) }
    ) -> ClockHandover? {
        let given = environment[StartupReads.keepTime.key]
        if given != nil { unset(StartupReads.keepTime.key) }
        guard let path = path(from: given) else { return nil }
        return ClockHandover(path: path)
    }

    /// 環境に載った場所を解く。空白だけの値と絶対パスでない値は渡されていないものとして扱う
    /// (相対の値は読む側の作業ディレクトリで別の場所になる)。
    static func path(from given: String?) -> String? {
        guard let trimmed = given?.trimmingCharacters(in: .whitespacesAndNewlines),
            trimmed.hasPrefix("/")
        else { return nil }
        return trimmed
    }

    /// 書く側が同じ場所に持つ、錠のファイルの場所。読み・比べ・置き換えを他のプロセスと不可分にする。
    /// **見張りが始めと終わりに、ファイルと一緒に消す。**
    nonisolated static func lockPath(for path: String) -> String { path + ".lock" }

    /// 番号のプロセスが生きているか。許されない (`EPERM`) のは居る。
    nonisolated static func processIsAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    /// ファイルを読む。**読めない版は使えないものとして返す** — 書式を変えた後の mokume と混ざっても、
    /// 値を取り違えず、0 秒から始めて言う。
    nonisolated static func read(path: String) -> Reading {
        guard FileManager.default.fileExists(atPath: path) else { return .absent }
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            return .unusable(reason: Diagnostics.reason(error))
        }
        struct Header: Decodable { var version: Int? }
        do {
            let header = try JSONDecoder().decode(Header.self, from: data)
            guard header.version == Snapshot.currentVersion else {
                let found = header.version.map { "format \($0)" } ?? "no format version"
                return .unusable(
                    reason: "it has \(found), and this mokume reads format \(Snapshot.currentVersion)")
            }
            let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
            guard snapshot.isUsable else {
                return .unusable(reason: "the clock in it is not a usable time")
            }
            return .found(snapshot)
        } catch {
            return .unusable(reason: Diagnostics.reason(error))
        }
    }

    /// 前の世代が書いたものを、いま読む。無い・使えないなら `nil` (0 秒から始める)。
    ///
    /// **使えないときは 1 度だけ、原因と次にすることを言う。** 黙って 0 秒から始めると、旗を打ったのに
    /// 時計が続かない理由が分からない。ファイルが無いのは、最初の世代では当たり前なので言わない。
    func predecessor() -> Predecessor? {
        switch read() {
        case .absent:
            return nil
        case .unusable(let reason):
            if !warnedUnusable {
                warnedUnusable = true
                let place = path.map { " (\($0))" } ?? ""
                warn(
                    "--keep-time: could not read the previous version's clock\(place): \(reason). "
                        + "This version starts from 0 s; it writes its own clock as it runs, so the next "
                        + "rebuild continues from here. If this keeps happening, check that the "
                        + "temporary directory (TMPDIR) is readable and writable")
            }
            return nil
        case .found(let snapshot):
            return Predecessor(snapshot: snapshot, writerIsAlive: isAlive(snapshot.writer))
        }
    }

    /// この枚の作者の時計を書く。**必要なときだけ書く。**
    ///
    /// - 止めているか・枚が止まっているかが変わったとき、止めている・止まっている間に秒が変わったとき
    /// - 止めていない間は、前に書いたものからの外挿 (``Snapshot/rate`` を掛ける) が実際の秒と
    ///   ずれたとき (飛んだ・戻した。フレームの時計は 1 フレームより大きくずれたとき)、
    ///   またはしばらく書いていないとき (``refreshInterval``)。**この 2 つは ``minimumWriteGap`` を空ける**
    ///
    /// - Parameters:
    ///   - seconds: 作者の時計の秒 (観測の指定秒ではない)。
    ///   - isHeld: 止めているか。
    ///   - isStill: 枚が止まっているか。
    ///   - kind: 時計の種類。
    ///   - frames: これまでに進めたフレームの数 (フレームの時計の進み方を測る)。
    ///   - moment: この枚の時刻。
    func publish(
        seconds: Double, isHeld: Bool, isStill: Bool, kind: Kind, frames: Int, at moment: Double
    ) {
        let rate = rate(of: kind, isHeld: isHeld || isStill, frames: frames, at: moment)
        let snapshot = Snapshot(
            seconds: seconds, isHeld: isHeld, isStill: isStill, rate: rate, at: moment, writer: writer,
            generation: generation)
        guard snapshot.isUsable, needsWrite(snapshot, tolerance: kind.tolerance) else { return }
        lastWritten = snapshot
        write(snapshot)
    }

    /// 止めていない間の作者の時計の進み方。実時間の時計は 1、フレームの時計は `refreshInterval` ごとに測り直し、
    /// **測れるまでは `nil`**。**進んだフレームの数で測る** — 飛んだ秒は含まない。
    private func rate(of kind: Kind, isHeld: Bool, frames: Int, at moment: Double) -> Double? {
        guard case .frames(let interval) = kind else {
            rateAnchor = nil
            return 1
        }
        if isHeld {
            // 進まない間は測らない。再開したときに測り直す
            rateAnchor = nil
            return measuredRate
        }
        guard let anchor = rateAnchor else {
            rateAnchor = (frames, moment)
            return measuredRate
        }
        let elapsed = moment - anchor.at
        if elapsed >= Self.refreshInterval {
            measuredRate = Double(frames - anchor.frames) * interval / elapsed
            rateAnchor = (frames, moment)
        }
        return measuredRate
    }

    private func needsWrite(_ snapshot: Snapshot, tolerance: Double) -> Bool {
        guard let last = lastWritten else { return true }
        if last.isHeld != snapshot.isHeld || last.isStill != snapshot.isStill { return true }
        if snapshot.isHeld || snapshot.isStill { return snapshot.seconds != last.seconds }
        // 進み方が測れた
        if last.rate == nil, snapshot.rate != nil { return true }
        let gap = snapshot.at - last.at
        guard gap >= Self.minimumWriteGap else { return false }
        // 測れていない間は、実時間と同じ進み方として比べる (外挿に使うわけではなく、書くかどうかの目安)
        let predicted = last.seconds + (last.rate ?? 1) * max(0, gap)
        return abs(predicted - snapshot.seconds) > tolerance || gap >= Self.refreshInterval
    }

    /// ファイルへ置く。**置く段は main の外で走らせる** — JSON を作って置き換える処理がフレームの予算に乗らない。
    /// 本体が既に持つ書き込みの口に載せる: 行き先ごとに 1 本ずつ、書いている間に頼まれたものは最後の 1 つに
    /// 畳む (``WriteLanes``)。頼みが止んでも、最後の 1 つは書かれる。原子的な置き方は ``AtomicFile``。
    nonisolated final class FileSink: Sendable {
        private struct State {
            var writes = 0
            var warnedWrite = false
            var lockDescriptor: Int32?
        }

        private let path: String
        private let warn: @Sendable (String) -> Void
        private let isAlive: @Sendable (Int32) -> Bool
        private let lanes = WriteLanes()
        private let state = Mutex(State())

        init(
            path: String, warn: @escaping @Sendable (String) -> Void,
            isAlive: @escaping @Sendable (Int32) -> Bool = { ClockHandover.processIsAlive($0) }
        ) {
            self.path = path
            self.warn = warn
            self.isAlive = isAlive
        }

        deinit {
            if let descriptor = state.withLock({ $0.lockDescriptor }) { close(descriptor) }
        }

        /// 書いてほしいものを渡す。**すぐ戻る。** 置き場所と一時ファイルの名前を決める準備だけ main で済ませ
        /// (``AtomicFile/reserve(_:)``)、置く段は裏で走る。
        @MainActor func submit(_ snapshot: Snapshot) {
            let placement: AtomicFile.Placement
            do {
                placement = try AtomicFile.reserve(URL(fileURLWithPath: path))
            } catch {
                return reportWriteFailure(error)
            }
            lanes.enqueue(path, drop: {}) { [self] in place(snapshot, placement) }
        }

        /// 書いた回数 (検査用)。
        var writeCount: Int { state.withLock { $0.writes } }

        /// 頼まれたものがすべて書かれる (あるいは見送られる) まで待つ。**検査のためだけ。**
        func settle() {
            while lanes.isBusy(path) { Thread.sleep(forTimeInterval: 0.005) }
        }

        /// 錠を取ってファイルの世代を見て、より新しい世代の書き手が生きていれば見送る。居なければ原子的に置き換える。
        private func place(_ snapshot: Snapshot, _ placement: AtomicFile.Placement) {
            let descriptor = lock()
            defer { if let descriptor { flock(descriptor, LOCK_UN) } }
            if case .found(let existing) = ClockHandover.read(path: path),
                existing.generation > snapshot.generation, isAlive(existing.writer)
            {
                // より新しい世代が生きている。その時計を上書きしない。**次の頼みで見直す** — その世代が
                // 居なくなれば、見送りは取り消される
                return
            }
            do {
                let data = try JSONEncoder().encode(snapshot)
                try placement.place { try data.write(to: $0) }
                state.withLock { $0.writes += 1 }
            } catch {
                reportWriteFailure(error)
            }
        }

        /// 書けなかったことを 1 度だけ、原因と次にすることとともに言う。
        private func reportWriteFailure(_ error: any Error) {
            let first = state.withLock { state -> Bool in
                defer { state.warnedWrite = true }
                return !state.warnedWrite
            }
            guard first else { return }
            warn(
                "--keep-time: could not write the clock to \(path): \(Diagnostics.reason(error)). "
                    + "The next rebuild will start from 0 s. Check that the temporary directory "
                    + "(TMPDIR) exists and is writable")
        }

        /// 錠のファイルを開いて排他の錠を取る。開けなければ錠なしで続ける (書けない場合は、書く側が言う)。
        private func lock() -> Int32? {
            let descriptor = state.withLock { state -> Int32? in
                if state.lockDescriptor == nil {
                    let opened = open(ClockHandover.lockPath(for: path), O_CREAT | O_RDWR, 0o600)
                    if opened >= 0 { state.lockDescriptor = opened }
                }
                return state.lockDescriptor
            }
            guard let descriptor, flock(descriptor, LOCK_EX) == 0 else { return nil }
            return descriptor
        }
    }
}
