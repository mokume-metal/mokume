// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

// 描く前の計算。
extension Sketch {
    /// 数の並びを用意する。**CPU と GPU で同じものを見る。**
    ///
    /// 下は、長さ (`count`) を 4・8・16 と動かした並びを作り、`setup()` で CPU から明るさの段を
    /// 書いたもの。断片 (``makeShader(_:name:values:surfaces:)``) は横の位置から升の番号を出し、
    /// ``numbers(_:)`` で渡した並びの値をそのまま明るさにする (升の両端は細く抜いて区切る)。
    /// 升は長さの数だけ出て、CPU が書いた値を GPU が読んでいる。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     <!-- example: 文脈 var rows: [Numbers] = [] -->
    ///     <!-- example: 文脈 var paint: Shader! -->
    ///     ```swift
    ///     func setup() {
    ///         // 長さを 4・8・16 と動かし、CPU から明るさの段を書く
    ///         for count in [4, 8, 16] {
    ///             let row = try! makeNumbers(count: count)
    ///             row.set((1...count).map { Float($0) / Float(count) })
    ///             rows.append(row)
    ///         }
    ///         // 横の位置から升の番号を出し、並びの値を明るさにする。
    ///         // 升の両端は細く抜き、升の数が見えるようにする
    ///         paint = try! makeShader(
    ///             """
    ///             float4 paint(Fragment in, Values values) {
    ///                 float cell = in.place.x * values.count;
    ///                 float inside = step(0.06, fract(cell)) * step(fract(cell), 0.94);
    ///                 return float4(float3(in.numbers[uint(cell)] * inside), 1);
    ///             }
    ///             """,
    ///             values: ["count": 4])
    ///     }
    ///
    ///     func draw() {
    ///         background(23, 26, 31)
    ///         noStroke()
    ///         shader(paint)
    ///         for (i, row) in rows.enumerated() {
    ///             paint.set("count", .number(Float(row.count)))
    ///             numbers(row)
    ///             rect(0, 30 + Float(i) * 90, width, 60)
    ///         }
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 横長の帯が 3 本。上から 4・8・16 の升に区切られ、どの帯も左の暗い灰色から右の白へ升ごとに明るくなる -->
    ///     ![横長の帯が 3 本。上から 4・8・16 の升に区切られ、どの帯も左の暗い灰色から右の白へ升ごとに明るくなる](https://i.gyazo.com/e899322015ed4c6627d6d1e41f4bc211.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// ## 書くのは CPU から、読むのは 1 本の道から
    ///
    /// 書くのはいつでもよい。種を蒔く向き (CPU → GPU) はフレームの外でも中でも意味が
    /// 変わらないので、`setup()` で蒔いてから `draw()` で回してよい (上の例も `setup()` で書いている)。
    ///
    /// **読むときは ``read(_:)`` を通る。** この型に読む口は無く、そこは必ず計算の
    /// 完了まで待つ。同じメモリを見ているので値は「読めて」しまうが、それが計算の前なのか
    /// 後なのかは呼んだ側に分からず、**絵か音がおかしくなって初めて気付く**形になるため。
    ///
    /// - Throws: 領域を取れないときと、`count` が 1 を割るとき (``RenderFailure/invalidCount(_:)``。
    ///   1 個へ丸めない) に ``RenderFailure``。
    // shot: 1 snippet=fc61cf1e
    public func makeNumbers(count: Int) throws(RenderFailure) -> Numbers {
        try canvas.makeNumbers(count: count)
    }

    /// 文字列から計算を作る。保存の拾い直しは効かない (在処が無いため)。
    ///
    /// ## 入口の関数は名前と同じ
    ///
    /// `name` がそのまま断片の中の `kernel void <name>(...)` になる。読み込む側
    /// (``loadComputation(_:values:)``) ではファイル名がその名前になる。
    ///
    /// 下は、入口を 2 つ (`rise` と `fall`) 書いた 1 つの断片から、`name` だけを変えて計算を 2 つ
    /// 作ったもの。上の帯の並びへ `rise`、下の帯の並びへ `fall` を走らせると、明るくなる向きが
    /// 逆になる。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     <!-- example: 文脈 var rise: Computation! -->
    ///     <!-- example: 文脈 var fall: Computation! -->
    ///     <!-- example: 文脈 var rows: [Numbers] = [] -->
    ///     <!-- example: 文脈 var paint: Shader! -->
    ///     ```swift
    ///     func setup() {
    ///         // 入口を 2 つ書いた 1 つの断片から、name で入口を選ぶ
    ///         let body = """
    ///             kernel void rise(device float *level [[buffer(0)]],
    ///                              uint id [[thread_position_in_grid]])
    ///             {
    ///                 level[id] = (float(id) + 1.0) / 16.0;
    ///             }
    ///
    ///             kernel void fall(device float *level [[buffer(0)]],
    ///                              uint id [[thread_position_in_grid]])
    ///             {
    ///                 level[id] = (16.0 - float(id)) / 16.0;
    ///             }
    ///             """
    ///         rise = try! makeComputation(body, name: "rise")
    ///         fall = try! makeComputation(body, name: "fall")
    ///         rows = [try! makeNumbers(count: 16), try! makeNumbers(count: 16)]
    ///         paint = try! makeShader(
    ///             """
    ///             float4 paint(Fragment in, Values values) {
    ///                 uint i = uint(in.place.x * values.count);
    ///                 return float4(float3(in.numbers[i]), 1);
    ///             }
    ///             """,
    ///             values: ["count": 16])
    ///     }
    ///
    ///     func draw() {
    ///         compute(rise, over: 16, writes: [rows[0]])
    ///         compute(fall, over: 16, writes: [rows[1]])
    ///         background(23, 26, 31)
    ///         noStroke()
    ///         shader(paint)
    ///         numbers(rows[0])
    ///         rect(0, 50, width, 80)
    ///         numbers(rows[1])
    ///         rect(0, 170, width, 80)
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 16 の升に分かれた帯が 2 本。上の帯は左の暗い灰色から右の白へ、下の帯は左の白から右の暗い灰色へ、段々に明るさが変わる -->
    ///     ![16 の升に分かれた帯が 2 本。上の帯は左の暗い灰色から右の白へ、下の帯は左の白から右の暗い灰色へ、段々に明るさが変わる](https://i.gyazo.com/8a51caa00c168570965888829a646f93.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// ## 束ねる先は呼ぶときに決まる
    ///
    /// ``compute(_:over:reads:writes:)`` に渡した `reads + writes` の並びが、そのまま
    /// `buffer(0)`, `buffer(1)`, … になる。渡した値は `MOKUME_VALUES` の口に載る
    /// (番号を書き写さずに済むよう名前で配ってある)。値は後から差し替えられる
    /// (``Computation/set(_:_:)``)。
    ///
    /// 下は、山の数 (`peaks`) を `values` で宣言した計算を 1 つ作り、``Computation/set(_:_:)`` で
    /// 1・2・3 と差し替えながら 3 本の並びへ頼んだもの。**頼んだ時点の値が効く**ので、同じ
    /// フレームの中で差し替えても、上の帯から順に山が 1 つ・2 つ・3 つになる。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     <!-- example: 文脈 var hills: Computation! -->
    ///     <!-- example: 文脈 var rows: [Numbers] = [] -->
    ///     <!-- example: 文脈 var paint: Shader! -->
    ///     ```swift
    ///     func setup() {
    ///         // 山の数を values で宣言する。断片からは values.peaks で読める
    ///         hills = try! makeComputation(
    ///             """
    ///             kernel void hills(device float *level [[buffer(0)]],
    ///                               constant Values &values [[buffer(MOKUME_VALUES)]],
    ///                               uint id [[thread_position_in_grid]])
    ///             {
    ///                 float turn = (float(id) + 0.5) / 64.0 * values.peaks;
    ///                 level[id] = 0.5 - 0.5 * cos(turn * 6.2832);
    ///             }
    ///             """,
    ///             name: "hills", values: ["peaks": 1])
    ///         rows = (0..<3).map { _ in try! makeNumbers(count: 64) }
    ///         paint = try! makeShader(
    ///             """
    ///             float4 paint(Fragment in, Values values) {
    ///                 uint i = uint(in.place.x * values.count);
    ///                 return float4(float3(in.numbers[i]), 1);
    ///             }
    ///             """,
    ///             values: ["count": 64])
    ///     }
    ///
    ///     func draw() {
    ///         // 山の数を 1・2・3 と差し替えながら頼む
    ///         for (i, row) in rows.enumerated() {
    ///             hills.set("peaks", .number(Float(i + 1)))
    ///             compute(hills, over: 64, writes: [row])
    ///         }
    ///         background(23, 26, 31)
    ///         noStroke()
    ///         shader(paint)
    ///         for (i, row) in rows.enumerated() {
    ///             numbers(row)
    ///             rect(0, 30 + Float(i) * 90, width, 60)
    ///         }
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 横長の帯が 3 本。暗い所と明るい所が滑らかに入れ替わり、明るい山が上の帯に 1 つ、中の帯に 2 つ、下の帯に 3 つある | symmetric=x -->
    ///     ![横長の帯が 3 本。暗い所と明るい所が滑らかに入れ替わり、明るい山が上の帯に 1 つ、中の帯に 2 つ、下の帯に 3 つある](https://i.gyazo.com/ced22251a5f4945884c0aeb40294d266.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// ## 保存したら差し替わる
    ///
    /// 在処のある断片は保存を拾って組み直される。**組み立てに失敗しても計算は止まらない** —
    /// 前の断片がそのまま残り、失敗の理由は観測の警告に出る。
    ///
    /// - Throws: 組み立てられないときに ``ShaderFailure``。
    // shot: 1 snippet=d76ea602
    // shot: 2 snippet=e8f5dab5
    public func makeComputation(
        _ body: String, name: String = "computation", values: [String: ShaderValue] = [:]
    ) throws(ShaderFailure) -> Computation {
        try canvas.makeComputation(body, name: name, values: values)
    }

    /// ファイルから計算を読み込む。**入口の関数の名前はファイル名**になる。
    ///
    /// 断片の書き方と値の渡し方は ``makeComputation(_:name:values:)`` と同じで、例と絵も
    /// そちらにある。違うのは、入口の名前を `name` ではなくファイル名で決めること
    /// (`assets/step.metal` なら `kernel void step(...)`) と、在処があるので保存を拾って組み直される
    /// こと (``makeComputation(_:name:values:)`` の「保存したら差し替わる」) である。
    ///
    /// - Throws: 見つからないとき・組み立てられないときに ``ShaderFailure``。
    // shot: 参照 makeComputation(_:name:values:)
    public func loadComputation(
        _ path: String, values: [String: ShaderValue] = [:]
    ) throws(ShaderFailure) -> Computation {
        try canvas.loadComputation(path, values: values)
    }

    /// 描く前に計算させる (1 次元)。
    ///
    /// `count` 本が走り、断片は `uint id [[thread_position_in_grid]]` で自分の番号 (0 から
    /// `count - 1`) を受け取る。下は、走った 1 本ごとにその番号の升を明るくする計算を、暗い灰色で
    /// 埋めた 16 升の並びへ、走らせる数を 4・8・16 と動かして頼んだもの。明るくなるのは並びの
    /// 先頭からその数の升だけで、残りは CPU が埋めた値のまま残る。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     <!-- example: 文脈 var light: Computation! -->
    ///     <!-- example: 文脈 var rows: [Numbers] = [] -->
    ///     <!-- example: 文脈 var paint: Shader! -->
    ///     ```swift
    ///     func setup() {
    ///         // 走った 1 本ごとに、その番号の升を明るくする
    ///         light = try! makeComputation(
    ///             """
    ///             kernel void light(device float *level [[buffer(0)]],
    ///                               uint id [[thread_position_in_grid]])
    ///             {
    ///                 level[id] = 1.0;
    ///             }
    ///             """,
    ///             name: "light")
    ///         // 16 升の並びを 3 本。CPU から暗い灰色で埋めておく
    ///         for _ in 0..<3 {
    ///             let row = try! makeNumbers(count: 16)
    ///             row.fill(0.1)
    ///             rows.append(row)
    ///         }
    ///         paint = try! makeShader(
    ///             """
    ///             float4 paint(Fragment in, Values values) {
    ///                 uint i = uint(in.place.x * values.count);
    ///                 return float4(float3(in.numbers[i]), 1);
    ///             }
    ///             """,
    ///             values: ["count": 16])
    ///     }
    ///
    ///     func draw() {
    ///         // 走らせる数を 4・8・16 と動かす
    ///         for (i, count) in [4, 8, 16].enumerated() {
    ///             compute(light, over: count, writes: [rows[i]])
    ///         }
    ///         background(23, 26, 31)
    ///         noStroke()
    ///         shader(paint)
    ///         for (i, row) in rows.enumerated() {
    ///             numbers(row)
    ///             rect(0, 30 + Float(i) * 90, width, 60)
    ///         }
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 横長の帯が 3 本。どれも左から白く、右は暗い灰色で、白い所は上の帯が 4 分の 1、中の帯が半分、下の帯が全部 -->
    ///     ![横長の帯が 3 本。どれも左から白く、右は暗い灰色で、白い所は上の帯が 4 分の 1、中の帯が半分、下の帯が全部](https://i.gyazo.com/8072cc380ecbc0b926798674f2487260.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// ## 読むものと書くものを言う
    ///
    /// `reads` と `writes` は**束ねる先であると同時に、依存の宣言**でもある。前に頼んだ
    /// 計算が書いた並びに触れる計算は、その計算が終わってから走る — 触れない計算どうしは
    /// 並行に走る。**順序は宣言から導かれる**ので、待つ仕掛けを自分で書くことはない。
    ///
    /// 束ねる先と宣言を 1 つにしてあるのは、2 つに分けると「束ねたのに宣言し忘れた」
    /// 組み合わせが作れてしまうからである。
    ///
    /// 下は、読んだ並びに 0.3 を足して書く計算を、1 本目 → 2 本目、2 本目 → 3 本目とつないで
    /// 頼んだもの。読む並びが `buffer(0)`、書く並びが `buffer(1)` に来る。2 つ目の計算は 1 つ目が
    /// 書いた並びを読むので、1 つ目が終わってから走り、帯は上から 1 段ずつ明るくなる。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     <!-- example: 文脈 var add: Computation! -->
    ///     <!-- example: 文脈 var rows: [Numbers] = [] -->
    ///     <!-- example: 文脈 var paint: Shader! -->
    ///     ```swift
    ///     func setup() {
    ///         // reads の並びが buffer(0)、writes の並びが buffer(1) に来る
    ///         add = try! makeComputation(
    ///             """
    ///             kernel void add(device const float *from [[buffer(0)]],
    ///                             device float *to [[buffer(1)]],
    ///                             uint id [[thread_position_in_grid]])
    ///             {
    ///                 to[id] = from[id] + 0.3;
    ///             }
    ///             """,
    ///             name: "add")
    ///         rows = (0..<3).map { _ in try! makeNumbers(count: 16) }
    ///         // 1 本目にだけ、CPU から明るさの段を書く
    ///         rows[0].set((0..<16).map { 0.1 + Float($0) / 15 * 0.2 })
    ///         paint = try! makeShader(
    ///             """
    ///             float4 paint(Fragment in, Values values) {
    ///                 uint i = uint(in.place.x * values.count);
    ///                 return float4(float3(in.numbers[i]), 1);
    ///             }
    ///             """,
    ///             values: ["count": 16])
    ///     }
    ///
    ///     func draw() {
    ///         // 2 つ目は 1 つ目が書いた並びを読む。終わるのを待つ仕掛けは書かない
    ///         compute(add, over: 16, reads: [rows[0]], writes: [rows[1]])
    ///         compute(add, over: 16, reads: [rows[1]], writes: [rows[2]])
    ///         background(23, 26, 31)
    ///         noStroke()
    ///         shader(paint)
    ///         for (i, row) in rows.enumerated() {
    ///             numbers(row)
    ///             rect(0, 30 + Float(i) * 90, width, 60)
    ///         }
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 16 の升に分かれた帯が 3 本。どの帯も左から右へ少しずつ明るくなり、帯どうしでは上の暗い灰色から下の明るい灰色へ 1 段ずつ明るい -->
    ///     ![16 の升に分かれた帯が 3 本。どの帯も左から右へ少しずつ明るくなり、帯どうしでは上の暗い灰色から下の明るい灰色へ 1 段ずつ明るい](https://i.gyazo.com/d4b49c15810203fdd4ff267ecba8041b.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// ## 描き場所をまたいでも、頼んだ順に効く
    ///
    /// 本体と描き場所 (``createGraphics(_:_:)``) で同じ並びを使っても、計算は**頼んだ順**に
    /// 効く。本体で先に頼んだ計算が書いた並びを、描き場所で後から読む計算は、書かれた後の値を
    /// 読む。描き場所で先に頼んだなら、そちらが先に効く。描き場所の `endDraw()` が本体の描き切りより
    /// 先に来ても、これは変わらない。使う並びが重ならない計算どうしは、今までどおり面ごとに流れる。
    ///
    /// 頼んだ順に効くのは**計算どうし**・``read(_:)``・数の並びへの書き込み (``Numbers/set(_:at:)``・
    /// ``Numbers/set(_:)``・``Numbers/fill(_:)``) の間である。書く前に頼んだ計算は書く前の中身を読み、
    /// 頼んだ後に書いた値は、その計算がその並びへ書いても残る。``numbers(_:)`` で渡した並びを読む
    /// 図形は、置いた順ではなく、それを置いた面が描き切られる時点の値で描かれる (計算は描画の前置き)。
    ///
    /// ## 計算と描画の間
    ///
    /// 計算が書いた並びを描画が読むときの同期も仕組みが入れる。**頼まれていない
    /// フレームでは何も待たない**ので、計算を使わないスケッチが遅くなることはない。
    ///
    /// ## 描くところで頼む
    ///
    /// `draw()` の中だけで効く。`setup()` や初期化から頼んだ計算はどのフレームにも
    /// 属さないので、**無視して理由を知らせる**。
    ///
    /// 下は、同じ計算を、上の帯の並びへは `setup()` で、下の帯の並びへは `draw()` で頼んだもの。
    /// `setup()` で頼んだほうは走らず、上の帯は CPU が埋めた暗い灰色のまま残る。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     <!-- example: 文脈 var light: Computation! -->
    ///     <!-- example: 文脈 var early: Numbers! -->
    ///     <!-- example: 文脈 var late: Numbers! -->
    ///     <!-- example: 文脈 var paint: Shader! -->
    ///     ```swift
    ///     func setup() {
    ///         light = try! makeComputation(
    ///             """
    ///             kernel void light(device float *level [[buffer(0)]],
    ///                               uint id [[thread_position_in_grid]])
    ///             {
    ///                 level[id] = 1.0;
    ///             }
    ///             """,
    ///             name: "light")
    ///         early = try! makeNumbers(count: 16)
    ///         early.fill(0.1)
    ///         late = try! makeNumbers(count: 16)
    ///         late.fill(0.1)
    ///         paint = try! makeShader(
    ///             """
    ///             float4 paint(Fragment in, Values values) {
    ///                 uint i = uint(in.place.x * values.count);
    ///                 return float4(float3(in.numbers[i]), 1);
    ///             }
    ///             """,
    ///             values: ["count": 16])
    ///         // setup() で頼んだ計算はどのフレームにも属さないので、走らない
    ///         compute(light, over: 16, writes: [early])
    ///     }
    ///
    ///     func draw() {
    ///         compute(light, over: 16, writes: [late])
    ///         background(23, 26, 31)
    ///         noStroke()
    ///         shader(paint)
    ///         numbers(early)
    ///         rect(0, 50, width, 80)
    ///         numbers(late)
    ///         rect(0, 170, width, 80)
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 横長の帯が 2 本。上の帯は一様な暗い灰色で、下の帯は一様に白い | symmetric=x -->
    ///     ![横長の帯が 2 本。上の帯は一様な暗い灰色で、下の帯は一様に白い](https://i.gyazo.com/0c226d41c5c8b51d68e682fe5a99f72f.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=40715f97
    // shot: 2 snippet=12b4d9f9
    // shot: 3 snippet=7db37900
    public func compute(
        _ computation: Computation, over count: Int,
        reads: [Numbers] = [], writes: [Numbers] = []
    ) {
        canvas.compute(computation, over: count, reads: reads, writes: writes)
    }

    /// これから描くものが、この並びを読む。
    ///
    /// 断片からは `in.numbers[i]` で引ける。**計算が書いた値をそのまま絵にする道**で、
    /// 渡していない断片が読むと 1 個の 0 が返る (何も束ねない状態は作らない)。
    ///
    /// 下は、中身の違う 3 本の並び (右へ明るい段・左へ明るい段・1 升おきに明るい) を、同じ断片で
    /// 塗る帯ごとに渡し替えたもの。どの帯も、置く前に渡した並びを読む。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     <!-- example: 文脈 var rows: [Numbers] = [] -->
    ///     <!-- example: 文脈 var paint: Shader! -->
    ///     ```swift
    ///     func setup() {
    ///         // 中身の違う 3 本: 右へ明るい段・左へ明るい段・1 升おきに明るい
    ///         let ramp = (1...16).map { Float($0) / 16 }
    ///         let stripes = (0..<16).map { Float($0 % 2) }
    ///         for values in [ramp, Array(ramp.reversed()), stripes] {
    ///             let row = try! makeNumbers(count: 16)
    ///             row.set(values)
    ///             rows.append(row)
    ///         }
    ///         paint = try! makeShader(
    ///             """
    ///             float4 paint(Fragment in, Values values) {
    ///                 uint i = uint(in.place.x * values.count);
    ///                 return float4(float3(in.numbers[i]), 1);
    ///             }
    ///             """,
    ///             values: ["count": 16])
    ///     }
    ///
    ///     func draw() {
    ///         background(23, 26, 31)
    ///         noStroke()
    ///         shader(paint)
    ///         // 帯ごとに、読む並びを渡し替える
    ///         for (i, row) in rows.enumerated() {
    ///             numbers(row)
    ///             rect(0, 30 + Float(i) * 90, width, 60)
    ///         }
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 16 の升に分かれた帯が 3 本。上の帯は右へ、中の帯は左へ段々に明るくなり、下の帯は黒と白の升が交互に並ぶ -->
    ///     ![16 の升に分かれた帯が 3 本。上の帯は右へ、中の帯は左へ段々に明るくなり、下の帯は黒と白の升が交互に並ぶ](https://i.gyazo.com/fd71a3c738b55b6cf130659524fa1c8a.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// **溜めている図形はその場で区切られる**ので、これより前に置いた図形が後から
    /// 差し替わることはない。ただし、読む並びが差し替わらないということで、**中身は置いた
    /// 時点で固まらない** — 図形は描き切りの時点の中身で描かれる (``Numbers`` の
    /// 「読み手ごとに、効く時刻が違う」)。長さは渡した側が知っているので断片へは配らない。
    ///
    /// 下は、1 個の並びの値に断片の値 (`gain`) を掛けて塗る断片で、四角を 3 つずつ 2 段に置いたもの。
    /// 上の段は並びの中身を 1・0.6・0.25 と書き換えながら置き、3 つとも描き切りの時点の 0.25 で
    /// 描かれる。下の段は断片の値を同じく書き換えながら置き、こちらは置いた時点の値で描かれる
    /// (``Shader/set(_:_:)-(_,ShaderValue)`` とは向きが逆)。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     <!-- example: 文脈 var level: Numbers! -->
    ///     <!-- example: 文脈 var one: Numbers! -->
    ///     <!-- example: 文脈 var paint: Shader! -->
    ///     ```swift
    ///     func setup() {
    ///         level = try! makeNumbers(count: 1)
    ///         one = try! makeNumbers(count: 1)
    ///         one.set(1, at: 0)
    ///         // 並びの値に、断片の値 (gain) を掛けて明るさにする
    ///         paint = try! makeShader(
    ///             """
    ///             float4 paint(Fragment in, Values values) {
    ///                 return float4(float3(in.numbers[0] * values.gain), 1);
    ///             }
    ///             """,
    ///             values: ["gain": 1])
    ///     }
    ///
    ///     func draw() {
    ///         background(23, 26, 31)
    ///         noStroke()
    ///         shader(paint)
    ///         let steps: [Float] = [1, 0.6, 0.25]
    ///         // 上の段: 並びの中身を書き換えながら置く。描き切りの時点の中身で描かれる
    ///         paint.set("gain", 1)
    ///         numbers(level)
    ///         for (i, value) in steps.enumerated() {
    ///             level.set(value, at: 0)
    ///             rect(40 + Float(i) * 120, 40, 80, 80)
    ///         }
    ///         // 下の段: 断片の値を書き換えながら置く。置いた時点の値で描かれる
    ///         numbers(one)
    ///         for (i, value) in steps.enumerated() {
    ///             paint.set("gain", .number(value))
    ///             rect(40 + Float(i) * 120, 180, 80, 80)
    ///         }
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 灰色の四角が上下 2 段に 3 つずつ。上の段は 3 つとも同じ暗い灰色で、下の段は左の白から右の暗い灰色へ段々に暗くなる -->
    ///     ![灰色の四角が上下 2 段に 3 つずつ。上の段は 3 つとも同じ暗い灰色で、下の段は左の白から右の暗い灰色へ段々に暗くなる](https://i.gyazo.com/b0f3606b2d33bac9db177f9a3706b47f.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// 渡すのは 1 度でよい。中身を ``Numbers/set(_:at:)`` で書き換えれば、次のフレームの
    /// 断片もその値を読む — 断片 (``shader(_:)``) と一組で残る。
    ///
    /// 下は、断片と並びを `setup()` で 1 度だけ渡し、`draw()` では並びの中身だけを書き換えたもの。
    /// 明るい升が 1 フレームに 1 升ずつ右へ進む。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     <!-- example: 文脈 var level: Numbers! -->
    ///     <!-- example: 文脈 var paint: Shader! -->
    ///     ```swift
    ///     func setup() {
    ///         level = try! makeNumbers(count: 16)
    ///         paint = try! makeShader(
    ///             """
    ///             float4 paint(Fragment in, Values values) {
    ///                 uint i = uint(in.place.x * values.count);
    ///                 return float4(float3(in.numbers[i]), 1);
    ///             }
    ///             """,
    ///             values: ["count": 16])
    ///         // 断片と並びは、1 度渡せばフレームを越えて残る
    ///         shader(paint)
    ///         numbers(level)
    ///     }
    ///
    ///     func draw() {
    ///         background(23, 26, 31)
    ///         noStroke()
    ///         // 中身だけを毎フレーム書き換える
    ///         let lit = (frameCount - 1) % 16
    ///         level.set((0..<16).map { $0 == lit ? 1 : 0.15 })
    ///         rect(0, 110, width, 80)
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 暗い灰色の帯の中を、白い升が 1 つ、左から右へ 1 升ずつ進み、右端まで行くと左端へ戻る | frames=48 symmetric=y -->
    ///     ![暗い灰色の帯の中を、白い升が 1 つ、左から右へ 1 升ずつ進み、右端まで行くと左端へ戻る](https://i.gyazo.com/31c4fd2742de4e45ab07b43c44b1cf2b.gif)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// - Note: 並びは**フレームを越える**。一度書けば、書き換えるまで残る。
    // shot: 1 snippet=d9bf43e4
    // shot: 2 snippet=0bc34129
    // shot: 3 snippet=5ec9d11e
    public func numbers(_ numbers: Numbers) { canvas.numbers(numbers) }

    /// 並びを読まない状態へ戻す。
    ///
    /// 戻した後の断片が読むのは、渡していないときと同じ 1 個の 0 である。**並びの中身には
    /// 触らない** — もう一度 ``numbers(_:)`` で渡せば、同じ中身が読める。
    ///
    /// 下は、1 個の並び (中身は 0.8) を読む断片で四角を 3 つ置き、真ん中の四角の前で戻し、右の
    /// 四角の前で渡し直したもの。真ん中だけが 0 を読んで黒くなる。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     <!-- example: 文脈 var level: Numbers! -->
    ///     <!-- example: 文脈 var paint: Shader! -->
    ///     ```swift
    ///     func setup() {
    ///         level = try! makeNumbers(count: 1)
    ///         level.set(0.8, at: 0)
    ///         // 渡していないときに読めるのは 1 個の 0 なので、0 番だけを読む
    ///         paint = try! makeShader(
    ///             """
    ///             float4 paint(Fragment in, Values values) {
    ///                 return float4(float3(in.numbers[0]), 1);
    ///             }
    ///             """)
    ///     }
    ///
    ///     func draw() {
    ///         background(89, 97, 115)
    ///         noStroke()
    ///         shader(paint)
    ///         numbers(level)
    ///         rect(30, 90, 100, 120)
    ///         // 読まない状態へ戻す。断片は 1 個の 0 を読む
    ///         resetNumbers()
    ///         rect(150, 90, 100, 120)
    ///         // 渡し直すと、同じ中身が読める
    ///         numbers(level)
    ///         rect(270, 90, 100, 120)
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 青みの灰色の下地に四角が 3 つ。左と右は同じ明るい灰色で、真ん中だけが黒い | symmetric=xy -->
    ///     ![青みの灰色の下地に四角が 3 つ。左と右は同じ明るい灰色で、真ん中だけが黒い](https://i.gyazo.com/2134305a6d737d3575fd95f10822e60a.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// 戻した状態も**フレームを越える**。下は、断片と並びを `setup()` で 1 度だけ渡し、毎フレーム
    /// 中身を書き換えながら、30 フレーム目で 1 度だけ戻したもの。戻した後は、中身を書き換え続けても
    /// 円は黒いままである。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     <!-- example: 文脈 var level: Numbers! -->
    ///     <!-- example: 文脈 var paint: Shader! -->
    ///     ```swift
    ///     func setup() {
    ///         level = try! makeNumbers(count: 1)
    ///         paint = try! makeShader(
    ///             """
    ///             float4 paint(Fragment in, Values values) {
    ///                 return float4(float3(in.numbers[0]), 1);
    ///             }
    ///             """)
    ///         shader(paint)
    ///         numbers(level)
    ///     }
    ///
    ///     func draw() {
    ///         background(89, 97, 115)
    ///         noStroke()
    ///         // 中身は毎フレーム書き換え続ける
    ///         level.set(0.5 + 0.4 * sin(Float(frameCount) * 0.4), at: 0)
    ///         // 30 フレーム目で 1 度だけ戻す。そのあとのフレームも戻したまま
    ///         if frameCount == 30 { resetNumbers() }
    ///         circle(200, 150, 160)
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 青みの灰色の下地の真ん中の円が、明るくなったり暗くなったりを繰り返したあと黒くなり、そのまま黒い | frames=60 symmetric=xy -->
    ///     ![青みの灰色の下地の真ん中の円が、明るくなったり暗くなったりを繰り返したあと黒くなり、そのまま黒い](https://i.gyazo.com/e8552ac1108eb45e52dde74e55f922f2.gif)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// - Note: 並びは**フレームを越える**。一度書けば、書き換えるまで残る。
    // shot: 1 snippet=b40dc8fc
    // shot: 2 snippet=b4da70c9
    public func resetNumbers() { canvas.resetNumbers() }

    /// 描く前に計算させる (2 次元)。
    ///
    /// 断片は `uint2 at [[thread_position_in_grid]]` で位置を受け取る。ほかは 1 次元の
    /// ``compute(_:over:reads:writes:)`` と同じ。
    ///
    /// 下は、8 × 6 の升目 (CPU が市松に埋めたもの) を 3 枚用意し、走った位置の升を白くする計算を、
    /// 基準の 4 × 3 から幅 (`width`) を 8 に、高さ (`height`) を 6 に 1 つずつ動かして頼んだもの。
    /// 白くなるのは、左上から幅 × 高さの升だけである。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     <!-- example: 文脈 var mark: Computation! -->
    ///     <!-- example: 文脈 var grids: [Numbers] = [] -->
    ///     <!-- example: 文脈 var paint: Shader! -->
    ///     ```swift
    ///     func setup() {
    ///         // 位置は uint2 で届く。8 × 6 の升目の、その位置を白くする
    ///         mark = try! makeComputation(
    ///             """
    ///             kernel void mark(device float *grid [[buffer(0)]],
    ///                              uint2 at [[thread_position_in_grid]])
    ///             {
    ///                 grid[at.y * 8 + at.x] = 1.0;
    ///             }
    ///             """,
    ///             name: "mark")
    ///         // 升目は CPU から市松に埋めておく
    ///         for _ in 0..<3 {
    ///             let grid = try! makeNumbers(count: 8 * 6)
    ///             grid.set((0..<48).map { ($0 % 8 + $0 / 8) % 2 == 0 ? 0.1 : 0.2 })
    ///             grids.append(grid)
    ///         }
    ///         // 板の左上 (origin) から 14 ずつの升で、並びの値を読む
    ///         paint = try! makeShader(
    ///             """
    ///             float4 paint(Fragment in, Values values) {
    ///                 uint2 cell = uint2((in.position - values.origin) / 14.0);
    ///                 return float4(float3(in.numbers[cell.y * 8 + cell.x]), 1);
    ///             }
    ///             """,
    ///             values: ["origin": .pair(0, 0)])
    ///     }
    ///
    ///     func draw() {
    ///         // 基準の 4 × 3 から、幅を 8 に、高さを 6 に 1 つずつ動かす
    ///         let sizes = [(4, 3), (8, 3), (4, 6)]
    ///         for (i, size) in sizes.enumerated() {
    ///             compute(mark, over: size.0, by: size.1, writes: [grids[i]])
    ///         }
    ///         background(23, 26, 31)
    ///         noStroke()
    ///         shader(paint)
    ///         for (i, grid) in grids.enumerated() {
    ///             let x = 20 + Float(i) * 125
    ///             paint.set("origin", .pair(x, 108))
    ///             numbers(grid)
    ///             rect(x, 108, 112, 84)
    ///         }
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 暗い市松模様の升目の板が 3 枚。どれも左上から白い升が広がり、左の板は 4 × 3 升、真ん中は上半分の 8 × 3 升、右は左半分の 4 × 6 升が白い -->
    ///     ![暗い市松模様の升目の板が 3 枚。どれも左上から白い升が広がり、左の板は 4 × 3 升、真ん中は上半分の 8 × 3 升、右は左半分の 4 × 6 升が白い](https://i.gyazo.com/e31d399076425e181ee642d4dc2f6fe9.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=d5ab3e25
    public func compute(
        _ computation: Computation, over width: Int, by height: Int,
        reads: [Numbers] = [], writes: [Numbers] = []
    ) {
        canvas.compute(computation, over: width, by: height, reads: reads, writes: writes)
    }

    /// 計算が書いた値を読む。**そのフレームの結果が返る。**
    ///
    /// GPU で集めた値を、音・通信・状態遷移といった CPU 側の仕事へ渡すための道である。
    ///
    /// 下は、GPU が 12 個の高さを書き、CPU がそれを読んで円を置いたもの。円の位置を決めて
    /// いるのは、読み返した値だけである。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     <!-- example: 文脈 var wave: Computation! -->
    ///     <!-- example: 文脈 var heights: Numbers! -->
    ///     ```swift
    ///     func setup() {
    ///         // 12 個の高さを GPU で決める
    ///         wave = try! makeComputation(
    ///             """
    ///             kernel void wave(device float *heights [[buffer(0)]],
    ///                              uint id [[thread_position_in_grid]])
    ///             {
    ///                 heights[id] = 150.0 + 90.0 * sin(float(id) * 0.55);
    ///             }
    ///             """,
    ///             name: "wave")
    ///         heights = try! makeNumbers(count: 12)
    ///     }
    ///
    ///     func draw() {
    ///         compute(wave, over: 12, writes: [heights])
    ///         let ys = read(heights)      // ここで走らせて待つ
    ///         background(23, 26, 31)
    ///         noStroke()
    ///         fill(242, 115, 64)
    ///         for (i, y) in ys.enumerated() {
    ///             circle(35 + Float(i) * 30, y, 16)
    ///         }
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 橙色の小さな円が 12 個、左から右へ間を空けて並び、上下に波打っている -->
    ///     ![橙色の小さな円が 12 個、左から右へ間を空けて並び、上下に波打っている](https://i.gyazo.com/56ae8538953d09380396e18c5d8156c6.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// ## 読むと、そのフレームの続きが止まる
    ///
    /// 頼んだ計算がまだ走っていなければ、**その場で走らせて GPU の完了まで待つ**。
    /// 待っているあいだ、このフレームの続き (残りの図形を置くことも、描き切ることも)
    /// は進まない。毎フレーム読むと CPU と GPU が交互に動く形になり、重なって進めなく
    /// なる — **読むのは要るときだけ・まとめて 1 度**にする。
    ///
    /// 頼んだ計算が残っていなければ走らせるものは無いが、前のフレームの GPU の仕事が
    /// まだ終わっていなければ、それは待つ。同じフレームで 2 度読んでも、待つのは 1 度きり。
    ///
    /// **書いた値も、読む前に届く。** 数の並びへの書き込みは待たずに控えへ積まれ、描き
    /// 切りか読み戻しが GPU へ届けるので、書いた直後に読んでも書いた値が返る。
    ///
    /// ## 別の面で頼んだ計算も、読む前に流れる
    ///
    /// 本体と描き場所のどちらで頼んだ計算でも、この並びを書くものは、読む前に走る。
    /// 描き場所の中から、本体で先に頼んだ計算の結果を読んでもよい。
    ///
    /// ## 溜めている図形には触らない
    ///
    /// 画素の読み戻し (``pixels``) は溜めている図形を描き切るが、こちらは計算だけを
    /// 流す。図形を 1 つも置いていないフレームでも読めるし、読んだあとに置いた図形が
    /// 消えることもない。**別の機能を有効にしたときだけ動く形にしない**ため、同期を
    /// ほかの経路の副作用に相乗りさせていない。
    ///
    /// ## 読んだ後にもう一度頼んでよい
    ///
    /// 読んだ時点で溜め場は空になる。そのあと頼んだ計算は、いつもどおり描く前に流れる。
    /// 同じ計算が 2 度走ることはない。
    ///
    /// 下は、CPU から 45 を書いた 1 個の並びに、倍にする計算を頼んでは読んで棒を置く、を 1 つの
    /// フレームで 3 回繰り返したもの。読むたびにそこまでに頼んだ計算の結果が返り、棒は 90・180・360 と
    /// 伸びる。先に置いた棒も、後の読み戻しで消えない。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     <!-- example: 文脈 var twice: Computation! -->
    ///     <!-- example: 文脈 var span: Numbers! -->
    ///     ```swift
    ///     func setup() {
    ///         // 並びの値を倍にする
    ///         twice = try! makeComputation(
    ///             """
    ///             kernel void twice(device float *span [[buffer(0)]],
    ///                               uint id [[thread_position_in_grid]])
    ///             {
    ///                 span[id] = span[id] * 2.0;
    ///             }
    ///             """,
    ///             name: "twice")
    ///         span = try! makeNumbers(count: 1)
    ///     }
    ///
    ///     func draw() {
    ///         background(23, 26, 31)
    ///         noStroke()
    ///         fill(242, 115, 64)
    ///         span.set(45, at: 0)
    ///         // 頼む → 読む → 棒を置く、を 3 回
    ///         for row in 0..<3 {
    ///             compute(twice, over: 1, writes: [span])
    ///             let length = read(span)[0]
    ///             rect(20, 50 + Float(row) * 80, length, 40)
    ///         }
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 左端から右へ伸びる橙色の棒が 3 本。上から下へ、1 本ごとに長さが倍になる -->
    ///     ![左端から右へ伸びる橙色の棒が 3 本。上から下へ、1 本ごとに長さが倍になる](https://i.gyazo.com/f978a9723ffef9401d92f61018cd03d1.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=d7424f97
    // shot: 2 snippet=9dfc4082
    public func read(_ numbers: Numbers) -> [Float] { canvas.read(numbers) }
}
