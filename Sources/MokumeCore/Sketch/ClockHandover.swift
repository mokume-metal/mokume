// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import MokumeDiagnostics

/// 作り直しをまたいで、作者の時計を新しい世代へ渡す (`mokume watch --keep-time`・[#2414])。
///
/// `watch` は `.swift` を保存するたびに、スケッチを新しいプロセスで作り直す。既定では新しい世代の
/// ``SketchPart/time`` は 0 から始まる (``SketchPart/jumpTime(_:)`` の説明)。旗 `--keep-time` を付けた
/// 見張りは、子の環境に **1 つのファイルの場所** (``StartupReads/keepTime``) を渡す。場所を受けた世代は、
///
/// - 作者の時計 (止めた・飛んだぶんを含む秒と、止めているか) を、**必要なときだけ**そのファイルへ書く。
///   書く処理は main の外の直列のキューで行い、続けて頼まれたら最新のものだけを書く (``FileSink``)
/// - **`setup()` の前**に、前の世代が書いたものを読んで時計へ入れる。そのあと**最初の枚の時点**で、
///   `setup()` が時計に触っていなければ読み直して始め直す (``FrameTiming/advance(at:)``)
///
/// 見張りは何も計算しない。**作り直しの間も前の世代は回り続ける**ので、新しい世代は最初の枚を出す時点
/// (`moment`) で「前の世代がいま描いていた秒」を求める (``Snapshot/start(at:writerIsAlive:)``)。前の世代が
/// すでに居ない (落ちた) ときは、居ない間の時間を足さず、最後に書いた秒から始める。
///
/// **運ぶのは作者の時計の秒と、止めているかだけ** — ``SketchPart/frameCount``・乱数の列・``SketchPart/deltaTime``
/// で積んだ状態 (``Countdown`` を含む)・作者の変数は運ばない。**渡す秒は倍精度のまま** (作者に見せる単精度の
/// ``SketchPart/time`` ではない。長く回した見張りの作り直しの後も、周期の位相 ``SketchPart/phase(period:)`` が
/// 刻みを粗くしない)。
///
/// **書き手は世代で区別する。** 新しい世代は読んだ世代 + 1 を名乗り、古い世代は書く直前にファイルの世代を見て、
/// より新しいものがあれば書かずに退く。前の世代は SIGTERM で止め終えるまで書き続けるので、これが無いと
/// 新しい世代が別の秒で止めた直後に、前の世代の時計で上書きされうる。
///
/// 場所を受けない実行 (旗の無い `watch`・`run`・`render`) は、何も読まず何も書かない。
///
/// [#2414]: https://github.com/mokume-metal/mokume/issues/2414
nonisolated final class ClockHandover {
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
        /// 作者の時計の秒 (``FrameTiming/seconds``)。止めた・飛んだぶんを含む。
        var seconds: Double
        /// 止めているか (``SketchPart/pauseTime()``)。
        var isHeld: Bool
        /// 止めていない間に、実時間 1 秒で進む作者の時計の秒。実時間の時計は 1、フレームの時計は測った値
        /// (重いフレームで 1 を下回る)。
        var rate: Double
        /// 書いた時刻 (`CACurrentMediaTime()`。端末の中のどのプロセスでも同じ時間軸)。
        var at: Double
        /// 書いたプロセスの番号。落ちて消えた世代の時間を足さないために、生きているかを見る。
        var writer: Int32
        /// 書いた世代。新しい世代の書いたファイルを、古い世代が上書きしない。
        var generation: Int

        /// 読める値か。壊れたファイルから非有限の秒を受け取ると、時計の原点が非有限になる。
        var isUsable: Bool { seconds.isFinite && at.isFinite && rate.isFinite && rate >= 0 && generation >= 0 }

        /// 新しい世代の最初の枚 (時刻 `moment`) が始める、作者の時計の秒と、止めているか。
        ///
        /// - 止めていれば、止めた秒のまま
        /// - 書き手がもう居なければ、書いた秒のまま (居ない間は進まない)。落ちた世代を、直した後に
        ///   消えていた時間ぶん先から始めない
        /// - それ以外は、書いた後に流れた時間に ``rate`` を掛けたぶん進める。**前の世代が最後の枚を描いてから
        ///   新しい世代が最初の枚を出すまで** (ビルドと起動) も、前の世代は回り続けているからである。時刻が
        ///   戻っていれば (`moment` が書いた時刻より前) 進めない
        func start(at moment: Double, writerIsAlive: Bool = true) -> (seconds: Double, isHeld: Bool) {
            if isHeld { return (seconds, true) }
            guard writerIsAlive else { return (seconds, false) }
            return (seconds + rate * max(0, moment - at), false)
        }
    }

    /// 読んだ結果。
    nonisolated enum Reading: Equatable, Sendable {
        /// ファイルが無い。最初の世代では当たり前なので、言わない。
        case absent
        /// ファイルはあるが使えない (読めない・壊れている・非有限)。理由は人に読める 1 句。
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
    /// この世代の番号。前の世代を読んだ世代 + 1 (読めなければ 1)。
    private(set) var generation = 1
    /// フレームの時計の進み方を測る窓の起点 (フレーム番号と時刻)。止めている間・種類が変わったときに捨てる。
    private var rateAnchor: (frames: Int, at: Double)?
    private var measuredRate = 1.0

    /// 外挿が合っている間も書き直す間隔 (秒)。フレームの時計は、この間隔で進み方の測り直しが届く。
    static let refreshInterval: Double = 0.5

    /// - Parameters:
    ///   - read: 前の世代が書いたものを読む。**検査から差し替える。**
    ///   - write: 書く先。**検査から差し替える。** 本番は main の外へ渡すだけで、すぐ戻る。
    ///   - isAlive: 番号のプロセスが生きているか。
    ///   - warn: 人への知らせの出口。
    ///   - writer: 自分のプロセスの番号。
    ///   - path: ファイルの場所 (知らせの文面に入れる)。
    init(
        read: @escaping () -> Reading, write: @escaping (Snapshot) -> Void,
        isAlive: @escaping (Int32) -> Bool = ClockHandover.processIsAlive,
        warn: @escaping (String) -> Void = Diagnostics.warn,
        writer: Int32 = getpid(), path: String? = nil
    ) {
        self.read = read
        self.write = write
        self.isAlive = isAlive
        self.warn = warn
        self.writer = writer
        self.path = path
    }

    /// ファイルを読み、同じファイルへ書く。書くのは main の外 (``FileSink``)。
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
    static func lockPath(for path: String) -> String { path + ".lock" }

    /// 番号のプロセスが生きているか。許されない (`EPERM`) のは居る。
    static func processIsAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    /// ファイルを読む。
    static func read(path: String) -> Reading {
        guard FileManager.default.fileExists(atPath: path) else { return .absent }
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            return .unusable(reason: Diagnostics.reason(error))
        }
        let snapshot: Snapshot
        do {
            snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
        } catch {
            return .unusable(reason: Diagnostics.reason(error))
        }
        guard snapshot.isUsable else { return .unusable(reason: "the clock in it is not a usable time") }
        return .found(snapshot)
    }

    /// 前の世代が書いたものを、いま読む。無い・使えないなら `nil` (0 秒から始める)。
    ///
    /// **使えないときは 1 度だけ、原因と次にすることを言う。** 黙って 0 秒から始めると、旗を打ったのに
    /// 時計が続かない理由が分からない。ファイルが無いのは、最初の世代では当たり前なので言わない。
    /// 呼んだ世代の番号 (``generation``) を、読んだ世代 + 1 に置く。
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
            generation = max(generation, snapshot.generation + 1)
            return Predecessor(snapshot: snapshot, writerIsAlive: isAlive(snapshot.writer))
        }
    }

    /// この枚の作者の時計を書く。**必要なときだけ書く。**
    ///
    /// - 止めているか・止めた秒が変わったとき
    /// - 止めていない間は、前に書いたものからの外挿 (``Snapshot/rate`` を掛ける) が実際の秒と
    ///   ずれたとき (飛んだ・戻した。フレームの時計は 1 フレームより大きくずれたとき)、
    ///   またはしばらく書いていないとき (``refreshInterval``)
    ///
    /// - Parameters:
    ///   - seconds: 作者の時計の秒 (観測の指定秒ではない)。
    ///   - isHeld: 止めているか。
    ///   - kind: 時計の種類。
    ///   - frames: これまでに進めたフレームの数 (フレームの時計の進み方を測る)。
    ///   - moment: この枚の時刻。
    func publish(seconds: Double, isHeld: Bool, kind: Kind, frames: Int, at moment: Double) {
        let rate = rate(of: kind, isHeld: isHeld, frames: frames, at: moment)
        let snapshot = Snapshot(
            seconds: seconds, isHeld: isHeld, rate: rate, at: moment, writer: writer,
            generation: generation)
        guard snapshot.isUsable, needsWrite(snapshot, tolerance: kind.tolerance) else { return }
        lastWritten = snapshot
        write(snapshot)
    }

    /// 止めていない間の作者の時計の進み方。実時間の時計は 1、フレームの時計は `refreshInterval` ごとに測り直す。
    /// **進んだフレームの数で測る** — 飛んだ秒は含まない。
    private func rate(of kind: Kind, isHeld: Bool, frames: Int, at moment: Double) -> Double {
        guard case .frames(let interval) = kind else {
            rateAnchor = nil
            return 1
        }
        if isHeld {
            // 止めている間は進まない。再開したときに測り直す
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
        if last.isHeld != snapshot.isHeld { return true }
        if snapshot.isHeld { return snapshot.seconds != last.seconds }
        let predicted = last.start(at: snapshot.at).seconds
        return abs(predicted - snapshot.seconds) > tolerance
            || snapshot.at - last.at >= Self.refreshInterval
    }

    /// ファイルへ書く。**main の外の直列のキューで書く** — JSON を作り、原子的に置き換える処理がフレームの
    /// 予算に乗らない。続けて頼まれたら最新のものだけを書き (``minimumGap`` より速くは書かない)、
    /// 頼みが止んでも最後の 1 つは書く。
    nonisolated final class FileSink: @unchecked Sendable {
        /// 続けて書く間隔の下限 (秒)。毎枚 `jumpTime` する作品でも、書くのは 1 秒に 20 回までになる。
        static let minimumGap: Double = 0.05

        private let path: String
        private let warn: @Sendable (String) -> Void
        private let queue = DispatchQueue(label: "mokume.keep-time", qos: .utility)
        // 以下はキューの上だけで触る
        private var pending: Snapshot?
        private var isScheduled = false
        private var lastWrite = -Double.infinity
        private var hasRetired = false
        private var writes = 0
        private var warnedWrite = false
        private var lockDescriptor: Int32?

        init(path: String, warn: @escaping @Sendable (String) -> Void) {
            self.path = path
            self.warn = warn
        }

        deinit {
            if let lockDescriptor { close(lockDescriptor) }
        }

        /// 書いてほしいものを渡す。**すぐ戻る。** 呼べるのはどのスレッドからでもよい。
        func submit(_ snapshot: Snapshot) {
            queue.async {
                self.pending = snapshot
                guard !self.isScheduled else { return }
                self.isScheduled = true
                let wait = max(0, Self.minimumGap - (ProcessInfo.processInfo.systemUptime - self.lastWrite))
                self.queue.asyncAfter(deadline: .now() + wait) {
                    self.isScheduled = false
                    guard let next = self.pending else { return }
                    self.pending = nil
                    self.lastWrite = ProcessInfo.processInfo.systemUptime
                    self.place(next)
                }
            }
        }

        /// 書いた回数 (検査用)。
        var writeCount: Int { queue.sync { writes } }

        /// 頼まれたものがすべて書かれる (あるいは捨てられる) まで待つ。**検査のためだけ。**
        func settle() {
            // 間隔の待ちを含めて、頼みが空になるまで数える
            while queue.sync(execute: { isScheduled || pending != nil }) {
                Thread.sleep(forTimeInterval: 0.01)
            }
        }

        /// 錠を取ってファイルの世代を見て、より新しい世代があれば退く。無ければ原子的に置き換える。
        private func place(_ snapshot: Snapshot) {
            guard !hasRetired else { return }
            let descriptor = lock()
            defer { if let descriptor { flock(descriptor, LOCK_UN) } }
            if case .found(let existing) = ClockHandover.read(path: path),
                existing.generation > snapshot.generation
            {
                // より新しい世代がある。以後は書かない (新しい世代の時計を上書きしない)
                hasRetired = true
                return
            }
            do {
                let data = try JSONEncoder().encode(snapshot)
                try data.write(to: URL(fileURLWithPath: path), options: .atomic)
                writes += 1
            } catch {
                guard !warnedWrite else { return }
                warnedWrite = true
                warn(
                    "--keep-time: could not write the clock to \(path): \(Diagnostics.reason(error)). "
                        + "The next rebuild will start from 0 s. Check that the temporary directory "
                        + "(TMPDIR) exists and is writable")
            }
        }

        /// 錠のファイルを開いて排他の錠を取る。開けなければ錠なしで続ける (書けない場合は、書く側が言う)。
        private func lock() -> Int32? {
            if lockDescriptor == nil {
                let descriptor = open(ClockHandover.lockPath(for: path), O_CREAT | O_RDWR, 0o600)
                if descriptor >= 0 { lockDescriptor = descriptor }
            }
            guard let descriptor = lockDescriptor, flock(descriptor, LOCK_EX) == 0 else { return nil }
            return descriptor
        }
    }
}
