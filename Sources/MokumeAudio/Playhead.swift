// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// 再生位置の移り変わり。**機材にも時計にも触れない純粋な型**で、検査が直に回す。
///
/// 位置は「区切り」で持つ。区切りは鳴らし始めた位置 (``start``) から始まり、そこから鳴った
/// 標本の数 (`played`) は呼ぶ側が測って渡す — 実際に鳴らしているなら player が描いた数、
/// 書き出しならフレームの数から決めた数である。どちらで測っても、同じ `played` からは
/// 同じ位置と同じ区間 (``span(of:from:after:)``) が出る。だから書き出しの解析は、実時間の再生と同じ位置の区間から取られる。
///
/// 鳴らし始めるたびに区切りを始め直し、止めるときは区切りを締めて位置を ``start`` に残す。
nonisolated struct Playhead: Equatable {
    /// 標本の数。1 以上。
    let length: Int
    /// いまの区切りが始まった位置 (標本)。止まっている間は、次に鳴らし始める位置。
    private(set) var start = 0
    /// 鳴っているか。
    private(set) var isPlaying = false
    /// 終わりから頭へ戻り続けるか。
    private(set) var isLooping = false
    /// いまの区切りを、鳴っている間に飛んで始めたか (``jump(to:)``)。そうなら窓の区切りより前を
    /// ファイルの標本で埋める — 飛ぶ前からその位置まで鳴っていたのと同じ窓にする。
    private(set) var leapt = false
    /// ``leapt`` のとき、始まりより前をファイルの標本で埋める、いちばん小さい番号。飛んで始めた区切りは 0
    /// (ファイルの頭より前は 0)。**鳴らしたまま始め直した区切り (``carry(after:)``) は、元の区切りの始まりの番号**
    /// — 元の区切りが 0 で埋めていた、始まりより前は、そのまま 0 にする。
    private(set) var filledFrom = 0
    /// 区間の番号に足す数 (標本)。ループで頭へ戻った周回ぶん (``length`` の倍数)。
    ///
    /// 番号は ``start`` + 鳴った標本の数 (区切りの始まりからの通し番号) だが、鳴らしたまま位置の側で区切りを
    /// 始め直す (``carry(after:)``) と、``start`` は位置 (``length`` 未満) に戻る。**番号まで戻すと、窓の格子
    /// (``AudioAnalysis/hop`` ごと) が (周回数 × ``length``) を ``AudioAnalysis/hop`` で割った余りだけずれて**、
    /// 同じ標本に別の値が出る (#3268)。そこで周回ぶんをここに持ち、番号は続ける。区切りを始め直す操作
    /// (``play(looping:)``・``jump(to:)``・``pause(after:)``・``stop()``) は番号も数え直すので、0 に戻す。
    private(set) var shift = 0

    init(length: Int) {
        self.length = max(1, length)
    }

    /// 区切りの中で `played` 標本鳴ったときの位置。止まっていれば ``start``。
    /// 1 度だけ鳴らしているなら ``length`` で止まる。
    func position(after played: Int) -> Int {
        guard isPlaying else { return start }
        let reached = start + max(0, played)
        return isLooping ? reached % length : min(reached, length)
    }

    /// 1 度だけ鳴らしていて、`played` 標本で終わりまで鳴り切ったか。
    func hasEnded(after played: Int) -> Bool {
        isPlaying && !isLooping && start + max(0, played) >= length
    }

    /// 鳴らし始める。**鳴っている最中なら頭から鳴らし直す。** 止めていれば止めた位置から、
    /// 頭へ戻してあれば頭から。**止めた位置が終わり (``jump(to:)`` で寄せたもの) なら、鳴り終わった後と同じに
    /// 頭から** (#3303)。呼んだ側は区切りを始め直す。
    mutating func play(looping: Bool) {
        if isPlaying || start >= length { start = 0 }
        isPlaying = true
        isLooping = looping
        leapt = false
        filledFrom = 0
        shift = 0
    }

    /// 位置を `sample` へ移す。0 より前は頭、``length`` より後は終わりへ寄せる。
    ///
    /// 鳴っていれば、呼んだ側がそこから区切りを始め直す。その区切りの窓は、始まりより前を 0 でなく
    /// ファイルの標本で埋める (``leapt``)。止まっていれば位置だけが動き、次に鳴らし始める位置になる。
    mutating func jump(to sample: Int) {
        start = min(max(sample, 0), length)
        leapt = isPlaying
        filledFrom = 0
        shift = 0
    }

    /// 鳴らしたまま、いまの位置 (`played` 標本鳴ったところ) から区切りを始め直す。**区間の番号は続ける** (``shift``)。
    ///
    /// 始め直す前の区切りの鳴った分は、ファイルの標本で埋める (``leapt``) — 同じ音が続いていたのと同じ窓にする。
    /// **元の区切りの始まりより前は、元の区切りと同じに埋める** (``filledFrom``): 元が飛んで始めた区切りならファイルの標本、
    /// 止めた後に途中から鳴らし直した区切りなら 0。通さない回と同じ値になる。
    /// 違いは番号で、飛ぶと番号を数え直すが、こちらは同じ音が続くので、番号を変えない — 解析の窓の格子が動かず、
    /// 取り方 (エフェクトへ通すか・録りの音声トラックへ載せるか) に依らず、同じ標本には同じ値が出る。止まっていれば何もしない。
    mutating func carry(after played: Int) {
        guard isPlaying else { return }
        let number = self.number(after: played)
        let place = position(after: played)
        if !leapt { filledFrom = shift + start }
        start = place
        leapt = true
        shift = isLooping ? number - place : 0
    }

    /// 区切りの中で `played` 標本鳴ったときの、区間の番号 (``span(of:from:after:)`` の終わり)。
    /// 1 度だけなら ``length`` で止まる。
    func number(after played: Int) -> Int {
        let reached = shift + start + max(0, played)
        return isLooping ? reached : min(reached, length)
    }

    /// 止めて、いまの位置を覚える。鳴り終わっていれば頭へ戻す。
    mutating func pause(after played: Int) {
        guard isPlaying else { return }
        start = hasEnded(after: played) ? 0 : position(after: played)
        isPlaying = false
        leapt = false
        filledFrom = 0
        shift = 0
    }

    /// 止めて頭へ戻す。
    mutating func stop() {
        start = 0
        isPlaying = false
        leapt = false
        filledFrom = 0
        shift = 0
    }

    /// 鳴り終わっていれば止めて頭へ戻す。止めたなら `true`。
    mutating func settle(after played: Int) -> Bool {
        guard hasEnded(after: played) else { return false }
        stop()
        return true
    }

    /// 区切りの中で `played` 標本鳴ったところまでの、解析する区間。`covered` は前のフレームの区間の終わり。
    ///
    /// **番号は ``shift`` + ``start`` + 鳴った標本の数** (ファイルの位置。ループで頭へ戻っても戻さない通し番号) で、
    /// 窓の格子 (``AudioAnalysis/hop`` ごと) もこの番号に置く。標本は ``sample(at:in:)`` の決まりで
    /// 読む (始まりより前は 0、飛んで始めた区切りはファイルの標本)。止まっていれば呼ばない。
    func span(of samples: [Float], from covered: Int, after played: Int) -> AudioSpan {
        // 1 度だけなら、ファイルの終わりより先は無い (終わりまでを区間にする)
        let to = number(after: played)
        let from = AudioAnalysis.limited(from: min(max(covered, 0), to), to: to)
        let first = AudioAnalysis.firstNeeded(from: from)
        return AudioSpan(
            base: first, samples: (first..<to).map { sample(at: $0, in: samples) }, from: from)
    }

    /// 区切りの通し番号 `index` (``start`` + 鳴った標本の数) の標本。**区間 (``span(of:from:after:)``) の標本の決まりの正本。**
    ///
    /// - 区切りの始まりより前は 0 (まだ鳴らしていない)。ただし鳴っている間に飛んで始めた区切り (``leapt``) は、
    ///   ファイルの標本で埋める (ファイルの頭より前は 0。``carry(after:)`` した区切りは ``filledFrom`` より前も 0)
    /// - 1 度だけなら、終わりより後は 0。ループなら頭へ戻って続ける
    ///
    /// 検査が、区切りの中の標本の並びを直に読むのにも使う。
    func sample(at index: Int, in samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        guard index - shift >= start else {
            // 始まりより前。ループなら、周回ぶん戻った番号もファイルの標本 (``carry(after:)`` の後は、前の周の音)
            guard leapt, filledFrom <= index else { return 0 }
            if isLooping { return samples[index % samples.count] }
            return index < samples.count ? samples[index] : 0
        }
        if isLooping { return samples[index % samples.count] }
        return index < samples.count ? samples[index] : 0
    }
}
