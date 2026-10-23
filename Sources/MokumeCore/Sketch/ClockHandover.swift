// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

/// 作り直しをまたいで、作者の時計を新しい世代へ渡す (`mokume watch --keep-time`・[#2414])。
///
/// `watch` は `.swift` を保存するたびに、スケッチを新しいプロセスで作り直す。既定では新しい世代の
/// ``SketchPart/time`` は 0 から始まる (``SketchPart/jumpTime(_:)`` の説明)。旗 `--keep-time` を付けた
/// 見張りは、子の環境に **1 つのファイルの場所** (``StartupReads/keepTime``) を渡す。場所を受けた世代は、
///
/// - **毎枚ではなく必要なときに**、作者の時計 (止めた・飛んだぶんを含む秒と、止めているか) をそのファイルへ書く
/// - 最初の枚の前に、そのファイルを読む (前の世代が書いたもの)
///
/// 見張りは何も計算しない。**作り直しの間も前の世代は回り続ける**ので、新しい世代は最初の枚を出す時点
/// (`moment`) で「前の世代がいま描いていた秒」を求める (``Snapshot/start(at:)``)。
///
/// **運ぶのは作者の時計の秒と、止めているかだけ** — ``SketchPart/frameCount``・乱数の列・``SketchPart/deltaTime``
/// で積んだ状態 (``Countdown`` を含む)・作者の変数は運ばない。**渡す秒は倍精度のまま** (作者に見せる単精度の
/// ``SketchPart/time`` ではない。長く回した見張りの作り直しの後も、周期の位相 ``SketchPart/phase(period:)`` が
/// 刻みを粗くしない)。
///
/// 場所を受けない実行 (旗の無い `watch`・`run`・`render`) は、何も読まず何も書かない。
///
/// [#2414]: https://github.com/mokume-metal/mokume/issues/2414
nonisolated final class ClockHandover {
    /// 前の世代が書いた、作者の時計。
    nonisolated struct Snapshot: Codable, Equatable, Sendable {
        /// 作者の時計の秒 (``FrameTiming/seconds``)。止めた・飛んだぶんを含む。
        var seconds: Double
        /// 止めているか (``SketchPart/pauseTime()``)。
        var isHeld: Bool
        /// 実時間の時計か。そうなら、止めていない間は書いた後も実時間で進む。
        var isRealtime: Bool
        /// 書いた時刻 (`CACurrentMediaTime()`。端末の中のどのプロセスでも同じ時間軸)。
        var at: Double

        /// 新しい世代の最初の枚 (時刻 `moment`) が始める、作者の時計の秒と、止めているか。
        ///
        /// - 止めていれば、止めた秒のまま
        /// - 実時間の時計で止めていなければ、書いた後に流れた時間ぶん進める。**前の世代が最後の枚を描いてから
        ///   新しい世代が最初の枚を出すまで** (ビルドと起動) も、前の世代は回り続けているからである。時刻が
        ///   戻っていれば (`moment` が書いた時刻より前) 進めない
        /// - フレームの時計なら、書いた秒のまま (フレーム番号で進むので、実時間で外挿しない)
        func start(at moment: Double) -> (seconds: Double, isHeld: Bool) {
            if isHeld { return (seconds, true) }
            if isRealtime { return (seconds + max(0, moment - at), false) }
            return (seconds, false)
        }

        /// 読める値か。壊れたファイルから非有限の秒を受け取ると、時計の原点が非有限になる。
        var isUsable: Bool { seconds.isFinite && at.isFinite }
    }

    /// 前の世代が書いていたもの。無い・読めないなら `nil` (0 秒から始める)。
    let inherited: Snapshot?

    private let write: (Snapshot) -> Void
    private var lastWritten: Snapshot?

    /// 実時間の時計で、外挿が合っている間も書き直す間隔 (秒)。外挿は正確なので、変わらない間は稀でよい。
    static let refreshInterval: Double = 0.5
    /// 外挿が実際の秒とこれ以上ずれたら、書き直す (秒)。飛んだ・戻したときに当たる。
    static let driftTolerance: Double = 0.001

    /// - Parameters:
    ///   - inherited: 前の世代が書いたもの。
    ///   - write: 書く先。**検査から差し替える。**
    init(inherited: Snapshot?, write: @escaping (Snapshot) -> Void) {
        self.inherited = inherited
        self.write = write
    }

    /// ファイルを読み、同じファイルへ書く。
    convenience init(path: String) {
        let inherited = Self.read(path: path)
        self.init(inherited: inherited) { snapshot in
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            // 原子的に置き換える。新しい世代が読む瞬間に、書きかけを見せない
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }

    /// 起動の環境から作る。**無ければ `nil`。** 読んだら環境から消す (``ShaderOrigin/startup()`` と同じ) —
    /// 合図はこのプロセスを起こした見張りが渡したもので、このプロセスがさらに起こす子のものではない。
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

    /// ファイルを読む。無い・壊れている・非有限なら `nil`。
    static func read(path: String) -> Snapshot? {
        guard let data = FileManager.default.contents(atPath: path),
            let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
            snapshot.isUsable
        else { return nil }
        return snapshot
    }

    /// この枚の作者の時計を書く。**必要なときだけ書く。**
    ///
    /// - フレームの時計: 秒が動いたとき (毎枚)
    /// - 止めている: 止めた秒が変わったとき
    /// - 実時間で止めていない: 前に書いたものからの外挿が実際の秒とずれたとき (飛んだ・止めた・戻した)、
    ///   またはしばらく書いていないとき
    /// - どの時計でも、止めているか・時計の種類が変わったとき
    func publish(_ snapshot: Snapshot) {
        guard snapshot.isUsable, needsWrite(snapshot) else { return }
        lastWritten = snapshot
        write(snapshot)
    }

    private func needsWrite(_ snapshot: Snapshot) -> Bool {
        guard let last = lastWritten else { return true }
        if last.isHeld != snapshot.isHeld || last.isRealtime != snapshot.isRealtime { return true }
        if snapshot.isHeld { return snapshot.seconds != last.seconds }
        guard snapshot.isRealtime else { return snapshot.seconds != last.seconds }
        let predicted = last.start(at: snapshot.at).seconds
        return abs(predicted - snapshot.seconds) > Self.driftTolerance
            || snapshot.at - last.at >= Self.refreshInterval
    }
}
