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
    /// 読むのは **OBJ (.obj)** だけ。形 (頂点・面・面の向き) だけを読み、材質・
    /// テクスチャ・物体の区切りは読み飛ばす (何行読み飛ばしたかは ``Model/skippedLines``)。
    /// 面の向きが書かれていなければ**形から求める**ので、向きの無いモデルでも
    /// 立体らしく光が付く。
    ///
    /// **既定では、置いたら見える大きさへ整える** (`normalize`)。整えるのは 3 つ —
    /// 中心を原点へ、いちばん長い辺を面の短いほうの半分へ (一様に。軸の比は変わらない)、
    /// 縦軸をこの面の約束 (下向き) へ。`false` を渡すと**ファイルの座標がそのまま**残る。
    ///
    /// **読み込みは投げる。** 失敗したときに別の道を選ぶ判断が要るためで、見つからない
    /// ときの説明には**探した場所**が載る。同じ名前・同じ整え方なら読み直さない。
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
    /// > Note: ``loadModel(_:normalize:)`` と同じ理由で、この口にも例の絵は付いていない。
    public func requestModel(_ path: String, normalize: Bool = true) async throws(ModelFailure)
        -> Model
    {
        try await canvas.requestModel(path, normalize: normalize)
    }

    /// 読み込んだモデルを置く。
    ///
    /// いまの変換と塗りが効く。**続けて同じモデルを置いても描く回数は増えない** —
    /// 頂点は置き直されず、置き場所だけが増える。
    ///
    /// > Note: 置く先のモデルがこのリポジトリに無いので、この口にも例の絵は付いていない。
    /// > 光や材質の効き方は組み込みの立体と同じなので、``sphere(_:detail:)`` の絵が
    /// > そのまま参考になる。
    public func model(_ model: Model) { canvas.model(model) }
}
