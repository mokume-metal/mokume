// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

// モデル。
extension Sketch {
    /// 外で作ったモデルを読む。読み終わるまで返らない。
    ///
    /// <!-- example: 文脈 var head: Model? -->
    /// ```swift
    /// func setup() {
    ///     head = try? loadModel("assets/head.obj")
    /// }
    /// func draw() {
    ///     lights()
    ///     push()
    ///     translate(width / 2, height / 2, 0)
    ///     rotateY(time * 0.5)
    ///     if let head { model(head) }
    ///     pop()
    /// }
    /// ```
    ///
    /// 読むのは **OBJ (.obj)** と **STL (.stl)** で、拡張子で読み分ける (大文字小文字は
    /// 問わない)。どちらも形 (頂点・面・面の向き) と展開だけを読み、材質・テクスチャ・物体の
    /// 区切りは読み飛ばす (何を読み飛ばしたかは ``Model/skippedLines``)。面の向きが書かれて
    /// いなければ**形から求める**ので、向きの無いモデルでも立体らしく光が付く。
    ///
    /// **STL は 3D プリンタ向けに配られる形式で、文字の STL もバイナリの STL も読む。**
    /// OBJ と違うところが 3 つある:
    ///
    /// - **面ごとに平らに光る。** STL は点を共有しないので、隣の面と向きが均されない
    ///   (OBJ で向きを書かない形は、点を共有する面どうしで均される)。展開も持たないので、
    ///   貼る絵は囲みの箱の位置で乗る
    /// - **縦軸の約束が無い。** 3D プリンタ向けの STL は z を上に書くことが多いので、そのまま
    ///   置くと寝て見える。起こすなら `rotateX` で 4 分の 1 回す
    /// - **文字の STL で数として読めない座標は 0 として読まれる** (読み手の Model I/O がそう
    ///   読む)。OBJ のように読み飛ばして数えはしない。バイナリの STL で座標が数でない面は
    ///   読み飛ばし、``Model/skippedLines`` に面の数として数える
    ///
    /// 読めない STL (壊れている・途中で切れている・空のファイル・小文字の `solid` で始まらない
    /// 文字の STL) は ``ModelFailure/unreadable(path:)`` を投げる。面を 1 つも持たない STL は
    /// 投げない (下の Note)。
    ///
    /// **既定では、置いたら見える大きさへ整える** (`normalize`)。整えるのは 3 つ —
    /// 中心を原点へ、いちばん長い辺を面の短いほうの半分へ (一様に。軸の比は変わらない)、
    /// 縦軸をこの面の約束 (下向き) へ。`false` を渡すと**ファイルの座標がそのまま**残る。
    ///
    /// 下の 2 枚は同じ 2 つのファイル — 底が正方形の角錐を、大きさだけ 30 倍変えて書いた
    /// OBJ — を、整えて読んだものと整えずに読んだものである。OBJ は文字のファイルなので、
    /// 例はその場で書き出してから読んでいる。灰色の横線が、置いた位置 (`translate` の先) の
    /// 高さを通る。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     <!-- example: 文脈 var pyramids: [Model] = [] -->
    ///     ```swift
    ///     import Foundation
    ///
    ///     func setup() {
    ///         // 同じ角錐を、大きさだけ変えて 2 つの OBJ に書く (y が上向き)
    ///         for s in [1, 30] {
    ///             let obj = """
    ///                 v 0 \(3 * s) 0
    ///                 v \(-s) 0 \(-s)
    ///                 v \(s) 0 \(-s)
    ///                 v \(s) 0 \(s)
    ///                 v \(-s) 0 \(s)
    ///                 f 1 5 4
    ///                 f 1 4 3
    ///                 f 1 3 2
    ///                 f 1 2 5
    ///                 f 2 3 4 5
    ///                 """
    ///             let path = NSTemporaryDirectory() + "pyramid-\(s).obj"
    ///             try? obj.write(toFile: path, atomically: true, encoding: .utf8)
    ///             pyramids.append(try! loadModel(path))
    ///         }
    ///     }
    ///
    ///     func draw() {
    ///         background(23, 26, 31)
    ///         stroke(90)
    ///         line(0, 150, 400, 150)
    ///         lights()
    ///         noStroke()
    ///         fill(242, 115, 64)
    ///         for (index, pyramid) in pyramids.enumerated() {
    ///             push()
    ///             translate(110 + index * 180, 150, 0)
    ///             rotateY(0.6)
    ///             model(pyramid)
    ///             pop()
    ///         }
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 大きさが 30 倍違う 2 つのファイルから読んだ橙色の角錐が、同じ大きさで左右に並ぶ。どちらも頂点が上を向き、置いた高さを示す灰色の横線が形の途中を横切る -->
    ///     ![大きさが 30 倍違う 2 つのファイルから読んだ橙色の角錐が、同じ大きさで左右に並ぶ。どちらも頂点が上を向き、置いた高さを示す灰色の横線が形の途中を横切る](https://i.gyazo.com/2ed814ad0eed26cda63fe5391ad47390.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     <!-- example: 文脈 var pyramids: [Model] = [] -->
    ///     ```swift
    ///     import Foundation
    ///
    ///     func setup() {
    ///         // 同じ角錐を、大きさだけ変えて 2 つの OBJ に書く (y が上向き)
    ///         for s in [1, 30] {
    ///             let obj = """
    ///                 v 0 \(3 * s) 0
    ///                 v \(-s) 0 \(-s)
    ///                 v \(s) 0 \(-s)
    ///                 v \(s) 0 \(s)
    ///                 v \(-s) 0 \(s)
    ///                 f 1 5 4
    ///                 f 1 4 3
    ///                 f 1 3 2
    ///                 f 1 2 5
    ///                 f 2 3 4 5
    ///                 """
    ///             let path = NSTemporaryDirectory() + "pyramid-\(s).obj"
    ///             try? obj.write(toFile: path, atomically: true, encoding: .utf8)
    ///             pyramids.append(try! loadModel(path, normalize: false))
    ///         }
    ///     }
    ///
    ///     func draw() {
    ///         background(23, 26, 31)
    ///         stroke(90)
    ///         line(0, 150, 400, 150)
    ///         lights()
    ///         noStroke()
    ///         fill(242, 115, 64)
    ///         for (index, pyramid) in pyramids.enumerated() {
    ///             push()
    ///             translate(110 + index * 180, 150, 0)
    ///             rotateY(0.6)
    ///             model(pyramid)
    ///             pop()
    ///         }
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 同じ 2 つのファイルを整えずに読むと、左は横線のすぐ下の 2 画素ほどの点にしかならず、右は頂点が下を向いて横線から垂れ下がる -->
    ///     ![同じ 2 つのファイルを整えずに読むと、左は横線のすぐ下の 2 画素ほどの点にしかならず、右は頂点が下を向いて横線から垂れ下がる](https://i.gyazo.com/c94b3d123abd773211e3644da9f6aefa.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// **読み込みは投げる。** 失敗したときに別の道を選ぶ判断が要るためで、見つからない
    /// ときの説明には**探した場所**が載る。同じ名前・同じ整え方なら、控えに残っている
    /// 間は読み直さない (同じモデルが返る)。
    ///
    /// **読み直さないための控えには上限がある** (面ごとに、見積もりで約 64 MB)。超えると、
    /// しばらく使っていないモデルから捨てて、次に読むときに読み直す。読み直したモデルは
    /// 前に返したものとは別のもので (``Model`` の `==` は同じ読み込みから来たものだけを
    /// 等しいとする)、そのときのファイルの中身を読む。動きを書き出した連番の OBJ を
    /// `draw()` の中で 1 枚ずつ読む書き方でも、控えは上限を超えて増えない。ただし、
    /// 上限を超える長さの連番を繰り返し回すと毎回読み直すことになる。繰り返し回すなら、
    /// `setup()` で配列へ読んで持つ。
    ///
    /// - Note: 読めても面が 1 つも無いことがある (``Model/isEmpty``)。そのときは
    ///   投げずに、置いたときに警告する — 「読めなかった」と「読めたが見えない」は
    ///   別の話なので、区別できるようにしてある。
    // shot: 1 snippet=422c10b2
    // shot: 2 snippet=c25f28d8
    public func loadModel(_ path: String, normalize: Bool = true) throws(ModelFailure) -> Model {
        try canvas.loadModel(path, normalize: normalize)
    }

    /// 外で作ったモデルを読む。**読んでいる間、他の仕事を止めない。**
    ///
    /// 解釈を別の仕事として回すので、大きなモデルを読んでもフレームが詰まらない。
    ///
    /// **`setup()` の中で `Task` を起こし、そこから呼ぶ。** 呼び方と届く前の扱いは
    /// ``requestImage(_:)`` と同じで、届くまでの ``draw()`` はモデルが無いまま呼ばれ、
    /// 置くのは `draw()` の中である。
    ///
    /// <!-- example: 文脈 var head: Model? -->
    /// ```swift
    /// func setup() {
    ///     Task { head = try? await requestModel("assets/head.obj") }
    /// }
    ///
    /// func draw() {
    ///     lights()
    ///     translate(width / 2, height / 2, 0)
    ///     if let head { model(head) }
    /// }
    /// ```
    ///
    /// > Note: 届いたモデルの整え方と見え方は ``loadModel(_:normalize:)`` と同じなので、絵は
    /// > そちらを見ること。届くフレームは実行ごとに違うので、この口だけの絵は撮っていない。
    // shot: 参照 loadModel(_:normalize:)
    public func requestModel(_ path: String, normalize: Bool = true) async throws(ModelFailure)
        -> Model
    {
        try await Self.requireLoadingCanvas("requestModel(_:normalize:)")
            .requestModel(path, normalize: normalize)
    }

    /// 読み込んだモデルを置く。
    ///
    /// いまの変換と塗りと線が効く。**続けて同じモデルを置いても描く回数は増えない** —
    /// 頂点は置き直されず、置き場所だけが増える。線の引かれ方は組み込みの立体と同じで、
    /// 隣り合う面が折れているところと面の縁を通る (``box(_:)`` の但し書き)。光や材質の
    /// 効き方も組み込みの立体と同じである。
    ///
    /// 下の絵は、``loadModel(_:normalize:)`` の例と同じ角錐を 3 つ置き、塗りと線だけを
    /// 変えている。底が見えるように、手前へ傾けて下から見上げている。底の四角は 1 つの面と
    /// して書いてあり、置くときに三角形 2 枚へ割られるが、平らなので割った対角線に線は出ない。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     <!-- example: 文脈 var pyramid: Model! -->
    ///     ```swift
    ///     import Foundation
    ///
    ///     func setup() {
    ///         let obj = """
    ///             v 0 3 0
    ///             v -1 0 -1
    ///             v 1 0 -1
    ///             v 1 0 1
    ///             v -1 0 1
    ///             f 1 5 4
    ///             f 1 4 3
    ///             f 1 3 2
    ///             f 1 2 5
    ///             f 2 3 4 5
    ///             """
    ///         let path = NSTemporaryDirectory() + "pyramid.obj"
    ///         try? obj.write(toFile: path, atomically: true, encoding: .utf8)
    ///         pyramid = try! loadModel(path)
    ///     }
    ///
    ///     func draw() {
    ///         background(23, 26, 31)
    ///         lights()
    ///         strokeWeight(2)
    ///         for column in 0..<3 {
    ///             push()
    ///             translate(75 + column * 125, 150, 0)
    ///             rotateY(0.6)
    ///             rotateX(0.6)
    ///             scale(0.5, 0.5, 0.5)
    ///             if column == 2 { noFill() } else { fill(242, 115, 64) }
    ///             if column == 0 { noStroke() } else { stroke(255) }
    ///             model(pyramid)
    ///             pop()
    ///         }
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 下から見上げた同じ角錐が 3 つ並ぶ。左は橙色の塗りだけ、中は塗りに白い線、右は白い線だけ。線は角錐の稜線だけを通り、中にも右にも、底の四角を割る対角線は出ていない -->
    ///     ![下から見上げた同じ角錐が 3 つ並ぶ。左は橙色の塗りだけ、中は塗りに白い線、右は白い線だけ。線は角錐の稜線だけを通り、中にも右にも、底の四角を割る対角線は出ていない](https://i.gyazo.com/4210828318f8942f99a32979660a7e55.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=84b7a99d
    public func model(_ model: Model) { canvas.model(model) }
}
