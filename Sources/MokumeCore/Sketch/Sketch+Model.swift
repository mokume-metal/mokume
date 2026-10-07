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
    ///
    /// > Note: この口には例の絵が付いていない。読む先のファイルが要るが、このリポジトリは
    /// > 生成物・バイナリを持たないためである。手元の形で試すなら ``box(_:)`` や
    /// > ``sphere(_:detail:)`` を見ること — そちらには絵が付いている。
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
    /// > Note: ``loadModel(_:normalize:)`` と同じ理由で、この口にも例の絵は付いていない。
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
    /// 隣り合う面が折れているところと面の縁を通る (``box(_:)`` の但し書き)。
    ///
    /// > Note: 置く先のモデルがこのリポジトリに無いので、この口にも例の絵は付いていない。
    /// > 光や材質の効き方は組み込みの立体と同じなので、``sphere(_:detail:)`` の絵が
    /// > そのまま参考になる。
    public func model(_ model: Model) { canvas.model(model) }
}
