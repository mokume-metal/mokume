// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT
//
// 三角形の経路で、描く画素で 1 画素より細い名指しの基本図形の塗りを補う仕組み (#1934)。
//
// **説明文は置かない。** 正本は上の層 (ADR-0020 決定 4) で、api-surface.py の
// slash_doc は宣言の直前に積んだ `//` も説明文として拾う。この覚え書きが
// 拾われないよう、宣言との間は必ず 1 行空ける。

import simd

extension Canvas {

    /// 描く画素で 1 画素より細い塗りを補う片 1 つ ([#1934])。
    ///
    /// [#1934]: https://github.com/mokume-metal/mokume/issues/1934
    struct ThinFillPiece {
        /// 4 つの角 (形自身の座標)。凸の四角形で、最初の角からの扇 (三角形 2 枚) に割る。
        var corners: (SIMD2<Float>, SIMD2<Float>, SIMD2<Float>, SIMD2<Float>)
        /// 断片の後で掛ける被覆 (`ShapeFragmentIn.coverage`・#1637 と同じ口)。
        var coverage: Float
    }

    /// 細い塗りの雛形の置き場所 1 つが持つ記述の並び: ``Canvas/thinFillRecords`` の `first` から `count` 個
    /// ([#2208])。**並びは Shapes.metal の `ThinFillSpan` と一致していなければならない。**
    ///
    /// 置き場所の片は、記述の並びの順に数える — 片 `k` は、先頭の記述から順に片の数を引いていって、
    /// 引ききれなくなった記述の `k` 番目である。塗りは 1 つの記述 (`count` は 1) だが、1 つの置き場所が
    /// 複数の記述を持てる並びにしてあるのは、線 (#2172) が太さの違う区間ごとの記述を同じ置き場所に
    /// 並べて当てられるようにするため。口・列の引き方・頂点段の数え方はそのまま使え、増えるのは記述の
    /// 種別だけである。
    ///
    /// 置き場所の位置 (`anchor`) と変換の平行移動 (`translation`) も持つ — 記述は向きと寸法だけで決まり
    /// 位置を含まないので、位置が違うだけの置き場所は同じ記述を指せる。頂点段は周の中心へ `anchor` を
    /// 足してから角を出し、`translation` を最後に足して置く。CPU が畳まずに置くときと同じ順である。
    struct ThinFillSpan {
        var first: UInt32
        var count: UInt32
        var anchor: SIMD2<Float> = .zero
        var translation: SIMD2<Float> = .zero
    }

    /// 細い塗りの置き場所に添える、記述と置き場所の位置・平行移動 (``ThinFillSpan`` になる)。
    struct ThinFillPlacing {
        var record: ThinFillRecord
        var anchor: SIMD2<Float>
        var translation: SIMD2<Float>
    }

    /// 直前に求めた細い塗りの記述の控え。向きと寸法 (``Canvas/FlatForm``) と、描く画素へ写す 2x2 が
    /// 同じなら記述も同じ (記述は 2 つだけで決まる)。
    struct ThinFillMemo {
        var form: FlatForm
        var drawn: simd_float2x2
        var record: ThinFillRecord?
    }

    /// 細い塗りの片の**記述**。置き場所 1 つぶん ([#2208])。
    ///
    /// 片は、描く画素の空間の 2 つの基底 (`axis` と `across`) で表した帯の列で、`origin` から
    /// `span` を `divisor` 個に割った刻みで `pieces` 個並ぶ。片 `k` の角は、描く画素での
    /// `(u, v)` — `u` は刻みの端、`v` は `±side` — を `center + inverse (axis u + across (slope u + v))`
    /// で形自身の座標へ戻した点である。被覆は種別 (``Coverage``) が決める。
    ///
    /// **並びは Shapes.metal の `ThinFillRecord` と一致していなければならない**
    /// (`ShaderInterfaceTests` が反射と突き合わせる)。CPU で片を出す式 (``pieces()``) と頂点段の式は
    /// 同じ順の `fma` (積和の順を固定する) で、種別・倍精度の特異値・弦の積分は CPU が記述にして渡す。
    ///
    /// [#2208]: https://github.com/mokume-metal/mokume/issues/2208
    struct ThinFillRecord: Equatable {
        /// 被覆の決め方。
        enum Coverage {
            /// 全部の片が同じ被覆。
            case constant(Float)
            /// 細長い楕円: 片の中でいちばん太い弦から取る。
            case longEllipse(thin: Float, long: Float, width: Float)
            /// 片ごとの被覆の表 (長い向きが短い楕円。0 の片は置かない)。
            case table(SIMD16<Float>)
        }

        /// 描く画素から形自身の座標へ戻す 2x2 (列 2 本を並べる)。
        var inverse: SIMD4<Float>
        /// 形の中心 (xy) と、刻みの向き (zw・描く画素)。
        var centerAxis: SIMD4<Float>
        /// 帯の幅の向き (xy・描く画素)・弦の中点の傾き・帯の半幅 (``ThinFillRecord`` の `side`)。
        var acrossSlopeSide: SIMD4<Float>
        /// 刻みの始まり・刻み全体の長さ・割る数・片の数。
        var layout: SIMD4<Float>
        /// 被覆の種別 (0 一定・1 細長い楕円・2 表) と、種別ごとの値。
        var coverageMode: SIMD4<Float>
        /// 被覆の表 (種別 2 だけが読む)。
        var table0 = SIMD4<Float>(repeating: 0)
        var table1 = SIMD4<Float>(repeating: 0)
        var table2 = SIMD4<Float>(repeating: 0)

        init(
            inverse: simd_float2x2, center: SIMD2<Float>, axis: SIMD2<Float>, across: SIMD2<Float>,
            slope: Float, side: Float, origin: Float, span: Float, divisor: Float, pieces: Int,
            coverage: Coverage
        ) {
            self.inverse = SIMD4(
                inverse.columns.0.x, inverse.columns.0.y, inverse.columns.1.x, inverse.columns.1.y)
            centerAxis = SIMD4(center.x, center.y, axis.x, axis.y)
            acrossSlopeSide = SIMD4(across.x, across.y, slope, side)
            layout = SIMD4(origin, span, divisor, Float(pieces))
            switch coverage {
            case .constant(let value):
                coverageMode = SIMD4(0, value, 0, 0)
            case .longEllipse(let thin, let long, let width):
                coverageMode = SIMD4(1, thin, long, width)
            case .table(let table):
                coverageMode = SIMD4(2, 0, 0, 0)
                table0 = SIMD4(table[0], table[1], table[2], table[3])
                table1 = SIMD4(table[4], table[5], table[6], table[7])
                table2 = SIMD4(table[8], table[9], 0, 0)
            }
        }

        /// 描く画素 1 つの正方形 (中心 `center` のまわり・描く画素の軸に沿う)。被覆は描く画素での面積
        /// などで、呼ぶ側が渡す。
        static func unitSquare(
            around center: SIMD2<Float>, inverse: simd_float2x2, coverage: Float
        ) -> ThinFillRecord {
            ThinFillRecord(
                inverse: inverse, center: center, axis: SIMD2(1, 0), across: SIMD2(0, 1), slope: 0,
                side: 0.5, origin: -0.5, span: 1, divisor: 1, pieces: 1, coverage: .constant(coverage))
        }

        /// 片の数。
        var pieceCount: Int { Int(layout.w) }

        /// 記述の数がどれも有限か。**有限でない記述は置かない** — 頂点段へ渡すと、片の角が非数になって
        /// 面のどこにも出ない (か、画面の端まで伸びる)。片の端は `span × 片の番号 / 割る数` で出すので、
        /// 掛け算 (`span × 割る数`) があふれる記述も置かない。
        var isFinite: Bool {
            func finite(_ value: SIMD4<Float>) -> Bool { all((value - value) .== SIMD4<Float>(repeating: 0)) }
            return (layout.y * layout.z).isFinite && finite(inverse) && finite(centerAxis) && finite(acrossSlopeSide) && finite(layout)
                && finite(coverageMode) && finite(table0) && finite(table1) && finite(table2)
        }

        /// 雛形が持つ片の数の区間: 1・``shortCapacity``・16 と、そこから 8 刻みで上限の
        /// ``Canvas/thinEllipseSliceLimit`` まで (計 9 つ)。
        /// **置き場所の片の数が入る最小の区間を雛形の鍵に入れる。** 置き場所ごとに片の数が変わっても
        /// 同じ区間に収まる間は雛形を割らず、使わない片は頂点段が潰す。大きい区間の雛形は小さい区間の
        /// 置き場所も受ける (``Canvas/FlatKey/holds(_:)``) ので、割れるのは区間が上がるときだけである。区間が下がる・
        /// 同じ区間の置き場所は割れず、**区間が上がり続ける 1 つの並びの中なら高々 8 回**で済む (置き場所の
        /// 並びが途中で別の図形に変わって雛形を閉じれば、そこから数え直しになる)。
        /// 区間の目的は、小さい円や短い楕円を、いつも 64 片ぶん (384 頂点) の頂点関数で流さず、長い楕円も使わない片を 8 片未満に抑えること (頂点関数の費用が頂点数にほぼ比例するため)。
        static func capacity(forPieces count: Int) -> Int {
            if count <= 1 { return 1 }
            if count <= shortCapacity { return shortCapacity }
            if count <= 16 { return 16 }
            return min((count + 7) & ~7, Canvas.thinEllipseSliceLimit)
        }

        /// 長い向きが短い楕円 (``Canvas/thinFillShortSpan`` 未満) が使いうる片の数の上限。
        static let shortCapacity = Int(Canvas.thinFillShortSpan)

        /// 片 `k` の被覆。**置かない片は 0 以下** (表の 0・弦が 0 の端)。
        func coverage(of index: Int, from: Float, to: Float) -> Float {
            switch Int(coverageMode.x) {
            case 1:
                let (thin, long, width) = (coverageMode.y, coverageMode.z, coverageMode.w)
                // 片の中で、中心にいちばん近い位置の弦 (片の中でいちばん太い)
                let nearest = from <= 0 && to >= 0 ? 0 : min(abs(from), abs(to))
                let ratio = min(nearest / long, 1)
                let chord = thin * max(0, Float(1).addingProduct(-ratio, ratio)).squareRoot()
                return chord > 0 ? chord / width : 0
            case 2:
                switch index {
                case 0..<4: return table0[index]
                case 4..<8: return table1[index - 4]
                default: return table2[index - 8]
                }
            default:
                return coverageMode.y
            }
        }

        /// 片の角 (刻みの位置 `along`・帯の幅の向きの位置 `offset`) を形自身の座標で返す。
        /// **頂点段の式 (Shapes.metal の `mokume_thinFillCorner`) と同じ順の演算**: 積和は `fma` で固定し、
        /// 周の中心へ置き場所の位置 `anchor` を足してから、片の角を足す。
        func corner(anchor: SIMD2<Float>, along: Float, offset: Float) -> SIMD2<Float> {
            let center = SIMD2(centerAxis.x, centerAxis.y)
            let axis = SIMD2(centerAxis.z, centerAxis.w)
            let across = SIMD2(acrossSlopeSide.x, acrossSlopeSide.y)
            let slope = acrossSlopeSide.z
            let shift = offset.addingProduct(slope, along)
            let drawn = (axis * along).addingProduct(across, SIMD2(repeating: shift))
            let inverseX = SIMD2(inverse.x, inverse.y)
            let inverseY = SIMD2(inverse.z, inverse.w)
            let moved = (inverseX * drawn.x).addingProduct(inverseY, SIMD2(repeating: drawn.y))
            return (center + anchor) + moved
        }

        /// 記述から片を出す。**頂点段の式 (Shapes.metal の `mokume_thinFillCorner`) と同じ式。**
        /// 位置は記述の周の中心に含まれている (畳まずに置くときは、周を置き場所ぶんずらしてから記述を作る)。
        func pieces() -> [ThinFillPiece] {
            let side = acrossSlopeSide.w
            let (origin, span, divisor) = (layout.x, layout.y, layout.z)
            var result: [ThinFillPiece] = []
            result.reserveCapacity(pieceCount)
            func corner(_ along: Float, _ offset: Float) -> SIMD2<Float> {
                self.corner(anchor: .zero, along: along, offset: offset)
            }
            for index in 0..<pieceCount {
                let from = origin + span * Float(index) / divisor
                let to = origin + span * Float(index + 1) / divisor
                let cover = coverage(of: index, from: from, to: to)
                if coverageMode.x != 0, !(cover > 0) { continue }
                result.append(
                    ThinFillPiece(
                        corners: (corner(from, -side), corner(to, -side), corner(to, side), corner(from, side)),
                        coverage: cover))
            }
            return result
        }
    }

    /// 名指しの基本図形の塗りを、形自身の座標を描く画素へ写す 2x2 `linear` で置いたとき、描く画素で
    /// 1 画素より細い向きを持つなら、補う片 ([#1934])。**細くなければ `nil`** で、塗りはこれまで
    /// どおり周から三角形に割る。
    ///
    /// 三角形の経路の縁には AA が無い (ADR-0039 決定 3) ので、描く画素で 1 画素より細い帯は、
    /// 画素の中心を跨ぐかどうかで消えるか満濃度の 1 行になる。`fill(_:)` の説明 (「`rect` や
    /// `circle` で 1 画素より細く描いた塗りは、置く位置によらず面積に比例した濃さで出る」) は
    /// 経路を限らないので、距離関数の経路 (#1477) と同じ約束をここで守る。線の補い
    /// (``ThinStroke``・#1637) と同じく、**帯を広げ、細さの割合を被覆として断片の後で掛ける。**
    ///
    /// - **帯** (`rect` の片方の向きだけが細い): 細い向きを、**描く画素の軸に沿って列 (行) が
    ///   帯を切る長さ**がちょうど整数 n になるまで広げ、被覆を「元の切る長さ / n」にする。列ごとに
    ///   跨ぐ画素の中心がちょうど n 個になるので、光の量は帯の断面に比例する。線の補いのように
    ///   **線に垂直な太さ**を 1 にすると、45° の帯は列が切る長さが √2 になり、跨ぐ中心が 1 つか
    ///   2 つかを位相が決める — 向きが 45° ちょうどなら全部の列が揃い、置く位置で光の量が 1/√2 倍か
    ///   √2 倍に振れる (線の側は #2172)。垂直な太さが 1 未満なら切る長さは √2 未満なので、n は 1 か 2
    /// - **細長い楕円** (短軸だけが細い): 短軸を広げるだけでは、先端の弦が 1 より短いまま残る。
    ///   描く画素で長軸に沿って約 1 画素ごとの片に切り、片ごとに帯と同じ幅へ広げ、被覆を片の中で
    ///   いちばん太い弦から取る。距離関数の経路 (`mokume_thinEllipseCoverage`) が画素の中で中心に
    ///   いちばん近い位置の弦を取るのと同じ取り方である。長い直径が 10 画素ほどより短い楕円は、下の
    ///   「長い向きが短い形」の手当てに渡す
    /// - **小さい形** (どの向きも細い `rect`・長軸も細い楕円): 描く画素の軸に沿った描く画素 1 つの
    ///   正方形にし、被覆を描く画素での外接する箱の面積にする (円は直径の 2 乗・#1477 の判断 1 A。
    ///   線の点の補いと同じ形)
    /// - **補いが成り立たない `rect` は補わない** (#1934 の 2 回目の反証 1): 回した後に縦横で倍率の
    ///   違う拡大や剪断を掛けると、2 組の辺の隔たりがどちらも 1 を割ったまま、形は長い細い菱形に
    ///   なる。正方形にすると潰れ、帯にすると弦がもう一組の辺に縛られて暗くなり横へ伸びるので、
    ///   どの向きも細い `rect` は、描く画素での外接の箱が ``thinFillSmallReach`` 以内のときだけ
    ///   小さい形にする。帯も、弦の平らな所がある (端の辺の、列 (行) の向きの長さが長い辺より短い)
    ///   ときだけにする。それ以外は周から三角形に割る (直す前と同じ)
    /// - **長い向きが短い形** (列 (行) の向きの長さが ``thinFillShortSpan`` 未満): 上の 2 つでは、
    ///   長い向きの端が列の中心を跨ぐかどうかで、跨ぐ列の数が 1 つ振れる。長さ 1.5 の帯は 1 列か
    ///   2 列になり、光の量が倍まで振れる。そこで長い向きにも同じ手当てを当てる — 長さを整数の
    ///   列の数へ広げ、被覆で光の量を配る (矩形は 1 枚の片、楕円は列 1 つずつの片・``ShortProfile``)。
    ///   配る量は、距離関数の経路が長い向きを箱フィルタで数えた量を、置く位置についてならした値
    ///   である。`rect` ではちょうど面積になる。**楕円は「小さい形」との境目 (長い直径 1) で量が
    ///   2.4% 跳ぶ** — 1 未満は外接する箱 (いちばん太い弦 × 長い直径。距離関数の経路の小さい円と
    ///   同じ量) で、1 以上はならした量が箱の 0.976 倍になる (#1934 の 2 回目の反証 3)。小さい円の
    ///   約束 (外接する正方形の面積) を守るほうを取り、つなげない
    /// - **長い形** (``thinFillShortSpan`` 以上) は帯・片のまま描き、**置く位置による揺れが残る**
    ///   (#1934 の 2 回目の反証 2)。rect は端の列の数が 1 つ振れて 1 / 長さ、楕円は片の数が切り上げ
    ///   なので、列が切り捨てになる位置で中心の片の列が抜けて 4 / (π 長さ) ほど — 長さ 10 で 10%・
    ///   12.7% が上限である (実測は長さ 10.01〜11 で `shader()` 無しとの差が rect 9.8%・楕円 10.5%・
    ///   `longThinFillsStayWithinTheirBound`)。長い形まで長い向きの手当てを当てると、端の画素の
    ///   絵が動くので当てない
    ///
    /// 細さは ``roundedDrawnWeight(_:)`` で丸めてから 1 と比べる (線と同じ幅)。変換が潰れている
    /// (行列式 0) と補わない — 三角形のときも面積が無くて何も出ない。**寸法・中心が数でない・無限
    /// なら補わない** — 周から三角形に割るこれまでの塗りへ戻す (距離関数の経路も、有限でない半径の
    /// 形は置かずに断る・`appendForm(_:center:half:axis:arc:fills:cap:)`)。
    ///
    /// [#1934]: https://github.com/mokume-metal/mokume/issues/1934
    static func thinFillPieces(
        _ named: Outline.NamedFill, by linear: simd_float2x2
    ) -> [ThinFillPiece]? {
        thinFillRecord(named, by: linear)?.pieces()
    }

    /// ``thinFillPieces(_:by:)`` と同じ判定で、片を出す前の**記述**を返す。細くなければ `nil`。
    ///
    /// 片は記述から決まる (``ThinFillRecord/pieces()``)。畳んだ雛形は片を頂点にせず、この記述を置き場所
    /// ごとに GPU へ渡して頂点段が同じ式で片を出す (#2208)。判定と、倍精度の特異値・弦の積分は CPU に
    /// 残る — 頂点段へ移るのは、記述から頂点を出す足し算と掛け算だけである。
    static func thinFillRecord(
        _ named: Outline.NamedFill, by linear: simd_float2x2
    ) -> ThinFillRecord? {
        let determinant = simd_determinant(linear)
        guard determinant != 0, determinant.isFinite, isFinite(named) else { return nil }
        let record =
            named.isEllipse
            ? thinEllipseRecord(named, by: linear) : thinRectRecord(named, by: linear)
        // 極端な寸法や変換で、広げた帯の長さや逆行列があふれた記述は置かない (周から三角形に割る)
        guard let record, record.isFinite else { return nil }
        return record
    }

    /// 置き場所 `form` の細い塗りの記述。**向きと寸法が同じ置き場所が続く間は、直前の記述を使い回す** —
    /// 記述を求めるには倍精度の特異値と弦の積分 (短い楕円は `pow` と `asin` を最大 22 回) が要り、畳める
    /// 場面の置き場所ごとの費用の大半だった (#2208)。細くなければ `nil`。
    func thinFillRecord(of form: FlatForm, drawn: simd_float2x2) -> ThinFillRecord? {
        if let memo = thinFillMemo, memo.form == form, memo.drawn == drawn { return memo.record }
        thinFillRecordsBuilt += 1
        // `Optional.flatMap` に閉包を渡さない — 置き場所ごとに隔離の実行時検査を払う (#1779)
        var record: ThinFillRecord?
        if let named = form.namedFill { record = Self.thinFillRecord(named, by: drawn) }
        thinFillMemo = ThinFillMemo(form: form, drawn: drawn, record: record)
        return record
    }

    /// 置き場所の記述を 1 つ足す。**置き場所ごとに 1 度**呼ぶ (先頭と数は、足した記述から決まる)。
    ///
    /// **直前に足した記述と同じなら、記述は足さずに同じものを指す** — 向きと寸法が同じ置き場所が続く
    /// 場面では、記述が 1 つで済み (CPU の書き込みと GPU の読み出しが減る)、先頭と数の並びだけが伸びる。
    func addThinFill(_ placing: ThinFillPlacing) {
        if let last = lastThinFillRecord, thinFillRecords[last] == placing.record {
            thinFillSpans.append(
                ThinFillSpan(
                    first: UInt32(last), count: 1, anchor: placing.anchor,
                    translation: placing.translation))
            return
        }
        lastThinFillRecord = thinFillRecords.count
        thinFillSpans.append(
            ThinFillSpan(
                first: UInt32(thinFillRecords.count), count: 1, anchor: placing.anchor,
                translation: placing.translation))
        thinFillRecords.append(placing.record)
    }

    /// 長い向きが短いとみなす、列 (行) の向きの長さの上限 (描く画素)。これ以上長い形は長い向きの
    /// 手当てを当てず、置く位置による揺れが rect で 1 / 長さ、楕円で 4 / (π 長さ) ほど残る (長さ 10 で
    /// 10%・12.7%・#1934 の反証 2 と 2 回目の反証 2)。
    static let thinFillShortSpan: Float = 10

    /// 寸法と中心がどれも有限か。
    private static func isFinite(_ named: Outline.NamedFill) -> Bool {
        named.half.x.isFinite && named.half.y.isFinite && named.center.x.isFinite
            && named.center.y.isFinite
    }

    /// 名指しの基本図形の塗りが、2x2 `linear` で置いて描く画素で 1 画素より細い向きを持つか
    /// (``thinFillPieces(_:by:)`` が片を返すのと同じ判定)。片を組まずに答える — 畳みの鍵は置き場所
    /// ごとに求める (``thinFillLinear(_:)``)。
    static func isThinFill(_ named: Outline.NamedFill, by linear: simd_float2x2) -> Bool {
        let determinant = simd_determinant(linear)
        guard determinant != 0, determinant.isFinite, isFinite(named) else { return false }
        if named.isEllipse {
            return roundedDrawnWeight(2 * principalAxes(ellipseLinear(named, linear)).short) < 1
        }
        return rectPlan(named, by: linear) != nil
    }

    /// どの向きも細い `rect` を小さい形 (描く画素 1 つの正方形) とみなす、描く画素での外接の箱の
    /// 大きさの上限。回した描く画素 1 つの正方形 (√2) が入る大きさで、これより長い形を正方形に
    /// 潰さない (#1934 の 2 回目の反証 1)。
    static let thinFillSmallReach: Float = 1.5

    // MARK: - 矩形

    /// 矩形の、描く画素での 2 組の辺の隔たり (辺に垂直に測る・丸めた値) と、描く画素での面積。
    ///
    /// 上下の辺 (形自身の x の向き) の隔たりは、面積を辺の長さで割った `高さ × |det| / |D·x|`
    /// (線の ``drawnWeight(_:along:by:)`` と同じ量)。
    ///
    /// **この隔たりは辺に垂直に測る (行ノルム相当) ので、距離関数の経路の細い枝の境目
    /// (`reachPerPixel`・#2991) とは、直線の縁では 45° で √2 食い違う** — 距離関数の経路は、帯の両縁が 1 つの
    /// 画素に入るかを、画素の正方形を法線へ射影した幅 (行の絶対値の和・45° で行ノルムの √2 倍) で決める (縁の被覆を
    /// 面積で数えるため)。**三角形の経路は、これに揃えない** (線の ``drawnWeight(_:along:by:)`` と同じ理由)。
    /// 縁に AA が無く (ADR-0039 決定 3)、補う目的は「列 (行) ごとに画素の中心を少なくとも 1 つ跨がせる」ことで、
    /// 45° の帯は水平の断面が √2 倍なので、辺に垂直な隔たり 1 で足りる。法線向きの幅で補うと帯がさらに太くなり、
    /// 片の数・被覆の掛け方・既存の検査の前提が動く。食い違いの帰結は、描く画素での隔たりが 1〜1.41 の斜めの
    /// 細い塗りが、距離関数の経路では細い枝で面積に比例した濃さになり、三角形の経路では補わず中心を数えた濃さ
    /// (平均では面積に等しい) になること。
    private static func drawnRectSpans(
        _ named: Outline.NamedFill, by linear: simd_float2x2
    ) -> (height: Float, width: Float, area: Float) {
        let area = abs(simd_determinant(linear))
        let height = roundedDrawnWeight(2 * named.half.y * area / simd_length(linear.columns.0))
        let width = roundedDrawnWeight(2 * named.half.x * area / simd_length(linear.columns.1))
        return (height, width, 4 * named.half.x * named.half.y * area)
    }

    /// 細い `rect` の補い方。
    private enum RectPlan {
        /// 小さい形: 描く画素 1 つの正方形。被覆は描く画素での面積。
        case square(coverage: Float)
        /// 帯: 1 組の辺の隔たり `span` だけが細い。`edge` は長い辺、`endAlong` は端の辺が列 (行) の
        /// 向きにどれだけ伸びるか (描く画素)。
        case band(widensHeight: Bool, span: Float, edge: SIMD2<Float>, endAlong: Float, area: Float)
    }

    /// 細い `rect` を、補いが成り立つ形のときだけどう補うか。細くないか、補いが成り立たない形
    /// (``thinFillPieces(_:by:)`` の「補いが成り立たない `rect`」) なら `nil`。
    ///
    /// 2 本の辺は実際に描く画素へ写して測る: 形自身の x の向きの辺 `across` と y の向きの辺 `down`。
    private static func rectPlan(
        _ named: Outline.NamedFill, by linear: simd_float2x2
    ) -> RectPlan? {
        let span = drawnRectSpans(named, by: linear)
        guard span.height < 1 || span.width < 1 else { return nil }
        let across = linear.columns.0 * (2 * named.half.x)
        let down = linear.columns.1 * (2 * named.half.y)
        if span.height < 1, span.width < 1 {
            // どの向きも細い: 外接の箱が小さく、面積も描く画素 1 つに満たないときだけ正方形にする
            let box = abs(across) + abs(down)
            guard box.x <= thinFillSmallReach, box.y <= thinFillSmallReach, span.area < 1
            else { return nil }
            return .square(coverage: span.area)
        }
        // 1 組だけが細い: 上下の辺が細いなら形自身の x の向きの辺が長い辺
        let widensHeight = span.height < 1
        let edge = widensHeight ? across : down
        let end = widensHeight ? down : across
        let byRows = abs(edge.y) > abs(edge.x)
        let edgeAlong = byRows ? abs(edge.y) : abs(edge.x)
        let endAlong = byRows ? abs(end.y) : abs(end.x)
        // 弦の平らな所が無い (端の辺のほうが列の向きに長い) 形は、弦が端の辺に縛られる
        guard endAlong < edgeAlong else { return nil }
        return .band(
            widensHeight: widensHeight, span: widensHeight ? span.height : span.width, edge: edge,
            endAlong: endAlong, area: span.area)
    }

    private static func thinRectRecord(
        _ named: Outline.NamedFill, by linear: simd_float2x2
    ) -> ThinFillRecord? {
        guard let plan = rectPlan(named, by: linear) else { return nil }
        let (widensHeight, thinSpan, edge, endAlong, area): (Bool, Float, SIMD2<Float>, Float, Float)
        switch plan {
        case .square(let coverage):
            return .unitSquare(around: named.center, inverse: linear.inverse, coverage: coverage)
        case .band(let widens, let span, let longEdge, let along, let drawnArea):
            (widensHeight, thinSpan, edge, endAlong, area) = (widens, span, longEdge, along, drawnArea)
        }
        // 長い向きが短い形の手当ては、端の辺が 1 列に収まるときだけ (剪断で端が長く伸びた形は、
        // 長さを長い辺だけで数えると形が縮む)。収まらなければ帯のまま広げる
        if endAlong <= 1, let profile = ShortProfile(rectEdge: edge, area: area) {
            return shortRecord(profile, center: named.center, inverse: linear.inverse)
        }
        var half = named.half
        let band = widenedBand(thinSpan, along: simd_normalize(edge))
        let coverage = band.coverage
        if widensHeight {
            half.y *= band.widen
        } else {
            half.x *= band.widen
        }
        // 帯は形自身の座標の箱 (中心 ± 半幅・半高) なので、描く画素への写しは恒等にして記述する
        return ThinFillRecord(
            inverse: matrix_identity_float2x2, center: named.center, axis: SIMD2(1, 0),
            across: SIMD2(0, 1), slope: 0, side: half.y, origin: -half.x, span: 2 * half.x,
            divisor: 1, pieces: 1, coverage: .constant(coverage))
    }

    /// 辺に垂直な隔たり `span` (描く画素・1 未満) の帯を、向き `direction` (描く画素・長さ 1) に
    /// 沿って広げる倍率と被覆。**列 (行) が帯を切る長さを整数 n にする** (``thinFillPieces(_:by:)``)。
    ///
    /// 帯が横寄り (|x| ≥ |y|) なら列が、縦寄りなら行が帯を切る。切る長さは `span` を、帯の向きの
    /// 大きいほうの成分で割ったものになる。
    private static func widenedBand(
        _ span: Float, along direction: SIMD2<Float>
    ) -> (widen: Float, coverage: Float) {
        let axis = max(abs(direction.x), abs(direction.y))
        let crossings: Float = span / axis <= 1 ? 1 : 2
        let target = crossings * axis
        return (target / span, span / target)
    }

    // MARK: - 楕円

    /// 細長い楕円を長軸に沿って切る片の数の上限。片は長軸に沿ってほぼ 1 画素ずつだが、長い楕円は
    /// ここで止め、片を長くする。
    ///
    /// 片を長くすると、片の中のいちばん太い弦を取るぶんの多め (片の数 K に対して 4 / (πK) ほど) が
    /// 変わり、被覆が片ごとの段になる。64 なら多めは 2% に収まる。距離関数の経路の細い楕円も、長さ L
    /// に対して 4 / (πL) ほど多めに出る。**置く位置による揺れ (4 / (πL) ほど・``thinFillShortSpan``)
    /// は、片の数を変えても消えない** — どの列もちょうど 1 つの片に入るが、片が受け持つ列の数が置く
    /// 位置で 1 つ振れる (#1934 の 2 回目の反証 2)。上限を 1024 にしていた頃は、
    /// 400×0.5 の楕円 1 つが 2,400 頂点になり、200 個の組み立てが周から割るときの 6.4 倍かかった
    /// (#1934 の反証 8)。64 なら 384 頂点 (周から割ると 189) である。
    static let thinEllipseSliceLimit = 64

    /// 単位円を描く画素の楕円へ写す 2x2 (形自身の座標の半径を掛けたもの)。
    private static func ellipseLinear(
        _ named: Outline.NamedFill, _ linear: simd_float2x2
    ) -> simd_float2x2 {
        simd_float2x2(linear.columns.0 * named.half.x, linear.columns.1 * named.half.y)
    }

    private static func thinEllipseRecord(
        _ named: Outline.NamedFill, by linear: simd_float2x2
    ) -> ThinFillRecord? {
        let shape = ellipseLinear(named, linear)
        let axes = principalAxes(shape)
        // 半径が単精度で無限へあふれた楕円も補わない (片の数を整数へ直せない)
        guard axes.long.isFinite, axes.short.isFinite,
            roundedDrawnWeight(2 * axes.short) < 1
        else { return nil }
        let inverse = linear.inverse
        // 長軸も細い楕円 (1 画素より小さい円を含む) は、描く画素 1 つの正方形にする。被覆は描く
        // 画素での外接する箱の面積 (2 つの半径の積の 4 倍)
        if roundedDrawnWeight(2 * axes.long) < 1 {
            return .unitSquare(
                around: named.center, inverse: inverse, coverage: 4 * axes.long * axes.short)
        }
        if let profile = ShortProfile(ellipse: shape, longAxis: axes.direction) {
            return shortRecord(profile, center: named.center, inverse: inverse)
        }
        let along = axes.direction
        let across = SIMD2(-along.y, along.x)
        let thin = 2 * axes.short
        let width = thin * widenedBand(thin, along: along).widen
        let long = axes.long
        // 片の数は、上限で切ってから整数へ直す (巨大な直径を `Int` へ直すと実行時に落ちる)
        let span = 2 * long
        guard span.isFinite else { return nil }
        let count =
            span >= Float(thinEllipseSliceLimit)
            ? thinEllipseSliceLimit : max(1, Int(span.rounded(.up)))
        return ThinFillRecord(
            inverse: inverse, center: named.center, axis: along, across: across, slope: 0,
            side: width / 2, origin: -long, span: span, divisor: Float(count), pieces: count,
            coverage: .longEllipse(thin: thin, long: long, width: width))
    }

    /// 2x2 `m` が単位円を写した楕円の、長い半径・短い半径と、長軸の向き (長さ 1)。
    ///
    /// 半径は特異値で、``smallestSingularValue(of:)`` と同じく倍精度で、2 乗の差を引かない形で
    /// 解く。向きは `m mᵀ` の大きいほうの固有値の固有ベクトル。円に近くて向きが決まらないときは
    /// 描く画素の x の向きにする (細長い楕円の片にだけ使い、円は正方形の側へ行くので効かない)。
    private static func principalAxes(
        _ m: simd_float2x2
    ) -> (long: Float, short: Float, direction: SIMD2<Float>) {
        let a = Double(m.columns.0.x)
        let b = Double(m.columns.0.y)
        let c = Double(m.columns.1.x)
        let d = Double(m.columns.1.y)
        let trace = a * a + b * b + c * c + d * d
        let area = abs(a * d - b * c)
        let largest = ((trace + 2 * area).squareRoot() + max(trace - 2 * area, 0).squareRoot()) / 2
        let smallest = largest > 0 ? area / largest : 0
        // m mᵀ = [[p, q], [q, r]] の固有値 largest² の固有ベクトル
        let p = a * a + c * c
        let q = a * b + c * d
        let r = b * b + d * d
        let lambda = largest * largest
        let first = SIMD2(q, lambda - p)
        let second = SIMD2(lambda - r, q)
        let chosen = simd_length_squared(first) >= simd_length_squared(second) ? first : second
        let length = simd_length(chosen)
        let direction =
            length > 0 && length.isFinite
            ? SIMD2<Float>(Float(chosen.x / length), Float(chosen.y / length)) : SIMD2<Float>(1, 0)
        return (Float(largest), Float(smallest), direction)
    }

    // MARK: - 長い向きが短い形

    /// 長い向きが短い細い形の、列 (行) ごとの弦 (#1934 の反証 2・``thinFillPieces(_:by:)``)。
    ///
    /// 描く画素で形の中心を原点に、**長い向きの座標 `s`** で表す。帯が横寄りなら列が形を切り、
    /// `s` は描く画素の x で、弦は縦に測る。縦寄りなら行が切り、`s` は y で、弦は横に測る。
    /// 弦の中点は 1 本の直線に並ぶ (矩形は帯の中心線、楕円は縦 (横) の弦を二等分する直径)。
    struct ShortProfile {
        /// 行が形を切るか (偽なら列が切る)。
        var byRows: Bool
        /// 長い向きの長さの半分 (描く画素)。`s` は −half…half。
        var half: Float
        /// `s = 0` での弦の長さ (描く画素)。
        var peak: Float
        /// 楕円か。楕円なら弦は `peak × √(1 − (s / half)²)`、矩形なら一定。
        var isEllipse: Bool
        /// 弦の中点の並ぶ線の傾き。`s` が 1 進むと、中点が弦の向きに `slope` 動く。
        var slope: Float

        /// 矩形の長い辺 `edge` (描く画素) と描く画素での面積から。長い向きが短くなければ `nil`。
        init?(rectEdge edge: SIMD2<Float>, area: Float) {
            byRows = abs(edge.y) > abs(edge.x)
            let along = byRows ? edge.y : edge.x
            half = abs(along) / 2
            guard half > 0, 2 * half < Canvas.thinFillShortSpan else { return nil }
            peak = area / (2 * half)
            isEllipse = false
            slope = (byRows ? edge.x : edge.y) / along
        }

        /// 単位円を描く画素の楕円へ写す 2x2 `shape` と、その長軸の向きから。長い向きが短くなければ
        /// `nil`。楕円を `S = shape · shapeᵀ` で表すと、x の幅の半分は `√S_xx`、中心を通る縦の弦は
        /// `2 |det| / √S_xx`、縦の弦の中点は `y = (S_xy / S_xx) x` に並ぶ (行が切るなら x と y を入れ替える)。
        init?(ellipse shape: simd_float2x2, longAxis: SIMD2<Float>) {
            let c0 = SIMD2<Double>(Double(shape.columns.0.x), Double(shape.columns.0.y))
            let c1 = SIMD2<Double>(Double(shape.columns.1.x), Double(shape.columns.1.y))
            let sxx = c0.x * c0.x + c1.x * c1.x
            let sxy = c0.x * c0.y + c1.x * c1.y
            let syy = c0.y * c0.y + c1.y * c1.y
            let area = abs(c0.x * c1.y - c0.y * c1.x)
            byRows = abs(longAxis.y) > abs(longAxis.x)
            let along = byRows ? syy : sxx
            let extent = along.squareRoot()
            guard extent > 0, (2 * extent).isFinite, 2 * extent < Double(Canvas.thinFillShortSpan)
            else { return nil }
            half = Float(extent)
            peak = Float(2 * area / extent)
            isEllipse = true
            slope = Float(sxy / along)
        }

        /// 弦の、`s` から `t` までの積分 (どちらも −half…half)。
        func integral(_ s: Float, _ t: Float) -> Float {
            guard isEllipse else { return peak * (t - s) }
            return peak * (unitArea(t) - unitArea(s))
        }

        /// `∫₀^s √(1 − (v / half)²) dv`
        private func unitArea(_ s: Float) -> Float {
            let r = min(max(s / half, -1), 1)
            return half / 2 * (r * max(0, 1 - r * r).squareRoot() + RuntimeMath.asin(r))
        }

        /// 列の位置を一様に動かしてならした、**列ごとの「列の中でいちばん太い弦 × 列と形が重なる
        /// 長さ」の和**。距離関数の経路が、長い向きを箱フィルタで、細い向きを画素の中で中心に
        /// いちばん近い位置の弦で数えた量 (`mokume_thinEllipseCoverage`) の、置く位置についての平均で
        /// ある。矩形では弦が一定なので、ちょうど面積になる。
        ///
        /// 列 [u, u + 1] を動かして積分する。中心を含む列は弦が `peak` で、重なりの積分は
        /// `half ≥ 1` なら 1、そうでなければ `2 half − half²`。中心の片側にある列は、中心にいちばん
        /// 近い端 (中心から v) の弦を取り、重なりは `min(1, half − v)` なので、
        /// `∫₀^half f(v) · min(1, half − v) dv`。両側で 2 倍する。
        ///
        /// 楕円の `half = 0.5` (長い直径 1) では `peak` の 0.976 倍で、長い直径 1 未満の「小さい形」の
        /// 外接する箱 (`peak` × 1) とは 2.4% 食い違う (``Canvas/thinFillPieces(_:by:)``)。
        var averagedLight: Float {
            guard isEllipse else { return peak * 2 * half }
            let x = half
            let middle = peak * (x >= 1 ? 1 : 2 * x - x * x)
            let knee = max(0, x - 1)
            // v f(v) の原始関数: −peak (x² / 3) (1 − v² / x²)^(3/2)
            func moment(_ v: Float) -> Float {
                let r = v / x
                return -peak * x * x / 3 * RuntimeMath.pow(max(0, 1 - r * r), 1.5)
            }
            let side = integral(0, knee) + x * integral(knee, x) - (moment(x) - moment(knee))
            return middle + 2 * side
        }
    }

    /// 長い向きが短い形を、**長い向きに整数の列 (行) の数ぶんの片**にする (#1934 の反証 2)。
    ///
    /// 長さを切り上げた整数 m 列ぶんの幅を、形の中心のまわりに置く。片の端は列の境目と平行 (列が
    /// 切るなら縦) なので、置く位置によらず列の中心をちょうど m 個含む。弦の向きには、弦の中点の線の
    /// まわりにちょうど n 行 (1 か 2) の高さに広げる。光の量 (``ShortProfile/averagedLight``) を
    /// 列に配り、被覆を「列 1 つに配った量 / n」にする。どれも置く位置に依らないので、畳みの雛形と
    /// 保持した形の控えにも使える。
    ///
    /// **矩形は m 列を 1 枚の片にする** — 弦が一定なので、どの列にも同じ量を配ればよい。楕円は列
    /// 1 つずつの片に切り、片の中の弦の積分の割合で配る (列ごとの被覆は記述の表に入れる)。
    private static func shortRecord(
        _ profile: ShortProfile, center: SIMD2<Float>, inverse: simd_float2x2
    ) -> ThinFillRecord {
        let count = max(1, Int((2 * profile.half).rounded(.up)))
        let light = profile.averagedLight
        let left = -Float(count) / 2
        let axis: SIMD2<Float> = profile.byRows ? SIMD2(0, 1) : SIMD2(1, 0)
        let across: SIMD2<Float> = profile.byRows ? SIMD2(1, 0) : SIMD2(0, 1)
        guard profile.isEllipse else {
            // 矩形: (始まり, 終わり) = (left, -left) の 1 枚。列 1 つに配る量は light / count
            let share = light / Float(count)
            let crossings: Float = share <= 1 ? 1 : 2
            return ThinFillRecord(
                inverse: inverse, center: center, axis: axis, across: across, slope: profile.slope,
                side: crossings / 2, origin: left, span: Float(count), divisor: 1, pieces: 1,
                coverage: .constant(share / crossings))
        }
        // 楕円は列 1 つずつの片。配る量が 0 の列は片を置かない (表の 0 が潰す)
        let whole = profile.integral(-profile.half, profile.half)
        var shares = SIMD16<Float>(repeating: 0)
        var largest: Float = 0
        for index in 0..<count {
            let from = left + Float(index)
            let low = max(from, -profile.half)
            let high = min(from + 1, profile.half)
            let share = high > low && whole > 0 ? light * profile.integral(low, high) / whole : 0
            if share > 0 {
                shares[index] = share
                largest = max(largest, share)
            }
        }
        let crossings: Float = largest <= 1 ? 1 : 2
        var table = SIMD16<Float>(repeating: 0)
        for index in 0..<count where shares[index] > 0 { table[index] = shares[index] / crossings }
        return ThinFillRecord(
            inverse: inverse, center: center, axis: axis, across: across, slope: profile.slope,
            side: crossings / 2, origin: left, span: 1, divisor: 1, pieces: count,
            coverage: .table(table))
    }

    // MARK: - 積む

    /// 細い塗りの片を積み、片ごとの被覆を付ける (``noteCoverage(_:in:)``)。色と変換はいまのもので、
    /// 塗りを周から積むとき (``fillInterior(_:thinFillMatrix:)``) と同じ。
    ///
    /// **貼る絵の読み取り位置は、元の周の囲みの箱から取り、箱の外へ広げた角は箱の縁へ寄せる**
    /// (``clampedUV(_:)``)。広げた帯にも絵の全体が載り、帯の中ほどの画素は元の帯と同じ所を読む。
    func fillThin(_ pieces: [ThinFillPiece], outline: Outline) {
        let uvOf = style.picture == nil ? nil : Self.boxUV(of: outline.points)
        let fillColor = fillVertexColor
        let colors = (fillColor, fillColor, fillColor)
        for piece in pieces {
            let start = vertices.count
            let (a, b, c, d) = piece.corners
            let placedA = transform.placed(x: a.x, y: a.y)
            let placedB = transform.placed(x: b.x, y: b.y)
            let placedC = transform.placed(x: c.x, y: c.y)
            let placedD = transform.placed(x: d.x, y: d.y)
            var first: (SIMD2<Float>, SIMD2<Float>, SIMD2<Float>)?
            var second: (SIMD2<Float>, SIMD2<Float>, SIMD2<Float>)?
            if let uvOf {
                let (uvA, uvB, uvC, uvD) = (
                    Self.clampedUV(uvOf(a)), Self.clampedUV(uvOf(b)), Self.clampedUV(uvOf(c)),
                    Self.clampedUV(uvOf(d))
                )
                first = (uvA, uvB, uvC)
                second = (uvA, uvC, uvD)
            }
            appendTriangle(placedA, placedB, placedC, colors: colors, uvs: first)
            appendTriangle(placedA, placedC, placedD, colors: colors, uvs: second)
            noteCoverage(piece.coverage, in: start..<vertices.count)
        }
    }

    /// 細い塗りの畳んだ雛形の頂点を積む (#2208)。**片は組まない** — 頂点は「片の番号と角の番号」だけを
    /// `position` に持ち、置き場所ごとの記述 (``ThinFillRecord``) から頂点関数が片の角を出す。
    /// `capacity` 個の片ぶん (片 1 つが三角形 2 枚 = 6 頂点) を積み、使わない片は頂点関数が潰す。
    ///
    /// 貼る絵があるときの読み取り位置は、周の囲みの箱から頂点関数が作る (``FlatFrame/thinFillUV``)。
    /// その箱を返す (絵が無ければ `nil`)。
    func fillThinTemplate(capacity: Int, outline: Outline) -> SIMD4<Float>? {
        guard canPlace else {
            warnOutsideFrame(.placing)
            return nil
        }
        // appendTriangle と同じ手順で、読む面を決める
        beginFlat()
        let hasPicture = style.picture != nil
        if hasPicture { useWrittenUVTexture() } else { useGlyphTexture() }
        let fillColor = fillVertexColor
        let uv = whiteUV
        vertices.reserveCapacity(vertices.count + capacity * 6)
        for piece in 0..<capacity {
            // 三角形 2 枚: (a, b, c) と (a, c, d)
            for corner in [0, 1, 2, 0, 2, 3] {
                vertices.append(
                    ShapeVertex(
                        position: SIMD2(Float(piece), Float(corner)), uv: uv, color: fillColor))
            }
        }
        // 広げた片の被覆は 1 未満になりうるので、置き換える列は下地を読む断片で描く (#1637)
        openBatchHasThinCoverage = true
        guard hasPicture else { return nil }
        return Self.uvBounds(of: outline.points)
    }

    /// 読み取り位置を 0…1 の箱に収める。
    static func clampedUV(_ uv: SIMD2<Float>) -> SIMD2<Float> {
        simd_clamp(uv, SIMD2<Float>(0, 0), SIMD2<Float>(1, 1))
    }

    // MARK: - 畳み

    /// いまの変換で、名指しの基本図形 `form` の塗りが描く画素 1 画素より細くなるなら、その変換の
    /// 2x2 (#1934)。畳みの鍵 (``FlatKey/fillLinear``) に入る。**鍵は 2x2 そのもの** — 広げ方が帯の
    /// 向きで決まるので、線 (``rotationFreeKey(_:)``) と違って回転だけが違う置き場所も別の雛形になる。
    /// 塗りを持たない図形・扇・細くならない塗りは `nil` で、これまでどおり変換の違う置き場所も
    /// 同じ雛形に畳む。**広げ方を頂点段へ移した畳み (#2208) は使わない** — 検査が CPU の組み直しと
    /// 画素を比べるために残した形 (``expandsThinFillsInVertexStage`` が偽のとき)。
    func thinFillLinear(_ form: FlatForm) -> ThinFold? {
        guard style.hasFill, let named = form.namedFill else { return nil }
        let matrix = transform.matrix
        guard Self.isThinFill(named, by: drawnLinear(matrix)) else { return nil }
        let linear = SIMD4(
            matrix.columns.0.x, matrix.columns.0.y, matrix.columns.1.x, matrix.columns.1.y)
        return ThinFold(key: linear, linear: linear)
    }

    // MARK: - 保持した形

    /// 保持した形の名指しの基本図形の塗りを、置いた後に細ければ広げて組み直した頂点と被覆の区間
    /// (#1934)。**細くならなければ `nil`** で、呼ぶ側は記録した頂点 (か、刻み直した頂点) を置く。
    ///
    /// 頂点は記録した頂点と同じ座標 (形自身の座標に記録のときの変換を掛けたもの) で返すので、呼ぶ側は
    /// 記録した頂点と同じく置き場所の行列と色を掛ける。**組み直しは描く画素へ写す 2x2 ごとに 1 度
    /// だけ** — 同じ大きさ・同じ向きで置き続ける形は、控えた頂点を移すだけで済む (``ThinStrokeCache``)。
    func thinFillVertices(
        _ recipe: RingFillRecipe, placedBy matrix: simd_float4x4, cache: ThinStrokeCache, fill: Int
    ) -> (vertices: [ShapeVertex], coverage: [CoverageSpan])? {
        guard let named = recipe.outline.namedFill else { return nil }
        let linear = drawnLinear(matrix * recipe.transform.matrix)
        let key = SIMD4(linear.columns.0.x, linear.columns.0.y, linear.columns.1.x, linear.columns.1.y)
        if let cached = cache.thinFill(fill, key) { return cached }
        var built: (vertices: [ShapeVertex], coverage: [CoverageSpan])?
        if let pieces = Self.thinFillPieces(named, by: linear) {
            built = Self.thinFillVertices(pieces, recipe: recipe)
        }
        cache.rememberThinFill(built, fill, key)
        return built
    }

    /// 片を、記録した頂点と同じ座標・色・読み取り位置の頂点にする (``fillThin(_:outline:)`` と
    /// 同じ割り方)。
    ///
    /// 読み取り位置の箱は、周の点を持つ素材 (楕円) なら周から、持たない素材 (矩形・記録のときに
    /// 周を落とす) なら形の箱 (中心 ± 半幅・半高 = 矩形の周の囲みの箱) から作る。
    static func thinFillVertices(
        _ pieces: [ThinFillPiece], recipe: RingFillRecipe
    ) -> (vertices: [ShapeVertex], coverage: [CoverageSpan]) {
        var box = recipe.outline.points
        if box.isEmpty, let named = recipe.outline.namedFill {
            box = [named.center - named.half, named.center + named.half]
        }
        let uvOf = recipe.hasPicture ? boxUV(of: box) : nil
        var vertices: [ShapeVertex] = []
        vertices.reserveCapacity(pieces.count * 6)
        var spans: [CoverageSpan] = []
        for piece in pieces {
            let start = vertices.count
            let (a, b, c, d) = piece.corners
            for corner in [a, b, c, a, c, d] {
                var uv = recipe.uv
                if let uvOf { uv = clampedUV(uvOf(corner)) }
                vertices.append(
                    ShapeVertex(
                        position: recipe.transform.placed(x: corner.x, y: corner.y), uv: uv,
                        color: recipe.color))
            }
            CoverageSpan.note(piece.coverage, in: start..<vertices.count, to: &spans)
        }
        return (vertices, spans)
    }
}

extension Canvas.FlatForm {
    /// `fill(_:)` の説明が名指す基本図形なら、その塗りの形。**周の閉包が作る周
    /// (``Canvas/Outline/namedFill``) と同じ値** — 畳みの鍵はこちらで細さを測り、雛形は周の側で
    /// 広げる。扇 (一周でない弧) は `nil`。
    var namedFill: Canvas.Outline.NamedFill? {
        switch self {
        case .rect(let width, let height):
            Canvas.Outline.NamedFill(
                isEllipse: false, center: SIMD2(width / 2, height / 2),
                half: SIMD2(width / 2, height / 2))
        case .ellipse(let radiusX, let radiusY):
            Canvas.Outline.NamedFill(
                isEllipse: true, center: SIMD2(0, 0), half: SIMD2(radiusX, radiusY))
        case .arc(let radiusX, let radiusY, _, let sweep):
            sweep >= 2 * .pi
                ? Canvas.Outline.NamedFill(
                    isEllipse: true, center: SIMD2(0, 0), half: SIMD2(radiusX, radiusY))
                : nil
        }
    }
}

extension Canvas.FlatKey {
    /// 細い塗りの片の数の区間だけが違う鍵なら、大きいほうの区間にした鍵 (#2208)。細い塗りかどうかが
    /// 違うか、区間以外が違えば `nil`。
    func joined(with other: Canvas.FlatKey) -> Canvas.FlatKey? {
        guard (thinFillCapacity > 0) == (other.thinFillCapacity > 0) else { return nil }
        var widest = self
        widest.thinFillCapacity = max(thinFillCapacity, other.thinFillCapacity)
        var same = other
        same.thinFillCapacity = widest.thinFillCapacity
        return widest == same ? widest : nil
    }

    /// この鍵の雛形が `other` の置き場所も受けられるか。区間以外が同じで、この雛形の区間が `other` 以上。
    func holds(_ other: Canvas.FlatKey) -> Bool {
        joined(with: other)?.thinFillCapacity == thinFillCapacity
    }
}
