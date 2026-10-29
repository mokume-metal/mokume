// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Metal

/// 断片へ渡せる面。
///
/// 値 (``ShaderValue``) と型を分けてある。**詰め先が違う**からで、値は列ごとの 1 区画へ
/// 詰められるが、面は口へ割り当てるしかない ([#407](https://github.com/mokume-metal/mokume/issues/407))。
/// 1 つの辞書に混ぜると、詰める側 (`ShaderSource.pack`) に「これは詰めない」という
/// 分岐が並ぶことになる。
///
/// 受けるのは**読み込んだ絵と、自分で描いた面の両方**である — 貼る口 (``Canvas/texture(_:)-(Image)``)
/// が両方を受けるのと揃えてある。出どころで型を分けると、面を差し替えるだけのコードが
/// 出どころの数だけ増える。
public enum ShaderSurface {
    /// 読み込んだ (あるいは画素から作った) 絵。
    case image(Image)
    /// 自分で描いた場所。
    case graphics(Canvas)
    /// **この塗りを当てた面の、前のフレームの絵。** 残像やフィードバック (前の絵を少し薄めて、ずらして、
    /// 描き足す) を、描き場所 2 枚の入れ替えなしで書ける。
    ///
    /// 「前の絵」は、**その面が次のフレームへ持ち越す絵**である ([ADR-0021] 決定 4)。
    ///
    /// - フレームの終わりの `effects()` を通す**前**の絵で、効果を 2 度掛けしない。`effects()` を通した絵は
    ///   画面に出るだけで、ここには入らない。呼んだ時点で掛ける `filter()` が焼き込んだ分は、持ち越す絵に
    ///   入るので前の絵に入る
    /// - `noLoop()` の後に `redraw()` を呼んだときは、**最後に描いた枚** (止まっている間のコールバックが
    ///   足した分を含む)
    /// - **1 枚目は透明**。何も描いていない面の初期値である
    /// - 画素は描く画素の面のもの。`pixelDensity` を下げれば、前の絵も描く細かさになる。`mokume_sample` の座標は
    ///   0〜1 なので、断片は細かさに依らない
    /// - 描き場所 (``SketchPart/createGraphics(_:_:)``) に当てれば、読むのはその描き場所の前の絵で、本体の絵ではない
    ///
    /// **先に `background()` で消してから読んでよい。** 前の絵は、そのフレームが描き始める前に取るからで、
    /// 消す前の絵を読める。消さずに重ねると、前の絵と混ざって薄まらない。
    ///
    /// <!-- example: 文脈 var echo: Shader! -->
    /// ```swift
    /// func setup() {
    ///     // 前の絵を、中心へ 2% 寄せて 4% 薄めて読む。マウスで置いた円が、吸い込まれながら色が抜ける
    ///     echo = try! createShader(
    ///         """
    ///         float4 paint(Fragment in, Values values, Surfaces surfaces) {
    ///             float2 p = (in.place - 0.5) * 0.98 + 0.5;
    ///             return mokume_sample(surfaces.last, p) * 0.96;
    ///         }
    ///         """,
    ///         surfaces: ["last": .previousFrame])
    /// }
    ///
    /// func draw() {
    ///     background(0)
    ///     noStroke()
    ///     shader(echo)
    ///     rect(0, 0, width, height)
    ///     resetShader()
    ///     fill(255, 140, 60)
    ///     circle(mouseX, mouseY, 30)
    /// }
    /// ```
    ///
    /// **費用**: 使う面ごとに、面と同じ大きさの写しが 1 枚増え、毎フレーム全面の写しを 1 回払う。払うのは
    /// この面を宣言した塗りを**当てた**面だけで、宣言しない面と、宣言しても当てていない面は何も払わない
    /// (当てたフレームの次のフレームも、描き始める前に写しを取る)。決定論は保たれる — 前の枚はフレーム番号から決まる。
    /// 1 つのフレームの中で、`loadPixels()` などの描き切りの**後**に初めて当てると、その枚だけは前のフレームの絵では
    /// なく、その時点の絵を読む。
    ///
    /// 手本は Hydra の `src(o0)`・TouchDesigner の Feedback TOP・Shadertoy の自分自身を読むバッファである
    /// (p5.js 2.x・openFrameworks・Cinder は、描き場所 2 枚を手で入れ替える)。
    /// 時間方向に拡大する `Upscale.temporal` が持つ ``Canvas/usesFrameHistory`` は、拡大のための別の仕組みで、
    /// この面とは関係しない。
    ///
    /// [ADR-0021]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0021-solid-space-and-frame-assembly.md
    case previousFrame

    /// 内側の受け口へ畳む。**下位の描画資源は面に出さない** ([ADR-0024] 決定 8)。
    ///
    /// 前のフレームの絵 (``previousFrame``) は、読む面ごとに決まるので受け口を持たない (`nil`)。
    ///
    /// [ADR-0024]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0024-extension-seams.md
    var picture: Picture? {
        switch self {
        case .image(let image): .loaded(image)
        case .graphics(let canvas): .drawn(canvas.output)
        case .previousFrame: nil
        }
    }

    /// いま読める面を、持ち主と組にして返す。**読む直前に整えてから返す** — 書き換えた
    /// 画素があればここで送りを頼み、描き切りが届ける。区間は面だけでなく持ち主も
    /// 写し取る (`HeldTexture`)。
    ///
    /// - Parameter canvas: 塗りを当てる面。前のフレームの絵は、この面の写しを読む。
    func held(reading canvas: Canvas) -> HeldTexture {
        guard let picture else { return canvas.previousFrameHeld() }
        picture.prepare()
        return picture.held
    }
}
