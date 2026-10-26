// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import CoreGraphics
import CoreText
import Metal
import MokumeDiagnostics
import simd

/// 字形を焼いて溜めておく 1 枚の面。
///
/// ## なぜ 1 枚にまとめるのか
///
/// 字は 1 文字ずつ別々の絵だが、面を分けると**字ごとに描画を切らなければならない**。
/// 1 枚に詰めておけば、文字列も図形も同じ列にそのまま並べられる。
///
/// ## この面は色を持つ
///
/// 焼くのは覆っている割合ではなく**色そのもの** (線形 P3・アルファ乗算済み) である。
/// 単色の字は白で焼かれるので `RGB == A` になり、塗りの色を掛けると「塗りの色 ×
/// 覆い」に戻る — **覆いの面だったときと 1 画素も変わらない**。絵文字のように
/// それ自身が色を持つ字形は、その色がそのまま入る。
///
/// 焼く道具立ては ``ImageFile`` と同じで、色空間の変換は CoreGraphics が行う
/// ([ADR-0011] 決定 3 の「入口で変換」)。
///
/// [ADR-0011]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0011-color-model.md
///
/// ## 図形もこの面を読む
///
/// 左上の隅に**白く塗った区画**を置いてある。図形はそこを指すので、字と図形で
/// シェーダを分けずに済む (白を掛けても色は変わらない)。区画の中央を指すので、
/// 隣の字形が滲み込むことはない。
///
/// ## 書き込んでよい時機
///
/// **焼く口は GPU を待たない** ([#1792])。焼いた画素は頁 (``GlyphPage``) の控えに「区画 + 画素」で積み、
/// 描き切りがコマンドの先頭で GPU 側のコピーで頁へ届ける (画像と同じ・[#749])。コピーの前には、前の
/// 仕事が読み終わるのを待つ仕掛けを積む (`Canvas.encodeUploads`)。焼いたフレームの描きは新しい字を読む。
/// 焼く区画は作りたての場所で、普段は前の仕事がまだ読まない。GPU が固まった場面は、焼かずに諦める
/// のではなく、描き切りの待ちの期限と、打ち切りの後の届け直し ([#2199]) で扱われる。広げるとき (`grow`)
/// と焼き直すとき (`rebake`) は新しい頁 (``GlyphPage``) を作るだけなので待たない — 前の頁は、そこを
/// 指している列や形が手放すまで生き、控えも前の頁のものが前の頁へ届く。
///
/// **残る待ちは 2 つで、どちらも数えられる回数である。** 控えに積む量が上限 (``GlyphPage/pendingByteLimit``・
/// ``GlyphPage/pendingRegionLimit``) を越えたとき (多くの字を初めて焼くフレーム) と、控えの置き場が
/// 足りなくて取り直すとき (`GrowableBuffer`・ふだんは起きない) は、全完了を待つ。
///
/// [#749]: https://github.com/mokume-metal/mokume/issues/749
/// [#1792]: https://github.com/mokume-metal/mokume/issues/1792
/// [#2199]: https://github.com/mokume-metal/mokume/issues/2199
///
/// ## 上限の面が埋まったら
///
/// **同じ大きさの新しい頁へ替えて、要る字を焼き直す** (`rebake`・[#1342])。焼き分けの鍵には
/// 大きさが入るので、`textSize()` を連続的に変えると鍵が際限なく増え、上限の面もいずれ埋まる。
/// 替えずにいると、それ以後に初めて使う字が 1 つも描かれない。
///
/// いまの面を 0 で埋め直して使い回さないのは、前のフレームがまだその面を読んでいるかも
/// しれないからである — 埋め直すには GPU の完了を待つことになる。
///
/// [#1342]: https://github.com/mokume-metal/mokume/issues/1342
@MainActor final class GlyphAtlas {
    /// 最初の一辺 (画素)。
    static let initialSize = 256
    /// 広げられる上限 (画素)。
    static let maximumSize = 4096
    /// 初めの大きさから上限まで、頁を広げられる回数 (大きさは倍々に広がる)。
    static let maximumGrowths = (maximumSize / initialSize).trailingZeroBitCount
    /// 字形の絵の周りに置く余白 (画素)。
    ///
    /// **この余白は送り位置に混ざってはならない。** 焼くときに余白ぶんずらし、
    /// 描くときに同じだけ戻すので、位置には現れない。
    static let padding = 2
    /// 白く塗った区画の一辺 (画素)。
    static let whiteBlock = 4
    /// 作りたての頁で、字形より先に埋まっている左上の隅の一辺 (画素)。白い区画と、その周りの
    /// 余白である。
    ///
    /// **字形はこの隅を避けて置かれる** — 棚の 1 段目は隅の右から、2 段目は隅の下から始まる。
    /// そのため上限の頁でも、両辺とも上限いっぱいの字形は入らない ([#1492])。
    ///
    /// [#1492]: https://github.com/mokume-metal/mokume/issues/1492
    static let reservedCorner = whiteBlock + padding
    /// 焼き場の画素の形式。**作業空間と同じ** — 線形・アルファ乗算済みの 16F
    /// ([ADR-0011] 決定 2)。
    ///
    /// [ADR-0011]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0011-color-model.md
    static let pixelFormat: MTLPixelFormat = .rgba16Float
    /// 1 画素ぶんのバイト数。
    static let bytesPerPixel = MemoryLayout<SIMD4<Float16>>.stride
    /// 面を 0 で埋めるとき、1 度に流す帯の上限 (バイト)。
    ///
    /// **面の画素数に比例させないための固定値** ([#796])。面と同じ大きさを CPU 側に
    /// 持つと 4096 の面で 128 MiB を瞬間的に確保する。かといって 1 行ずつ流すと
    /// `replace` の呼び出しが一辺の数だけ要り、4096 まで育てる経路が 6 倍遅くなる
    /// (22.5 ms → 134.7 ms の実測)。帯にすると確保は 1 MiB で頭打ち、呼び出しは
    /// 4096 の面でも 128 回で済む。
    ///
    /// [#796]: https://github.com/mokume-metal/mokume/issues/796
    static let blankBandBytes = 1 << 20

    /// 焼いた字形 1 つぶん。
    struct Entry {
        /// 面の中での左上と右下 (0…1)。
        var uvMin: SIMD2<Float>
        var uvMax: SIMD2<Float>
        /// 送り位置と基準線から見た、絵の左上のずれ (画素)。
        var offset: SIMD2<Float>
        /// 絵の大きさ (画素)。
        var size: SIMD2<Float>
        /// 絵を持たない字 (空白など)。
        var isBlank: Bool
        /// **字形が自分の色を持っているか** (絵文字がこれに当たる)。
        ///
        /// 色を持つ字形には塗りの色を掛けない — 積む側が頂点の色を「白 × 塗りの
        /// 透明度」に差し替えるので、合成の式は 1 本のままでよい (``Canvas``)。
        var isColored: Bool
    }

    /// 字形を引いた結果。**引けなかったときは理由を名乗る** ([#738])。
    ///
    /// 理由が要るのは、受け取る側が「面を広げれば入るのか」を判断できないためである。
    /// 分けないと、広げても入らない 1 字のために面を広げ続けることになる — 広げるたびに
    /// 焼いた字形は全部捨てられるので、**入らない字が他の全部を焼き直させる**形になり、
    /// 上限まで行き着いた後は回復もしない。
    ///
    /// [#738]: https://github.com/mokume-metal/mokume/issues/738
    enum Lookup {
        /// 焼いてある (あるいはいま焼いた) 字形。
        case found(Entry)
        /// いまの面に場所が無い。**広げれば入る** — 上限の面なら、焼き直せば入る (`rebake`)。
        ///
        /// **1 段広げて足りるとは限らない** ([#1460])。面は倍ずつにしか育たないので、
        /// 受け取る側は入るまで広げて引き直す。
        ///
        /// 「入る」は約束である。作りたての上限の頁にも入らない字形は、ここへ来る前に
        /// ``tooLarge(width:height:)`` を名乗る ([#1492])。
        ///
        /// [#1460]: https://github.com/mokume-metal/mokume/issues/1460
        /// [#1492]: https://github.com/mokume-metal/mokume/issues/1492
        case full
        /// 作りたての上限の頁 (``maximumSize``) にも入らない。**広げても焼き直しても入らない。**
        ///
        /// **両辺が上限以下でも当たる** ([#1492])。頁の左上の隅 (``reservedCorner``) を避けて
        /// 置くので、両辺を上限いっぱいには使えない。これを ``full`` と名乗ると、受け取る側は
        /// 焼き直せば入ると読む。入らないまま、上限の頁を毎フレーム作り直すことになる。
        ///
        /// 大きさは余白込みの画素数で、**Int に収まらなければ `Int.max` に張り付く** ([#1587])。
        ///
        /// [#1492]: https://github.com/mokume-metal/mokume/issues/1492
        /// [#1587]: https://github.com/mokume-metal/mokume/issues/1587
        case tooLarge(width: Int, height: Int)
        /// 焼けなかった。**広げても変わらない** — 字形の大きさが焼き場の座標に収まらない (幅か高さが 0 以下・
        /// 外接矩形が Int に直せない) か、CPU で描けなかった。
        ///
        /// 以前は GPU の完了を待てなくて面へ書かなかった場合 ([#934]) もここへ来たが、焼く口が待たなく
        /// なったので ([#1792]) 来ない。
        ///
        /// [#934]: https://github.com/mokume-metal/mokume/issues/934
        /// [#1792]: https://github.com/mokume-metal/mokume/issues/1792
        case unbakeable
    }

    /// 焼き分けの鍵。
    struct Key: Hashable {
        var fontKey: String
        var size: Float
        var style: TextStyle
        var glyph: UInt16
        /// 頼んだ太さ (100〜900 の整数)。0 は頼んでいない ([#2445])。**整数に丸めた値が入る** —
        /// 500.2 と 500.4 は同じ字形を使い、500 と 501 は別に焼く。毎フレーム太さを動かすと焼き直しが
        /// 続く代償は、`size` を動かすのと同じ形である (上限の頁を替えて焼き直す・[#1342])。
        ///
        /// [#2445]: https://github.com/mokume-metal/mokume/issues/2445
        /// [#1342]: https://github.com/mokume-metal/mokume/issues/1342
        var weight: Int = 0
        /// 焼く拡大の段 ([#2446])。0 は `size` の大きさそのままで焼く (拡大を掛けない・これまでの焼き方)。
        /// `n` は ``GlyphAtlas/ratio(ofStep:)`` 倍の画素で焼く — 字形の形と並びは `size` のまま、
        /// 描く面の画素だけを細かくする。
        ///
        /// [#2446]: https://github.com/mokume-metal/mokume/issues/2446
        var step: Int = 0
    }

    /// 1 オクターブ (2 倍) を何段に刻むか ([#2446])。拡大を動かすと、この段の境を越えるたびに焼き直す。
    /// 細かいほど拡大に合った画素で焼けるが、焼き直しが増える。
    ///
    /// [#2446]: https://github.com/mokume-metal/mokume/issues/2446
    static let stepsPerOctave = 8

    /// 段 `step` で焼くときの、`size` に対する倍率。段 0 は厳密に 1。
    static func ratio(ofStep step: Int) -> Float {
        step == 0 ? 1 : RuntimeMath.pow(2, Float(step) / Float(stepsPerOctave))
    }

    // MARK: - 拡大した字形を焼く量の上限 ([#2446])
    //
    // 拡大した字形は、段が変わるたびに焼き直す。**拡大を動かす絵が 1 フレームに焼く量**と、**1 字の大きさ**
    // と、**面のうち拡大した字形が占める割合**の 3 つを抑える。どれも越えたとき、字を欠かさず、焼いてある
    // 近い段か低い段の画素で描く (以前は伸ばして描いていたので、それを下回らない)。
    //
    // [#2446]: https://github.com/mokume-metal/mokume/issues/2446

    /// 1 フレームに、新しく焼いてよい拡大した字形 (段が 0 より上) の数の上限。**数と画素のバイト数の両方で
    /// 数える** (``scaledBakeBytesPerFrame``)。越えた分は、その字形で焼いてある近い段で描き、次のフレームで
    /// 先に焼く (``admitScaledBake(_:bytes:frame:)``)。
    var scaledBakesPerFrame = 64

    /// **1 字の大きさ**の上限 (画素のバイト数)。頁の控えの上限 (``pendingByteLimit``) と同じ値にする —
    /// 1 字で越えると、焼くたびに GPU の全完了を待つ ([#1792])。これを越える段は焼かず、収まる段まで下げる
    /// (``plan(for:font:)``)。
    ///
    /// [#1792]: https://github.com/mokume-metal/mokume/issues/1792
    var scaledBakeByteLimit: Int { pendingByteLimit }

    /// 1 フレームに新しく焼いてよい拡大した字形の画素のバイト数。**1 字の上限 (``scaledBakeByteLimit``) より
    /// 小さく置く** — 1 フレームの焼きを抑え、フレームの時間を揃える (測った値は #2446 の PR)。
    /// 1 フレームの最初の 1 字は、この量を越えても焼く。
    var scaledBakeBytesPerFrame = 2 << 20

    /// 面の上から何割までの段 (棚) に、拡大した字形を置いてよいか。下の残りは、拡大しない字 (段 0) の分
    /// である。**拡大した字形で面の底まで埋め尽くすと、そのフレームの後の字が (小さなラベルも) 置けず欠ける。**
    /// 面積ではなく棚の高さで区切る — 棚は左から詰めるので、幅の狭い字が混じると面積では数え切れない。
    static let scaledPageShare = 0.75

    /// 拡大した字形を置いてよい、面の上からの高さ (画素)。
    private static func scaledRowLimit(side: Int) -> Int { Int(scaledPageShare * Double(side)) }

    /// **このフレームの絵が、次のフレームに描き直されて残らないと分かっているか。** 立てた面だけが、上限を
    /// 越えた字の焼きを次のフレームへ送る (近い段の画素で描いた四角を、そのフレームの間だけ残す)。下ろした
    /// ままなら (既定) 上限を外して、字を要る段で焼き切る — 描き場所の絵・書き出す絵・撮る絵・止めた絵・形に
    /// 記録した字は残るので、送るとぼけたまま残る。
    ///
    /// 立てるのは走らせる側 (`SketchRuntime`) で、窓に出しながら回していて、次のフレームがそのフレームを描き
    /// 直すと分かっているときだけである。形の組み立ての中は、呼ぶ側 (``Canvas``) が送らない。
    var mayDeferScaledBakes = false

    private var budgetFrame = -1
    private var scaledBakesThisFrame = 0
    private var scaledBytesThisFrame = 0

    /// 焼けずに先送りした字形。`bytes` は頼んだ段で焼くバイト数、`age` は続けて何フレーム先送りしたか。
    private struct Owed {
        var bytes: Int
        var age: Int
    }
    /// 前のフレームで上限に当たり、焼けずに近い段か段 0 で描いた字形 (段を除いた鍵 → 先送りの履歴)。
    /// **このフレームでは、先送りが長い字形から先に焼く枠を持つ** — 描く順で早い字が枠を使い切ると、後ろの字が
    /// いつまでも焼けない (速くズームする絵で、後ろの字だけ近い段のまま残る)。新しい字形 (age 0) は、先送りした
    /// 字形すべての分を除いた残りしか使えず、先送りした字形は、自分より長く先送りした字形の分を除いた残りを使う。
    private var owedLastFrame: [Key: Owed] = [:]
    private var owedThisFrame: [Key: Owed] = [:]
    /// `owedLastFrame` を先送りの長さ (age) で数えた累積。``admitScaledBake(_:bytes:frame:deferrable:)`` が
    /// 「自分より長く先送りした字形の分」を、全件を走らずに引く。`owedLastFrame` を動かすたびに合わせる。
    private var owedLastFrameTotals = OwedTotals()

    /// 先送りの長さごとの (数・バイト) の累積。age は昇順・重複なしで、各 age について「その age 以上」の
    /// 合計を持つ。引くのは二分探索、字形が 1 つ消えるときの更新は、その age 以下の累積から引くだけである
    /// (全件の走査も、フレームの頭での前計算も要らない — 字形は判定の途中で消える)。
    private struct OwedTotals {
        private var ages: [Int] = []
        private var countFrom: [Int] = []
        private var bytesFrom: [Int] = []

        /// 先送りの履歴から作る (フレームが替わって `owedLastFrame` を差し替えたとき)。
        init(_ owed: some Sequence<Owed>) {
            var perAge: [Int: (count: Int, bytes: Int)] = [:]
            for entry in owed {
                let total = perAge[entry.age] ?? (0, 0)
                perAge[entry.age] = (total.count + 1, total.bytes + entry.bytes)
            }
            ages = perAge.keys.sorted()
            countFrom = [Int](repeating: 0, count: ages.count)
            bytesFrom = [Int](repeating: 0, count: ages.count)
            var count = 0
            var bytes = 0
            for index in ages.indices.reversed() {
                let total = perAge[ages[index]]!
                count += total.count
                bytes += total.bytes
                countFrom[index] = count
                bytesFrom[index] = bytes
            }
        }

        init() {}

        /// `age` より長く先送りした字形の数とバイト数。
        func longer(than age: Int) -> (count: Int, bytes: Int) {
            var low = 0
            var high = ages.count
            while low < high {
                let middle = (low + high) / 2
                if ages[middle] > age { high = middle } else { low = middle + 1 }
            }
            return low == ages.count ? (0, 0) : (countFrom[low], bytesFrom[low])
        }

        /// 先送りの履歴から外れた字形の分を引く。
        mutating func remove(_ owed: Owed) {
            guard let index = ages.firstIndex(of: owed.age) else { return }
            for position in 0...index {
                countFrom[position] -= 1
                bytesFrom[position] -= owed.bytes
            }
        }
    }

    /// 検査が読む: 先送りして焼けていない字形の数。
    var owedGlyphCount: Int { owedLastFrame.count + owedThisFrame.count }

    private func openBudget(frame: Int) {
        guard budgetFrame != frame else { return }
        budgetFrame = frame
        scaledBakesThisFrame = 0
        scaledBytesThisFrame = 0
        owedLastFrame = owedThisFrame
        owedLastFrameTotals = OwedTotals(owedLastFrame.values)
        owedThisFrame = [:]
    }

    /// 拡大した字形 1 つ (`bytes` バイト) を、このフレームに新しく焼いてよいか。**焼くなら数と量を数える。**
    ///
    /// 焼けなかった字形は控えて、次のフレームで先に焼く。`mayDeferScaledBakes` が下りていれば常に焼く
    /// (数えはする)。
    func admitScaledBake(_ key: Key, bytes: Int, frame: Int, deferrable: Bool = true) -> Bool {
        openBudget(frame: frame)
        var identity = key
        identity.step = 0
        let age = owedLastFrame[identity]?.age ?? 0
        var allowed = true
        if mayDeferScaledBakes && deferrable {
            // 自分より長く先送りした字形の分。表から引く (先送りの全件を走らない)
            let (reservedCount, reservedBytes) = owedLastFrameTotals.longer(than: age)
            let countFits = scaledBakesThisFrame + reservedCount < scaledBakesPerFrame
            // 1 フレームの最初の 1 字は、量が枠を越えても焼く (1 字の大きさは別に頭打ちにしてある)
            let first = scaledBytesThisFrame == 0 && reservedBytes == 0
            let bytesFit = first || scaledBytesThisFrame + bytes + reservedBytes <= scaledBakeBytesPerFrame
            allowed = countFits && bytesFit
        }
        guard allowed else {
            owedThisFrame[identity] = Owed(bytes: bytes, age: age + 1)
            return false
        }
        scaledBakesThisFrame += 1
        scaledBytesThisFrame += bytes
        if let paid = owedLastFrame.removeValue(forKey: identity) { owedLastFrameTotals.remove(paid) }
        return true
    }

    /// 先送りした字形が、別の道で要る段に焼けた (焼いてあった・低い段で決まった・フレームの終わりに払った)。
    /// **先送りの履歴から外す** — 残すと、次のフレームで若い字の枠をその分だけ押さえる。
    func noteBaked(_ key: Key, frame: Int) {
        guard !owedLastFrame.isEmpty || !owedThisFrame.isEmpty else { return }
        openBudget(frame: frame)
        var identity = key
        identity.step = 0
        if let paid = owedLastFrame.removeValue(forKey: identity) { owedLastFrameTotals.remove(paid) }
        owedThisFrame.removeValue(forKey: identity)
    }

    /// 字形の外接矩形を倍率 `ratio` で拡げ、余白を足して整数へ広げた升目の縁。
    private struct Edges {
        var left: CGFloat
        var bottom: CGFloat
        var right: CGFloat
        var top: CGFloat
        var width: CGFloat { right - left }
        var height: CGFloat { top - bottom }
    }

    private static func edges(of bounds: CGRect, ratio: CGFloat) -> Edges {
        var bounds = bounds
        if ratio != 1 { bounds = bounds.applying(CGAffineTransform(scaleX: ratio, y: ratio)) }
        let pad = CGFloat(padding)
        return Edges(
            left: bounds.minX.rounded(.down) - pad, bottom: bounds.minY.rounded(.down) - pad,
            right: bounds.maxX.rounded(.up) + pad, top: bounds.maxY.rounded(.up) + pad)
    }

    /// 頼んだ段 (`key.step`) の字形を、**1 字の大きさの上限に収まる段まで下げた段**と、その段で焼く画素の
    /// バイト数。空白など絵の無い字形は、頼んだ段のままバイト数 0。
    ///
    /// 上限は 2 つ — 1 字が頁に入ること (``fitsFreshPage(width:height:side:)``・面の割合を含む) と、
    /// 画素が ``scaledBakeByteLimit`` に収まること。段 0 は下げない (これまでの焼き方で、上限は
    /// ``bake(key:font:)`` が名乗る)。
    func plan(for key: Key, font: CTFont) -> (step: Int, bytes: Int) {
        var glyph = CGGlyph(key.glyph)
        let bounds = CTFontGetBoundingRectsForGlyphs(font, .horizontal, &glyph, nil, 1)
        guard bounds.width > 0, bounds.height > 0, bounds.width.isFinite, bounds.height.isFinite
        else { return (key.step, 0) }
        let limitPixels = CGFloat(scaledBakeByteLimit / Self.bytesPerPixel)
        // 拡大した字形は、作りたての上限の頁でも棚の上から ``scaledPageShare`` までに収まる大きさに限る
        let rowSide = Self.scaledRowLimit(side: Self.maximumSize)
        var step = key.step
        while true {
            let edges = Self.edges(of: bounds, ratio: CGFloat(Self.ratio(ofStep: step)))
            let pixels = edges.width * edges.height
            if step == 0
                || Self.fitsFreshPage(width: edges.width, height: edges.height, side: rowSide)
                    && pixels <= limitPixels
            {
                return (step, Int(min(pixels, CGFloat(Int.max / Self.bytesPerPixel)))
                    * Self.bytesPerPixel)
            }
            step -= 1
        }
    }

    /// 焼いてある字形。**焼かない** — 無ければ `nil`。
    func cachedEntry(for key: Key) -> Entry? { entries[key] }

    /// 1 つの頁が控えに積んでよいバイト数・区画の数の上限 (``GlyphPage/pendingByteLimit``・
    /// ``GlyphPage/pendingRegionLimit``)。**頁を替えても引き継ぐ。** 検査が差し替える。
    var pendingByteLimit = GlyphPage.defaultPendingByteLimit {
        didSet { page.pendingByteLimit = pendingByteLimit }
    }
    var pendingRegionLimit = GlyphPage.defaultPendingRegionLimit {
        didSet { page.pendingRegionLimit = pendingRegionLimit }
    }

    /// いま字形を焼いている頁。**広げると差し替わる。**
    private(set) var page: GlyphPage
    private(set) var size: Int
    private var entries: [Key: Entry] = [:]
    /// いまの頁の通し番号。**頁を替えるたびに変わり、どの焼き場の頁とも重ならない** ([#1783])。
    ///
    /// 書体が持つ字形の控え (``Typeface/placed``) が、引いた字形がまだこの頁のものかを
    /// 確かめるのに使う。頁を替えると焼いた字形は全部捨てられる (``startPage(side:gpu:)``)
    /// ので、番号が違えば控えは古い。
    ///
    /// [#1783]: https://github.com/mokume-metal/mokume/issues/1783
    private(set) var pageSerial: UInt64
    private static var nextPageSerial: UInt64 = 0
    /// 焼いた字形の数。**検査が読む** — 区間の外の `text()` が字を焼かないことを数える (#1672)。
    var bakedCount: Int { entries.count }
    private var cursorX: Int
    private var cursorY: Int
    private var rowHeight: Int
    /// 1 度だけ言う注意の種類。仕組みは ``WarningLog`` が持つ ([#734])。
    ///
    /// [#734]: https://github.com/mokume-metal/mokume/issues/734
    enum Warning: Hashable {
        /// 作りたての上限の頁にも入らない字形を頼まれた。
        ///
        /// **毎フレーム起きうる** — 入らない字は焼かれないので、次のフレームでも同じ道を
        /// 通る。1 度だけ言うのは ``Diagnostics/warn(_:)`` の但し書きに従う。
        case tooLarge
    }

    /// 測る側が CPU で描いた字形の画素。焼くときに同じ升目なら、描き直さずに使う ([#2560])。
    struct Rendered {
        var width: Int
        var height: Int
        /// 書き始めの位置 (升目の左下から)。
        var penX: Int
        var penY: Int
        var pixels: [SIMD4<Float16>]
    }

    /// 預かっている画素 (``keepRendered(_:for:)``)。
    private var kept: [Key: Rendered] = [:]
    private var keptBytes = 0
    /// 預かる画素の上限 (バイト)。96 MiB は、3000 の絵文字の升目 (72 MB) が入る大きさ。
    ///
    /// **預かったまま焼かれない画素を溜めない** — `textBounds` だけを呼ぶスケッチは、`text()` が
    /// 引き取らない画素を毎フレーム預ける。超えるときは預かっている分を捨て、1 つで上限を超える
    /// 大きさは預けない (描き直しになるだけで、墨は変わらない)。
    var keptLimitBytes = 96 << 20
    /// 預かっている字形の数。**検査が読む。**
    var keptCount: Int { kept.count }

    /// CPU で字形を描いた回数。焼くときと、測る側 (``Typeface/drawnInk(of:_:keeping:as:)``) が
    /// 描くときの、どちらも数える。**検査が読む** — 同じ字形を同じ大きさで測って焼いても、描くのは
    /// 1 回であること ([#2560])。
    private(set) var cpuRenders = 0

    /// 字形を CPU で描く。**焼き場も測る側も、描くときはここを通す** (数えるため)。
    func renderOnCPU(
        glyph: CGGlyph, font: CTFont, width: Int, height: Int, penX: Int, penY: Int,
        scale: CGFloat = 1
    ) -> [SIMD4<Float16>]? {
        cpuRenders += 1
        return Self.render(
            glyph: glyph, font: font, width: width, height: height, penX: penX, penY: penY,
            scale: scale)
    }

    /// 測る側が描いた画素を預かる。同じ鍵の字形を焼くとき、同じ升目なら描き直さずに使う。
    ///
    /// **描き方は焼き場と同じ** (``render(glyph:font:width:height:penX:penY:scale:)``) なので、預けた画素から
    /// 焼いた字形は、描き直して焼いたものと 1 ビットも変わらない。
    ///
    /// [#2560]: https://github.com/mokume-metal/mokume/issues/2560
    func keepRendered(_ rendered: Rendered, for key: Key) {
        let bytes = rendered.pixels.count * Self.bytesPerPixel
        guard bytes <= keptLimitBytes else { return }
        if let old = kept.removeValue(forKey: key) {
            keptBytes -= old.pixels.count * Self.bytesPerPixel
        }
        if keptBytes + bytes > keptLimitBytes {
            kept.removeAll()
            keptBytes = 0
        }
        kept[key] = rendered
        keptBytes += bytes
    }

    /// 預かった画素を、同じ升目なら引き取る。違う升目のものは使わず捨てる。
    private func takeRendered(
        for key: Key, width: Int, height: Int, penX: Int, penY: Int
    ) -> [SIMD4<Float16>]? {
        guard let rendered = kept.removeValue(forKey: key) else { return nil }
        keptBytes -= rendered.pixels.count * Self.bytesPerPixel
        guard rendered.width == width, rendered.height == height, rendered.penX == penX,
            rendered.penY == penY
        else { return nil }
        return rendered.pixels
    }

    /// 言った注意の控え。**検査が読む。**
    private(set) var warnings = WarningLog<Warning>()

    init(gpu: RenderDevice) throws(RenderFailure) {
        self.size = Self.initialSize
        self.page = try GlyphPage(side: size, gpu: gpu)
        self.pageSerial = Self.takePageSerial()
        self.cursorX = Self.reservedCorner
        self.cursorY = 0
        self.rowHeight = Self.reservedCorner
        paintWhiteBlock()
    }

    /// いまの頁の面。
    var texture: any MTLTexture { page.texture }

    /// いまの頁の面を、頁と組にして渡す。**列へ渡すときはこちら** (``HeldTexture``)。
    var held: HeldTexture { HeldTexture(texture: page.texture, owner: page) }

    static func makeTexture(side: Int, gpu: RenderDevice) throws(RenderFailure)
        -> any MTLTexture
    {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: Self.pixelFormat, width: side, height: side, mipmapped: false)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        let texture = try gpu.makeTexture(descriptor: descriptor)
        texture.label = "mokume.glyphs"
        fillTransparent(texture, side: side)
        return texture
    }

    /// 面全体を 0 で埋める。字形を焼く前に読まれても、透明として振る舞う。
    ///
    /// **帯を使い回して流す** ([#796] — 上限は ``blankBandBytes`` が持つ)。面と同じ
    /// 大きさを CPU 側に持つと、抜けた後も malloc が抱えた山が残る。
    ///
    /// 面を作る側から切り出してあるのは、**覆い残しを検査から見られるようにする**
    /// ためである。作りたての面は Metal が 0 で返すので、`makeTexture` を通した後を
    /// 読んでも、埋めたのか初めから 0 だったのかが分からない。
    ///
    /// [#796]: https://github.com/mokume-metal/mokume/issues/796
    static func fillTransparent(_ texture: any MTLTexture, side: Int) {
        let bytesPerRow = side * Self.bytesPerPixel
        let bandRows = max(1, min(side, Self.blankBandBytes / bytesPerRow))
        let blank = [SIMD4<Float16>](repeating: .zero, count: side * bandRows)
        blank.withUnsafeBytes { source in
            let bytes = source.baseAddress!
            var row = 0
            while row < side {
                let height = min(bandRows, side - row)
                texture.replace(
                    region: MTLRegionMake2D(0, row, side, height), mipmapLevel: 0,
                    withBytes: bytes, bytesPerRow: bytesPerRow)
                row += height
            }
        }
    }

    /// 左上の隅を白く塗る。図形はここを指す。
    private func paintWhiteBlock() {
        let side = Self.whiteBlock
        let white = [SIMD4<Float16>](repeating: SIMD4(1, 1, 1, 1), count: side * side)
        texture.replace(
            region: MTLRegionMake2D(0, 0, side, side), mipmapLevel: 0, withBytes: white,
            bytesPerRow: side * Self.bytesPerPixel)
    }

    /// 図形が指す、白い区画の中の点。
    ///
    /// 区画の中央 — 白い画素だけに囲まれた点を指すので、線形に読んでもちょうど 1 になる。
    var whiteUV: SIMD2<Float> {
        let center = Float(Self.whiteBlock) / 2 / Float(size)
        return SIMD2(center, center)
    }

    /// もう一段広げられるか。
    var canGrow: Bool { size < Self.maximumSize }

    /// 面を倍の大きさで取り直す。
    ///
    /// **焼いた字形は引き継がない。** 新しい面の中では場所が変わるので、位置を
    /// 計算し直すより、要るものをもう一度焼くほうが単純である。前の頁は、そこを
    /// 指している列や保持した形が抱えたまま残る。
    ///
    /// **前の頁を常駐から退かせるのは、頁自身が死ぬとき**である (``GlyphPage``)。ここで
    /// 退かせないのは、外す番がその時点の投入番号で決まるからで、広げるのは列を閉じた
    /// 直後 = フレームの途中なので、前の頁を指す列はまだ番号を持っていない — ここで
    /// 退かせると、その列が読む前に外れた ([#1079])。保持した形はフレームをまたいで
    /// 前の頁を読み続けるので、番号をどう遅らせても足りない ([#1178])。
    ///
    /// 外すこと自体をやめたわけではない。指す側が全部手放せば頁が死に、そこで外れる —
    /// 外さないと 256 から 4096 までの面が全部残り、最後の 1 枚だけで 128 MiB になる
    /// ([#738])。
    ///
    /// [#738]: https://github.com/mokume-metal/mokume/issues/738
    /// [#1079]: https://github.com/mokume-metal/mokume/issues/1079
    /// [#1178]: https://github.com/mokume-metal/mokume/issues/1178
    func grow(gpu: RenderDevice) throws(RenderFailure) {
        try startPage(side: min(Self.maximumSize, size * 2), gpu: gpu)
    }

    /// 同じ大きさの新しい頁へ替え、焼いた字形を捨てる。**上限の面が埋まったときに使う**
    /// ([#1342])。
    ///
    /// 広げるとき (``grow(gpu:)``) と同じ道を通る — 前の頁は、そこを指している列や保持した
    /// 形が抱えたまま残るので、**GPU を待たない**。要る字は、次に頼まれたときに新しい頁へ
    /// 焼かれる。
    ///
    /// 何度でも呼べるが、**1 フレームに何枚替えるかは呼ぶ側が決める** — 上限の頁は 1 枚で
    /// 128 MiB あり、替えた頁はそのフレームを描き終えるまで残る。
    ///
    /// [#1342]: https://github.com/mokume-metal/mokume/issues/1342
    func rebake(gpu: RenderDevice) throws(RenderFailure) {
        try startPage(side: size, gpu: gpu)
    }

    private static func takePageSerial() -> UInt64 {
        defer { nextPageSerial &+= 1 }
        return nextPageSerial
    }

    /// 一辺 `side` の新しい頁を作り、焼いた字形の控えと棚を空に戻す。
    private func startPage(side: Int, gpu: RenderDevice) throws(RenderFailure) {
        // **新しい頁を先に作る。** 作れずに投げたときも、前の頁はそのまま使える
        let fresh = try GlyphPage(side: side, gpu: gpu)
        fresh.pendingByteLimit = pendingByteLimit
        fresh.pendingRegionLimit = pendingRegionLimit
        page = fresh
        size = side
        entries.removeAll(keepingCapacity: true)
        pageSerial = Self.takePageSerial()
        cursorX = Self.reservedCorner
        cursorY = 0
        rowHeight = Self.reservedCorner
        paintWhiteBlock()
    }

    /// 作りたての一辺 `side` の頁に、`width`×`height` の字形が入るか。
    ///
    /// **棚の詰め方 (``reserve(width:height:)``) と同じ答えを返す。** 作りたての棚は隅
    /// (``reservedCorner``) の右から始まるので、幅が `side - 隅` までなら 1 段目に入り、高さは
    /// `side` まで使える。幅がそれを越えると隅の下の 2 段目へ送られ、今度は幅が `side` まで、
    /// 高さが `side - 隅` までになる。合わせると、**長いほうの辺が `side` まで、短いほうの辺が
    /// `side - 隅` まで**である ([#1492])。
    ///
    /// **大きさは浮動小数のまま受ける** ([#1587])。巨大な字形の大きさは Int に収まらないので、
    /// Int へ直す前にここで比べる。整数の画素数はそのまま表せるので、答えは Int で比べたときと同じ。
    ///
    /// [#1492]: https://github.com/mokume-metal/mokume/issues/1492
    /// [#1587]: https://github.com/mokume-metal/mokume/issues/1587
    static func fitsFreshPage(width: CGFloat, height: CGFloat, side: Int) -> Bool {
        max(width, height) <= CGFloat(side)
            && min(width, height) <= CGFloat(side - reservedCorner)
    }

    /// 画素数を Int へ直す。**Int に収まらなければ `Int.max` に張り付ける** — 焼き場に入らない
    /// 字形の大きさを名乗るためだけに使う (``Lookup/tooLarge(width:height:)``)。
    static func saturatingInt(_ pixels: CGFloat) -> Int {
        Int(exactly: pixels) ?? Int.max
    }

    /// 注意の文面に載せる画素数。Int に収まればこれまでどおり整数で、収まらなければ浮動小数の
    /// 表記で言う (`Int.max` に張り付けた数を言うと、実際と違う大きさを名乗ることになる)。
    private static func pixelCount(_ pixels: CGFloat) -> String {
        Int(exactly: pixels).map(String.init) ?? "\(pixels)"
    }

    /// 焼いてある字形。まだ無ければ焼く。**引けなければ理由を返す。**
    func entry(for key: Key, font: CTFont) -> Lookup {
        if let found = entries[key] { return .found(found) }
        let baked = bake(key: key, font: font)
        if case .found(let entry) = baked { entries[key] = entry }
        return baked
    }

    /// 字形を焼いて面へ置く。
    private func bake(key: Key, font: CTFont) -> Lookup {
        var glyph = CGGlyph(key.glyph)
        // **拡大の段は、書体の大きさの引数を変えずに、描く面の拡大で作る** (#2446)。大きさの引数を変えると、
        // 光学サイズを持つ書体 (既定の SF) は大きな光学サイズの字形にすり替わる
        let ratio = CGFloat(Self.ratio(ofStep: key.step))
        let bounds = CTFontGetBoundingRectsForGlyphs(font, .horizontal, &glyph, nil, 1)

        // 絵を持たない字 (空白)。場所は取らないが、送り幅は持つ
        guard bounds.width > 0, bounds.height > 0, bounds.width.isFinite, bounds.height.isFinite
        else {
            return .found(
                Entry(
                    uvMin: .zero, uvMax: .zero, offset: .zero, size: .zero, isBlank: true,
                    isColored: false))
        }

        // **Int へ直す前に、浮動小数のまま大きさを見る** (#1587)。巨大な大きさでは外接矩形の辺が
        // Int の範囲を越え、先に直すとそこでプロセスごと落ちる。上限の頁は Int の範囲よりはるかに
        // 小さいので、入るかどうかは浮動小数で決まる
        let edges = Self.edges(of: bounds, ratio: ratio)
        let (leftEdge, bottomEdge, rightEdge, topEdge) = (edges.left, edges.bottom, edges.right, edges.top)
        let extent = (width: edges.width, height: edges.height)
        guard extent.width > 0, extent.height > 0 else { return .unbakeable }
        // **作りたての上限の頁にも入らないなら、広げても焼き直しても入らない。** ここで名乗って
        // 諦める。上限と比べるだけでは足りない — 両辺が上限以下でも、左上の隅のぶん入らない
        // 字形がある (#1492)
        guard Self.fitsFreshPage(width: extent.width, height: extent.height, side: Self.maximumSize)
        else {
            // 拡大した字形が入らないときは、呼ぶ側が低い段で描く。段 0 の字形だけ知らせる
            if key.step == 0 { warnTooLargeOnce(width: extent.width, height: extent.height) }
            return .tooLarge(
                width: Self.saturatingInt(extent.width), height: Self.saturatingInt(extent.height))
        }
        // 入る字形の辺は Int に収まる。収まらないのは、外接矩形が原点から Int の範囲の外まで
        // 離れた字形だけで、焼いても置く場所の計算が成り立たない
        guard let left = Int(exactly: leftEdge), let bottom = Int(exactly: bottomEdge),
            let right = Int(exactly: rightEdge), let top = Int(exactly: topEdge)
        else { return .unbakeable }
        let width = right - left
        let height = top - bottom
        // いまの面より大きいだけなら、広げれば入る
        guard width <= size, height <= size else { return .full }

        // 拡大した字形は、棚の上から ``scaledPageShare`` までにしか置かない。入らなければ、場所が無いものとして扱う
        // (呼ぶ側は広げるか焼き直すか、低い段へ下がる)。拡大しない字の分を残す
        guard
            let origin = reserve(
                width: width, height: height,
                rowLimit: key.step == 0 ? nil : Self.scaledRowLimit(side: size))
        else { return .full }
        // 測る側が同じ升目に描いて預けていれば、描き直さずに使う (#2560)
        guard
            let pixels = takeRendered(
                for: key, width: width, height: height, penX: -left, penY: -bottom)
                ?? renderOnCPU(
                    glyph: glyph, font: font, width: width, height: height, penX: -left,
                    penY: -bottom, scale: ratio)
        else { return .unbakeable }

        // **待たずに、焼いた画素を頁の控えへ積む** (#1792)。届けるのは描き切りの GPU 側のコピーで、
        // コピーの前に前の仕事の読みを待つ仕掛けを積む。この区画は作りたての (前の仕事がまだ読まない)
        // 場所なので、普段は前のフレームが読んでいる画素を書き換えることも無い
        page.stage(x: origin.x, y: origin.y, width: width, height: height, pixels: pixels)

        let side = Float(size)
        // 拡大の段は、座標の単位 (`size` の大きさ) に戻して持つ。置く側は変わらず、拡大が段の倍率と
        // 同じなら、焼いた画素と描く画素が 1 対 1 になる (#2446)
        let unit = Float(ratio)
        var offset = SIMD2(Float(left), Float(-top))
        var drawnSize = SIMD2(Float(width), Float(height))
        if key.step != 0 {
            offset /= unit
            drawnSize /= unit
        }
        return .found(
            Entry(
                uvMin: SIMD2(Float(origin.x) / side, Float(origin.y) / side),
                uvMax: SIMD2(Float(origin.x + width) / side, Float(origin.y + height) / side),
                // 縦は下向きに測るので、基準線から上端までの距離が負のずれになる
                offset: offset,
                size: drawnSize,
                isBlank: false,
                isColored: Self.hasOwnColor(pixels)))
    }

    /// 広げても入らない字形を頼まれたことを、**最初の 1 度だけ**知らせる。
    ///
    /// 黙って何も描かないと、利用者は書体か色か位置を疑う ([ADR-0020] 決定 5)。
    /// 大きさが理由だと分かれば、`textSize()` を下げるという次の一手が打てる。
    ///
    /// **上限は 2 つ言う** — 長いほうの辺と、短いほうの辺 (``fitsFreshPage(width:height:side:)``)。
    /// 面の一辺だけを並べると、4091×4091 の字形が「4096×4096 に入らない」と言われ、食い違って
    /// 読める ([#1492])。
    ///
    /// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
    /// [#1492]: https://github.com/mokume-metal/mokume/issues/1492
    private func warnTooLargeOnce(width: CGFloat, height: CGFloat) {
        warnings.warnOnce(
            .tooLarge,
            "text(): one glyph is \(Self.pixelCount(width))x\(Self.pixelCount(height)) pixels, "
                + "which does not fit the baking area: it "
                + "takes glyphs of at most \(Self.maximumSize) pixels on the longer side and "
                + "\(Self.maximumSize - Self.reservedCorner) on the shorter. This character will "
                + "not be drawn — lower textSize()")
    }

    /// 焼いた画素が、字形自身の色を持っているか。
    ///
    /// 白で焼いた単色の字は**乗算済みで `RGB == A` が厳密に成立する**ので、崩れて
    /// いれば字形の側が色を持っている。書体の種別ではなく焼いた結果を見るので、
    /// 絵文字でも色つきの飾り字でも同じ 1 つの判定で足りる。
    private static func hasOwnColor(_ pixels: [SIMD4<Float16>]) -> Bool {
        // 8bit で 1 段ぶんより粗いずれだけを色と見る (焼きの誤差を色と取り違えない)
        let tolerance = Float16(1.0 / 512)
        return pixels.contains { texel in
            abs(texel.x - texel.w) > tolerance || abs(texel.y - texel.w) > tolerance
                || abs(texel.z - texel.w) > tolerance
        }
    }

    /// 面の中に場所を取る。棚を左から埋め、いっぱいになったら次の段へ。
    ///
    /// `rowLimit` は、字形の下端がここまでに収まる棚だけを使う (拡大した字形・``scaledPageShare``)。収まらないとき
    /// は、棚を進めずに諦める — 続く小さな字が、いまの棚の残りを使えるように。
    private func reserve(width: Int, height: Int, rowLimit: Int? = nil) -> (x: Int, y: Int)? {
        var x = cursorX
        var y = cursorY
        var row = rowHeight
        if x + width > size {
            x = 0
            y += row
            row = 0
        }
        guard y + height <= (rowLimit ?? size) else {
            if rowLimit == nil {
                cursorX = x
                cursorY = y
                rowHeight = row
            }
            return nil
        }
        cursorX = x + width
        cursorY = y
        rowHeight = max(row, height)
        return (x: x, y: y)
    }

    /// 字形 1 つを、作業空間の色の並びとして描く。
    ///
    /// **白で塗る。** 単色の字はこれで `RGB == A` になり、後から塗りの色を掛けると
    /// 覆いの面だったときと同じ値に戻る。色を持つ字形 (絵文字) は塗りの指定を無視して
    /// 自分の色を書き込むので、同じ 1 本の焼き方で両方が通る。
    ///
    /// 画素ごとの位置合わせと、画面の並びに合わせた平滑化は**切ってある**。入れると
    /// 同じ字が置き場所によって違う絵になり、焼いたものを使い回せなくなる。
    ///
    /// 描く道具の座標は下から上へ数えるが、**並びの先頭は絵の上端**なので、
    /// 面へはそのままの順で写る (``ImageFile/decode(at:name:)`` と同じ)。
    ///
    /// **墨の範囲を測る側 (``Typeface/drawnInk(of:_:)``) も、この描き方を読む** ([#2308])。
    /// 色を持つ字形 (絵文字) の墨は描いてみないと分からず、別の描き方で測ると
    /// `text()` の墨と食い違いうる。
    ///
    /// [#2308]: https://github.com/mokume-metal/mokume/issues/2308
    ///
    /// **`scale` は拡大の段の倍率** ([#2446])。書体の大きさの引数はそのままに、描く面を拡げて描くので、
    /// 字形の形 (光学サイズの選び) は変わらず、画素だけが細かくなる。`penX`・`penY` は拡げた後の画素。
    ///
    /// [#2446]: https://github.com/mokume-metal/mokume/issues/2446
    static func render(
        glyph: CGGlyph, font: CTFont, width: Int, height: Int, penX: Int, penY: Int,
        scale: CGFloat = 1
    ) -> [SIMD4<Float16>]? {
        var pixels = [SIMD4<Float16>](repeating: .zero, count: width * height)
        let stride = width * Self.bytesPerPixel
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            // 画像と同じ道具立て。色空間の変換は CoreGraphics が行う (ADR-0011 決定 3)
            guard let space = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3),
                let context = CGContext(
                    data: buffer.baseAddress, width: width, height: height,
                    bitsPerComponent: 16, bytesPerRow: stride, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                        | CGBitmapInfo.floatComponents.rawValue
                        | CGBitmapInfo.byteOrder16Little.rawValue)
            else { return false }

            context.setShouldAntialias(true)
            context.setAllowsFontSmoothing(false)
            context.setShouldSmoothFonts(false)
            context.setAllowsFontSubpixelPositioning(false)
            context.setShouldSubpixelPositionFonts(false)
            context.setAllowsFontSubpixelQuantization(false)
            context.setShouldSubpixelQuantizeFonts(false)
            context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)

            var index = glyph
            var position = CGPoint(x: CGFloat(penX), y: CGFloat(penY))
            if scale != 1 {
                context.scaleBy(x: scale, y: scale)
                position = CGPoint(x: position.x / scale, y: position.y / scale)
            }
            CTFontDrawGlyphs(font, &index, &position, 1, context)
            return true
        }
        return drawn ? pixels : nil
    }
}
