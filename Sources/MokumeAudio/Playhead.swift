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
///
/// ## 速さ (#3473)
///
/// `played` は区切りの頭から**経った**標本の数で、速さが 1 なら鳴ったファイルの標本の数と同じ。速さを変えると、
/// 区切りの中に錨 (``RateAnchor``) を足し、位置はそこから ``FileRate/position(from:elapsed:rate:)`` で導く — 音の側
/// (``FileVoice``・``FileNode``) と同じ式で、同じ位置になる。
///
/// - 包絡の位置 (``heard(after:)``) は経った数で数える (#3473 の 2026-11-14 の決定 1)
/// - 区間の番号 (``number(after:)``) は、区切りの始まりの位置 + **鳴った**標本の数で数える (決定 2)。速さ 0 の間は
///   鳴らないので進まない (決定 3)。速さ 1 では位置と同じ番号
/// - 区間の標本 (``sample(at:in:)``) は、その番号の標本が鳴ったときに読んでいた位置を、音の側と同じ読み方で読む (決定 4)
///
/// **速さを 1 度も変えていない区切り (``isPlain``) は、速さを入れる前と同じ式を通る。**
nonisolated struct Playhead: Equatable {
    /// 標本の数。1 以上。
    let length: Int
    /// いまの区切りが始まった位置 (標本)。止まっている間は、次に鳴らし始める位置。
    private(set) var start = 0
    /// 鳴っているか。
    private(set) var isPlaying = false
    /// 終わりから頭へ戻り続けるか。
    private(set) var isLooping = false
    /// いまの区切りを、鳴っている間に飛んで始めたか (``jump(to:)``)。そうならウィンドウの区切りより前を
    /// ファイルの標本で埋める — 飛ぶ前からその位置まで鳴っていたのと同じウィンドウにする。
    private(set) var leapt = false
    /// ``leapt`` のとき、始まりより前をファイルの標本で埋める、いちばん小さい番号。飛んで始めた区切りは 0
    /// (ファイルの頭より前は 0)。**鳴らしたまま始め直した区切り (``carry(after:)``) は、元の区切りの始まりの番号**
    /// — 元の区切りが 0 で埋めていた、始まりより前は、そのまま 0 にする。
    private(set) var filledFrom = 0
    /// 区間の番号に足す数 (標本)。ループで頭へ戻った周回ぶん (``length`` の倍数)。
    ///
    /// 番号は ``start`` + 鳴った標本の数 (区切りの始まりからの通し番号) だが、鳴らしたまま位置の側で区切りを
    /// 始め直す (``carry(after:)``) と、``start`` は位置 (``length`` 未満) に戻る。**番号まで戻すと、ウィンドウの格子
    /// (``AudioAnalysis/hop`` ごと) が (周回数 × ``length``) を ``AudioAnalysis/hop`` で割った余りだけずれて**、
    /// 同じ標本に別の値が出る (#3268)。そこで周回ぶんをここに持ち、番号は続ける。区切りを始め直す操作
    /// (``play(looping:)``・``jump(to:)``・``pause(after:)``・``stop()``) は番号も数え直すので、0 に戻す。
    private(set) var shift = 0
    /// いまの速さ (次に始める区切りの頭の速さ)。
    private(set) var rate: Double = 1
    /// いまの速さで解析を読む低域通過の係数 (速さが 1 を越えるとき)。
    private var rateKernel: RateKernel?
    /// いまの区切りの錨 (経った数の順。先頭は区切りの頭)。
    private(set) var anchors = [RateAnchor(elapsed: 0, sounded: 0, position: 0, rate: 1, kernel: nil)]
    /// 鳴らしたまま始め直した (``carry(after:)``) 前の区切りが速さを変えていたときの、その錨と番号の頭。始まりより前の
    /// 番号の標本を、前の区切りで鳴った位置から読む。
    private var carried: Carried?

    /// 鳴らしたまま始め直す前の区切り。
    private struct Carried: Equatable {
        /// 前の区切りの、鳴った数 0 の番号。
        var base: Int
        var anchors: [RateAnchor]
        var looping: Bool
    }

    init(length: Int) {
        self.length = max(1, length)
    }

    /// 速さを 1 度も変えていない区切りか。そうなら、速さを入れる前と同じ式で位置・番号・標本を求める。
    var isPlain: Bool {
        anchors.count == 1 && anchors[0].rate == 1 && anchors[0].elapsed == 0
            && anchors[0].position == Double(start) && (isLooping || shift == 0)
    }

    /// いまの区切りの頭の錨 (区切りの頭から見た経った数と、そこで読んでいた位置)。鳴らす側へ渡す。ふつうは始まりの
    /// 標本と 0 で、速さを変えて鳴っている区切りを ``carry(after:keepingAnchor:)`` で始め直したときだけ違う。
    var origin: (position: Double, elapsed: Int) {
        let anchor = anchors[Self.anchorIndex(in: anchors, elapsed: 0)]
        return (anchor.position, anchor.elapsed)
    }

    /// 区切りの錨を、始まりの位置からいまの速さで始め直す。
    private mutating func restartAnchors() {
        anchors = [
            RateAnchor(elapsed: 0, sounded: 0, position: Double(start), rate: rate, kernel: rateKernel)
        ]
    }

    /// 速さを `rate` にする。鳴っていれば、区切りの頭から `elapsed` 標本経った点に錨を置き、そこから新しい速さで進む
    /// (位置は跳ばない)。止まっていれば、次に鳴らし始める区切りの頭から。
    ///
    /// - Parameters:
    ///   - kernel: 解析を読む低域通過の係数 (速さが 1 を越えるとき)。
    ///   - position: 錨の位置。音の側が返した位置 (``RateLink/Anchor``) を渡す。`nil` なら同じ式で導く。
    mutating func setRate(
        _ rate: Double, kernel: RateKernel?, at elapsed: Int, position: Double? = nil
    ) {
        self.rate = rate
        rateKernel = kernel
        guard isPlaying else {
            restartAnchors()
            return
        }
        let last = anchors[anchors.count - 1]
        let at = max(elapsed, last.elapsed)
        let anchor = RateAnchor(
            elapsed: at, sounded: sounded(at: at), position: position ?? place(at: at), rate: rate,
            kernel: kernel)
        if at == last.elapsed {
            anchors[anchors.count - 1] = anchor
        } else {
            anchors.append(anchor)
        }
    }

    /// いまの区切りを始める前に、音の側が速さ `rate` を受けていた (``RateLink``)。区切りの頭からその速さにする。
    mutating func retime(_ rate: Double, kernel: RateKernel?) {
        // 前の区切りから持ち越した錨 (``carry(after:keepingAnchor:)``) は書き換えず、頭に錨を足す
        guard anchors[0].elapsed == 0 else {
            setRate(rate, kernel: kernel, at: 0)
            return
        }
        self.rate = rate
        rateKernel = kernel
        anchors[0].rate = rate
        anchors[0].kernel = kernel
        // 頭の後に錨があれば、頭からの速さで導き直す
        for index in anchors.indices.dropFirst() {
            let previous = anchors[index - 1]
            let span = anchors[index].elapsed - previous.elapsed
            anchors[index].position = FileRate.position(
                from: previous.position, elapsed: span, rate: previous.rate)
            anchors[index].sounded = previous.sounded + (previous.rate > 0 ? span : 0)
        }
    }

    /// 番号 `number` より前の標本を読むのにしか要らない錨を捨てる (その番号より前は、もう解析しない)。
    mutating func forget(before number: Int) {
        let sounded = number - shift - start
        if sounded > 0 { carried = nil }
        guard anchors.count > 1, sounded > 0 else { return }
        let keep = Self.anchorIndex(in: anchors, sounded: sounded)
        if keep > 0 { anchors.removeFirst(keep) }
    }

    /// 区切りの頭から `elapsed` 標本経ったところで読む位置 (折り返さない)。
    private func place(at elapsed: Int) -> Double {
        let anchor = anchors[Self.anchorIndex(in: anchors, elapsed: elapsed)]
        return FileRate.position(from: anchor.position, elapsed: elapsed - anchor.elapsed, rate: anchor.rate)
    }

    /// 区切りの頭から `elapsed` 標本経ったところまでに鳴った数 (速さ 0 の間を除く)。
    private func sounded(at elapsed: Int) -> Int {
        let anchor = anchors[Self.anchorIndex(in: anchors, elapsed: elapsed)]
        return anchor.sounded + (anchor.rate > 0 ? max(0, elapsed - anchor.elapsed) : 0)
    }

    /// 1 度だけ鳴らす区切りが終わりに着く、経った数。着かない (ループ・速さ 0 のまま) なら `nil`。
    private var endElapsed: Int? {
        guard !isLooping else { return nil }
        let end = Double(length)
        for (index, anchor) in anchors.enumerated() {
            if anchor.position >= end { return anchor.elapsed }
            guard anchor.rate > 0 else { continue }
            let limit = index + 1 < anchors.count ? anchors[index + 1].elapsed : Int.max
            let guess = ((end - anchor.position) / anchor.rate).rounded(.up)
            // 遅すぎて着くまでの数が数えられないなら、着かない
            guard guess < Double(1 << 50) else { continue }
            var count = max(0, Int(guess))
            while count > 0,
                FileRate.position(from: anchor.position, elapsed: count - 1, rate: anchor.rate) >= end
            {
                count -= 1
            }
            while FileRate.position(from: anchor.position, elapsed: count, rate: anchor.rate) < end {
                count += 1
            }
            if count < limit - anchor.elapsed { return anchor.elapsed + count }
        }
        return nil
    }

    /// `anchors` のうち、経った数 `elapsed` を含む錨 (経った数がそれ以下の最後の錨) の番号。
    private static func anchorIndex(in anchors: [RateAnchor], elapsed: Int) -> Int {
        var low = 0
        var high = anchors.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if anchors[middle].elapsed <= elapsed { low = middle } else { high = middle - 1 }
        }
        return low
    }

    /// `anchors` のうち、鳴った数 `sounded` の標本を鳴らした錨 (鳴った数がそれ以下の最後の錨) の番号。速さ 0 の錨は
    /// 鳴らさないので、同じ鳴った数の次の錨が選ばれる。
    private static func anchorIndex(in anchors: [RateAnchor], sounded: Int) -> Int {
        var low = 0
        var high = anchors.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if anchors[middle].sounded <= sounded { low = middle } else { high = middle - 1 }
        }
        return low
    }

    /// 番号 `number` の標本が鳴った、区切りの頭から経った数 (包絡の位置)。区切りの始まりより前は、始まりからの負の数。
    func elapsed(atNumber number: Int) -> Int {
        let sounded = number - shift - start
        guard sounded > 0, !isPlain else { return sounded }
        let anchor = anchors[Self.anchorIndex(in: anchors, sounded: sounded)]
        return anchor.elapsed + (sounded - anchor.sounded)
    }

    /// 区切りの中で `played` 標本鳴ったときの位置。止まっていれば ``start``。
    /// 1 度だけ鳴らしているなら ``length`` で止まる。
    func position(after played: Int) -> Int {
        guard isPlaying else { return start }
        guard isPlain else {
            let place = self.place(at: max(0, played))
            let end = Double(length)
            if isLooping { return Int(place.truncatingRemainder(dividingBy: end).rounded(.down)) }
            return place >= end ? length : Int(place.rounded(.down))
        }
        let reached = start + max(0, played)
        return isLooping ? reached % length : min(reached, length)
    }

    /// 区切りの中で `played` 標本鳴ったうち、実際にファイルの標本を鳴らした数。1 度だけなら終わりまでの数で止まる。
    /// 止まっていれば 0。包絡 (``FileEnvelope``) が進む数。
    func heard(after played: Int) -> Int {
        guard isPlaying else { return 0 }
        let reached = max(0, played)
        guard isPlain else {
            guard !isLooping, let end = endElapsed else { return reached }
            return min(reached, end)
        }
        return isLooping ? reached : min(reached, max(0, length - start))
    }

    /// 1 度だけ鳴らしていて、`played` 標本で終わりまで鳴り切ったか。
    func hasEnded(after played: Int) -> Bool {
        guard isPlain else {
            return isPlaying && !isLooping && place(at: max(0, played)) >= Double(length)
        }
        return isPlaying && !isLooping && start + max(0, played) >= length
    }

    /// 1 度だけ鳴らす区切りが終わりに着く、経った数 (`played` の数え方)。ループか、着かなければ `nil`。
    var endingElapsed: Int? {
        guard isPlaying, !isLooping else { return nil }
        guard isPlain else { return endElapsed }
        return max(0, length - start)
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
        carried = nil
        restartAnchors()
    }

    /// 位置を `sample` へ移す。0 より前は頭、``length`` より後は終わりへ寄せる。
    ///
    /// 鳴っていれば、呼んだ側がそこから区切りを始め直す。その区切りのウィンドウは、始まりより前を 0 でなく
    /// ファイルの標本で埋める (``leapt``)。止まっていれば位置だけが動き、次に鳴らし始める位置になる。
    mutating func jump(to sample: Int) {
        start = min(max(sample, 0), length)
        leapt = isPlaying
        filledFrom = 0
        shift = 0
        carried = nil
        restartAnchors()
    }

    /// 鳴らしたまま、いまの位置 (`played` 標本鳴ったところ) から区切りを始め直す。**区間の番号は続ける** (``shift``)。
    ///
    /// 始め直す前の区切りの鳴った分は、ファイルの標本で埋める (``leapt``) — 同じ音が続いていたのと同じウィンドウにする。
    /// **元の区切りの始まりより前は、元の区切りと同じに埋める** (``filledFrom``): 元が飛んで始めた区切りならファイルの標本、
    /// 止めた後に途中から鳴らし直した区切りなら 0。通さない回と同じ値になる。
    /// 違いは番号で、飛ぶと番号を数え直すが、こちらは同じ音が続くので、番号を変えない — 解析のウィンドウの格子が動かず、
    /// 取り方 (エフェクトへ通すか・録りの音声トラックへ載せるか) に依らず、同じ標本には同じ値が出る。止まっていれば何もしない。
    ///
    /// 速さを変えていた区切りは、始め直す前の錨を持ち越し (始まりより前の番号の標本をそこから読む)、新しい区切りの頭の
    /// 錨 (``origin``) を、読む位置の小数まで続くように置く。`keepingAnchor` なら、いまの錨をそのまま新しい区切りの
    /// 数え方へ移す — 鳴らす側が同じ錨から同じ式で導くので、始め直さなかったときと 1 標本も違わない (``FileVoice``)。
    /// そうでなければ、いまの位置 (小数) を新しい錨にする (``FileNode``。丸めの差だけ、始め直さなかったときとずれうる)。
    mutating func carry(after played: Int, keepingAnchor: Bool = true) {
        guard isPlaying else { return }
        let number = self.number(after: played)
        let place = position(after: played)
        let plain = isPlain
        let reached = max(0, played)
        let current = anchors[Self.anchorIndex(in: anchors, elapsed: reached)]
        let sounded = self.sounded(at: reached)
        let exact = self.place(at: reached)
        if !leapt { filledFrom = shift + start }
        carried = plain ? nil : Carried(base: shift + start, anchors: anchors, looping: isLooping)
        start = place
        leapt = true
        // 速さを変えていれば、1 度だけでも番号は位置と揃わないので、番号を続ける
        shift = isLooping || !plain ? number - place : 0
        restartAnchors()
        guard !plain else { return }
        anchors[0] =
            keepingAnchor
            ? RateAnchor(
                elapsed: current.elapsed - reached, sounded: current.sounded - sounded,
                position: current.position, rate: current.rate, kernel: current.kernel)
            : RateAnchor(elapsed: 0, sounded: 0, position: exact, rate: current.rate, kernel: current.kernel)
    }

    /// 区切りの中で `played` 標本鳴ったときの、区間の番号 (``span(of:from:after:)`` の終わり)。
    /// 1 度だけなら ``length`` で止まる。
    func number(after played: Int) -> Int {
        guard isPlain else {
            var reached = max(0, played)
            if !isLooping, let end = endElapsed { reached = min(reached, end) }
            return shift + start + sounded(at: reached)
        }
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
        carried = nil
        restartAnchors()
    }

    /// 止めて頭へ戻す。
    mutating func stop() {
        start = 0
        isPlaying = false
        leapt = false
        filledFrom = 0
        shift = 0
        carried = nil
        restartAnchors()
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
    /// ウィンドウの格子 (``AudioAnalysis/hop`` ごと) もこの番号に置く。標本は ``sample(at:in:)`` の決まりで
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
    ///
    /// 速さを変えた区切り (``isPlain`` でない) は、その番号の標本が鳴ったときに読んでいた位置を、音の側と同じ読み方
    /// (``FileRate/read(_:length:at:looping:kernel:)``) で読む。鳴らしたまま始め直した前の区切りが速さを変えていれば、
    /// 始まりより前の番号はその区切りの錨から読む。
    func sample(at index: Int, in samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        guard index - shift >= start else {
            // 始まりより前。ループなら、周回ぶん戻った番号もファイルの標本 (``carry(after:)`` の後は、前の周の音)
            guard leapt, filledFrom <= index else { return 0 }
            if let carried, index >= carried.base {
                return Self.read(
                    samples, sounded: index - carried.base, anchors: carried.anchors, looping: carried.looping)
            }
            if isLooping { return samples[index % samples.count] }
            return index < samples.count ? samples[index] : 0
        }
        guard isPlain else {
            return Self.read(samples, sounded: index - shift - start, anchors: anchors, looping: isLooping)
        }
        if isLooping { return samples[index % samples.count] }
        return index < samples.count ? samples[index] : 0
    }

    /// 錨 `anchors` の区切りで、鳴った数 `sounded` の標本。1 度だけなら、終わりに着いた後は 0。
    private static func read(
        _ samples: [Float], sounded: Int, anchors: [RateAnchor], looping: Bool
    ) -> Float {
        let anchor = anchors[anchorIndex(in: anchors, sounded: sounded)]
        let place = FileRate.position(
            from: anchor.position, elapsed: sounded - anchor.sounded, rate: anchor.rate)
        if !looping, place >= Double(samples.count) { return 0 }
        return samples.withUnsafeBufferPointer { buffer in
            FileRate.read(
                buffer.baseAddress!, length: buffer.count, at: place, looping: looping,
                kernel: anchor.kernel?.kernel)
        }
    }
}

/// 区切りの中で速さを変えた点 (錨。#3473)。そこから先は、位置が ``rate`` で進む。
nonisolated struct RateAnchor: Equatable {
    /// 区切りの頭から経った標本の数。
    var elapsed: Int
    /// そこまでに鳴った標本の数 (速さ 0 の間を除く)。
    var sounded: Int
    /// 読んでいた位置 (ファイルの標本・小数・ループでも折り返さない)。
    var position: Double
    var rate: Double
    /// 解析を読む低域通過の係数 (速さが 1 を越えるとき)。比べない (速さで決まる)。
    var kernel: RateKernel?

    static func == (lhs: RateAnchor, rhs: RateAnchor) -> Bool {
        lhs.elapsed == rhs.elapsed && lhs.sounded == rhs.sounded && lhs.position == rhs.position
            && lhs.rate == rhs.rate
    }
}
