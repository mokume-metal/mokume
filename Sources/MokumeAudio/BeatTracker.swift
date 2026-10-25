// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// 拍の検出。**標本を 1 つずつ順に足すだけの状態**で、機材にも時計にも触れない ([ADR-0042] 決定 6 の改訂)。
///
/// 入力の分け方 (fps・届くチャンクの長さ) が違っても、同じ標本列からは同じ標本位置で拍を判定する。状態は
/// 標本を ``AudioAnalysis/hop`` ごとに区切った**固定のブロック**の列でだけ進み、届いた単位ごとに 1 回判定する
/// 作りは採らない。足し算の順も標本の順に決まっているので、区切り方でビットがずれない。**読まれるかどうかにも
/// 依らない** — 持ち主は音源が鳴り始めたとき (最初の区間) に状態を作り、以後は区間を置くたびに必ず進める
/// (``SoundTrace``)。
///
/// ## 判定
///
/// ブロックごとの平均二乗 (エネルギー) が、直近の ``historyBlocks`` ブロック (48 kHz で約 1 秒) の平均の
/// ``ratio`` 倍を越え、かつ ``floorEnergy`` (−60 dBFS の RMS) を越えたら拍とする。数でない標本・無限の標本は
/// 0 として数える (履歴に残さない — ``AudioAnalysis/energy(of:from:to:sampleRate:)`` と同じ)。
///
/// - 拍の直後の ``refractoryBlocks`` ブロック (約 64 ms) は数えない。1 つの立ち上がりが 2 つのブロックに
///   またがっても 1 回になる
/// - **途中から始めた (または捨てて始め直した) ときは、最初の ``warmupBlocks`` ブロックは出さない。** 履歴が
///   溜まる前の平均は当てにならず、曲の途中で読み始めた最初のブロックが拍になってしまう。標本の流れの
///   **最初から**始めたとき (``init(fresh:)``・``reset(fresh:)``。無音から鳴り始める音・ファイルの頭から鳴らす音) は、
///   履歴が無いのは本当に何も鳴っていなかったからなので、最初の立ち上がりも拍になる。始まりの前の
///   ブロックは 0 として数え、履歴には入れない (全く鳴っていない間は何ブロック続いても同じ状態)
/// - 拍の位置は、それを見つけたブロックの先頭の通し番号。立ち上がりはそのブロックか、1 つ前のブロックの
///   終わりの数標本にあるので (後者は前のブロックのエネルギーが小さすぎて見つからない)、立ち上がりから
///   hop 1 つ (512 標本) 以内である
/// - **流れが切れたかは、区間の始まりが前の区間の終わりに続いているか (番号の連続) だけで決める。** 続かない
///   (標本を落とした・飛んだ・頭から鳴らし直した) ときは履歴を捨てて、次の格子の境目から始め直す (途中からの
///   始め直し。始まりが標本 0 ならその最初から)。落とした区間では拍を出さない。**番号を付け直しても流れが続く
///   ときは ``rebase(to:)`` で続きの番号を教える**
/// - 流れが終わったとき (``finish()``) は、閉じていない端数のブロックを、あとが無音として閉じる
///
/// 手本は Minim の `BeatDetect` の「音のエネルギーを直近の平均と比べる」形。p5.sound の `PeakDetect`・
/// Processing Sound の `BeatDetector` と同じく、感度の口は持たない (作例が要るまで作らない)。
///
/// [ADR-0042]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0042-camera-and-audio-standard.md
nonisolated struct BeatTracker {
    /// ブロックの長さ (標本)。窓の格子の hop と同じ。
    static let block = AudioAnalysis.hop
    /// 平均を取る直近のブロックの数。
    static let historyBlocks = 94
    /// 直近の平均の何倍を越えたら拍か。
    static let ratio: Float = 1.5
    /// 拍にする最小のエネルギー (平均二乗)。−60 dBFS の RMS。
    static let floorEnergy: Float = 1e-6
    /// 拍の後に数えないブロックの数。
    static let refractoryBlocks = 6
    /// 途中から始めたときに、出さないブロックの数。
    static let warmupBlocks = 8
    /// 見つけた拍の位置を覚えておく数の上限 (古いものから忘れる)。時刻を指定した観測の枚が読む。
    static let rememberedBeats = 1024

    /// 次に足す標本の通し番号。まだ何も足していなければ `nil`。
    private var next: Int?
    /// 始まりの前が無音か (流れの最初から始めるか)。最初に足す区間で、格子の境目までを 0 として数えるのに使う。
    private var startsSilent: Bool
    /// 流れが終わって (``finish()``)、次の区間が履歴を捨てて始め直すか。
    private var isEnded = false
    /// 読み飛ばす標本の数 (途中から始めたとき、次の格子の境目まで)。
    private var skipping = 0
    /// いまのブロックの二乗和と、足した標本の数。
    private var sum: Float = 0
    private var filled = 0
    /// 終えたブロックのエネルギー (環)。
    private var history: [Float] = []
    private var cursor = 0
    /// 出さないブロックの残り (途中から始めたとき ``warmupBlocks``)。
    private var warmupLeft = 0
    /// 拍の後に残る、数えないブロックの数。
    private var quiet = 0

    /// - Parameter fresh: 標本の流れの最初から始めるか (``reset(fresh:)``)。
    init(fresh: Bool = true) {
        startsSilent = fresh
        warmupLeft = fresh ? 0 : Self.warmupBlocks
    }

    /// 区間を処理した回数。検査が読む。
    private(set) var calls = 0
    /// 直近の ``process(_:)``・``finish()`` で見つけた拍の位置 (ブロックの先頭の通し番号)。検査が読む。
    private(set) var beats: [Int] = []
    /// これまでに見つけた拍の位置 (ブロックの先頭の通し番号。直近 ``rememberedBeats`` まで)。
    /// 履歴を捨てても消さない — 同じ標本列は同じ番号を読み直すので、位置の意味は変わらない。
    private(set) var found: [Int] = []

    /// 履歴を捨てる。
    ///
    /// - Parameter fresh: 次に足す標本が標本の流れの最初か (無音から鳴り始める・ファイルの頭から鳴らす)。
    ///   そうなら最初の立ち上がりも拍にする。途中 (曲の途中への飛び先・止めた位置からの再開) なら
    ///   ``warmupBlocks`` ブロックは出さない。
    mutating func reset(fresh: Bool) {
        next = nil
        isEnded = false
        startsSilent = fresh
        skipping = 0
        sum = 0
        filled = 0
        history.removeAll(keepingCapacity: true)
        cursor = 0
        warmupLeft = fresh ? 0 : Self.warmupBlocks
        quiet = 0
    }

    /// 流れの番号の付け方が変わった (標本の流れは続く)。次の区間は `position` から始まると教える。
    ///
    /// 履歴は捨てない。ブロックは標本の数で区切っているので、番号が変わっても境目は動かず、拍の位置が新しい
    /// 番号で出るだけである。まだ何も足していなければ何もしない。
    mutating func rebase(to position: Int) {
        guard next != nil else { return }
        next = position
    }

    /// 区間の標本を、標本の順に足す。区間に拍があれば `true`。
    ///
    /// 前の区間の終わりから続いていなければ、履歴を捨てて始め直す (``AudioSpan/from`` は上限で切られている)。
    mutating func process(_ span: AudioSpan) -> Bool {
        calls += 1
        beats.removeAll(keepingCapacity: true)
        var position = span.from
        if let expected = next, expected != position || isEnded {
            // 続かない = 標本を落とした・飛んだ・鳴らし直した。始まりが標本 0 なら流れの最初
            reset(fresh: position == 0)
        }
        if next == nil { begin(at: position) }
        let end = span.to
        let base = span.base
        span.samples.withUnsafeBufferPointer { samples in
            while position < end {
                if skipping > 0 {
                    let count = min(skipping, end - position)
                    position += count
                    skipping -= count
                    continue
                }
                // ブロックの終わりか区間の終わりまでを、標本の順に足す
                let run = min(end - position, Self.block - filled)
                var total = sum
                for index in (position - base)..<(position - base + run) {
                    let value = samples[index]
                    // 数でない標本・無限の標本は 0 として数える
                    if value.isFinite { total += value * value }
                }
                sum = total
                filled += run
                position += run
                if filled == Self.block { closeBlock(endingAt: position) }
            }
        }
        next = max(end, span.from)
        return !beats.isEmpty
    }

    /// 流れが終わった (一発音の終わり・ループしないファイルの終わり)。閉じていない端数のブロックを、あとが無音と
    /// して閉じる。端数にだけある立ち上がりも拍になりうる。拍があれば `true`。
    ///
    /// 終わった後の最初の区間は、続いていても履歴を捨てて始め直す。
    mutating func finish() -> Bool {
        beats.removeAll(keepingCapacity: true)
        guard let next, skipping == 0, filled > 0 else {
            isEnded = true
            return false
        }
        let start = next - filled
        // 残りの標本は 0 なので、二乗和はそのまま
        closeBlock(endingAt: start + Self.block)
        isEnded = true
        return !beats.isEmpty
    }

    /// 最初の区間の始まり `position` に合わせて、ブロックの格子に乗せる。
    private mutating func begin(at position: Int) {
        let offset = position % Self.block
        if startsSilent {
            // 始まりの前は無音: 格子の境目から始まりまでを 0 の標本として数える
            filled = offset
        } else {
            skipping = (Self.block - offset) % Self.block
        }
    }

    private mutating func closeBlock(endingAt position: Int) {
        let energy = sum / Float(Self.block)
        sum = 0
        filled = 0
        var total: Float = 0
        for value in history { total += value }
        let mean = history.isEmpty ? 0 : total / Float(history.count)
        if warmupLeft > 0 {
            warmupLeft -= 1
        } else if quiet > 0 {
            quiet -= 1
        } else if energy > Self.floorEnergy, energy > Self.ratio * mean {
            let start = position - Self.block
            beats.append(start)
            found.append(start)
            if found.count > 2 * Self.rememberedBeats { found.removeFirst(found.count - Self.rememberedBeats) }
            quiet = Self.refractoryBlocks
        }
        if history.count < Self.historyBlocks {
            // 始まりの前の全くの無音は、何ブロック続いても履歴に入れない (いつ状態を作っても同じになる)
            if !(history.isEmpty && energy == 0) { history.append(energy) }
        } else {
            history[cursor] = energy
            cursor = (cursor + 1) % Self.historyBlocks
        }
    }

    /// 区間 `(from, to]` に終わりが入るブロックで見つけた拍が、覚えている中にあるか。
    ///
    /// 通常の枚が同じ区間に対して返す答えと同じ決まり (ブロックの終わりが区間に入る)。時刻を指定した観測の枚が、
    /// 続きを歪めずに「その区間に拍があったか」を読むのに使う。まだ処理していない先の区間は、拍を知らない。
    func hasBeat(from: Int, to: Int) -> Bool {
        found.contains { $0 + Self.block > from && $0 + Self.block <= to }
    }
}
