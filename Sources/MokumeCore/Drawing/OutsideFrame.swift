// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

extension Canvas {

    /// フレームの外で置き直された設定。**何が無視されたか**を表す。
    ///
    /// 以前はそれぞれのファイルに `warn*OutsideFrame()` が 1 本ずつあり、**同じ事情の
    /// 説明が 7 箇所に写されていた** ([#947])。第 2 文 (「どのフレームにも属さないため
    /// 無視した」) は 7 つとも同型なので、片方だけ言い回しを直すと、同じ事情が口に
    /// よって違う説明になる。
    ///
    /// **鍵は種類ごとに分けたままにしてある** — 光の注意が視点の注意を黙らせないことを
    /// `WarnOnceTests` が契約として見ている。ここが畳むのは文面だけである。
    ///
    /// **シーンの記述 (``placing``・``pixelWrite`` を除く 11 種) の第 2 文は、断った場面を名乗らず、
    /// どの口でも同じ 1 文で「フレームの外で呼ばれた」とだけ言う** ([#2723])。
    ///
    /// - **場面**: 断るのは `setup()` の中だけではない。止まっている間 (`noLoop()`) の入力の
    ///   コールバックでも、面を直に持って呼ぶ形 (直に使う ``Canvas`` の `draw { }` の外など) でも
    ///   同じ文が出る。かつては「`setup()` の間に書いた」と決め打ちしていて、止めた後のコールバックで
    ///   書いた人に直す場所を取り違えさせた。スケッチの語彙を走っていないところ (`Task` の続き
    ///   など) から呼んだときは、面へ届かず、走っていない口の注意 (`OutsideRun`) になる
    /// - **動詞**: 同じ鍵を、種類の違う口が共有する — 光の鍵は `noLights()` も、視点の鍵は
    ///   `perspective()`・`ortho()` も、スタイルの鍵は `popStyle()` も、粒の鍵は `force()`・
    ///   `particles()` も使う。「置いた」「積んだ」「湧かせた」のような口ごとの動詞は、ほかの口で
    ///   偽になるので、どの口でも真の「呼ばれた」にそろえる
    ///
    /// 場面を名乗る文面は、#2723 が文面を直すだけと決めたので別の Issue ([#2780]) に分けた。そこで
    /// 描き場所の面だけ、13 種に共通の 1 文で `beginDraw()` と `endDraw()` を案内する
    /// (``drawingTargetNotice``)。本体の面は上の文のまま — 場面を言い分けない。
    ///
    /// [#947]: https://github.com/mokume-metal/mokume/issues/947
    /// [#2723]: https://github.com/mokume-metal/mokume/issues/2723
    /// [#2780]: https://github.com/mokume-metal/mokume/issues/2780
    enum OutsideFrame: CaseIterable {
        case camera
        case transform
        case style
        case clip
        case effects
        case light
        case surroundings
        case shadow
        case material
        case particles
        case compute
        /// 図形・絵・背景を置いた ([#1672])。**シーンの記述ではない** — 置いたものは、持ち越しを
        /// 約束する区間 (本体の `setup()` と止まっている間のコールバック・描き場所の
        /// `beginDraw()`〜`endDraw()`) ならフレームの外でも置ける。断るのはその外だけなので、
        /// 文面は「`setup()` の間に」ではなく、置ける場面を名乗る。
        ///
        /// [#1672]: https://github.com/mokume-metal/mokume/issues/1672
        case placing
        /// 画素を書いた ([#1672])。書いた画素も次の描き切りで面に載るので、置くことと同じ規則に
        /// 従う (ADR-0021 決定 4 の追補 (2026-09-27))。鍵を ``placing`` と分けるのは、直す先の
        /// 口が違うからである。
        ///
        /// [#1672]: https://github.com/mokume-metal/mokume/issues/1672
        case pixelWrite

        /// **自分でフレームを開く面が断ったときの文。種類ごとに主語を持ち、直し先の案内は 13 種で共通の
        /// 型にする** ([#2780])。自分でフレームを開く面とは、描き場所 (`createGraphics`) と、直に使う
        /// ``Canvas`` (`init(target:gpu:)`) である — ランタイムが持ち越しの区間を約束する本体の面
        /// (``Canvas/isRuntimeSurface``) ではない。
        ///
        /// 本体向けの ``notice`` は、利用者が `draw()` の中に居ても出うるこの面では直す場所を取り違えさせ、
        /// 本当の直し先 (`beginDraw()` と `endDraw()` の間・`draw { }` の中) をどこにも書かない。先頭の主語
        /// (何が断られたか) は ``notice`` と同じ種類名にそろえる — 違う口を呼んだ人が、2 行を見分けられる
        /// ように。**`only works` とは言わない**: この面でも ``Canvas/draw(_:)`` がフレームを開くので、
        /// 直し先は `beginDraw()`〜`endDraw()` だけではない。
        ///
        /// [#2780]: https://github.com/mokume-metal/mokume/issues/2780
        var drawingTargetNotice: String {
            let subject: String
            switch self {
            case .camera: subject = "The camera and projection are placed again every frame"
            case .transform: subject = "Transforms are written again every frame"
            case .style: subject = "Pushing and popping style only works inside a frame"
            case .clip: subject = "The clip is written again every frame"
            case .effects: subject = "Effects are written again every frame"
            case .light: subject = "Lights are placed again every frame"
            case .surroundings: subject = "The surroundings are placed again every frame"
            case .shadow: subject = "Shadows are written again every frame"
            case .material: subject = "Materials are written again every frame"
            case .particles: subject = "Particles are handled where you draw"
            case .compute: subject = "Compute is a preamble to drawing"
            case .placing: subject = "Shapes, images and backgrounds are placed inside a frame"
            case .pixelWrite: subject = "Pixels are written inside a frame"
            }
            return subject + ". " + Self.drawingTargetTail
        }

        /// ``drawingTargetNotice`` の、13 種で共通の直し先の案内。
        static let drawingTargetTail =
            "On a surface you open yourself, call this between beginDraw() and endDraw(), or "
            + "inside its draw { }. This was called outside them, so it belongs to no frame, and "
            + "was ignored"

        /// 初回だけ言うための鍵。
        var warning: Warning {
            switch self {
            case .camera: .cameraOutsideFrame
            case .transform: .transformOutsideFrame
            case .style: .styleOutsideFrame
            case .clip: .clipOutsideFrame
            case .effects: .effectsOutsideFrame
            case .light: .lightOutsideFrame
            case .surroundings: .surroundingsOutsideFrame
            case .shadow: .shadowOutsideFrame
            case .material: .materialOutsideFrame
            case .particles: .particlesOutsideFrame
            case .compute: .computeOutsideFrame
            case .placing: .placingOutsideFrame
            case .pixelWrite: .pixelWriteOutsideFrame
            }
        }

        /// 言う中身。**種類ごとの 1 文を、完全な文として持つ。**
        ///
        /// かつては `opening` +「初期化のときに」+ `pastVerb` + `subject` +「はどのフレーム
        /// にも属さないため、無視しました」の 3 スロットで組んでいた。**その形は語順と助詞に
        /// 依存していて、語順の違う言語では成り立たない** (ADR-0038 決定 3)。
        ///
        /// **日本語のままでも一度事故っている。** `pastVerb` を語幹だけにして `\(pastVerb)た`
        /// と組んだとき、音便のある動詞が濁らず「頼んだ」が「頼んた」になった。骨組みを
        /// 共有する節約より、1 文ずつ読めることを採る。
        var notice: String {
            switch self {
            case .camera:
                "The camera and projection are placed again every frame, so call this from "
                    + "draw(). This was called outside a frame, so it belongs to no frame, and was "
                    + "ignored"
            case .transform:
                "Transforms are written again every frame, so call this from draw(). This was "
                    + "called outside a frame, so it belongs to no frame, and was ignored"
            case .style:
                "Pushing and popping style only works inside a frame. This was called outside a "
                    + "frame, so it belongs to no frame, and was ignored"
            case .clip:
                "The clip is written again every frame, so call this from draw(). This was "
                    + "called outside a frame, so it belongs to no frame, and was ignored"
            case .effects:
                "Effects are written again every frame, so call this from draw(). This was "
                    + "called outside a frame, so it belongs to no frame, and was ignored"
            case .light:
                "Lights are placed again every frame, so call this from draw(). This was "
                    + "called outside a frame, so it belongs to no frame, and was ignored"
            case .surroundings:
                "The surroundings are placed again every frame, so call this from draw(). This "
                    + "was called outside a frame, so it belongs to no frame, and was ignored"
            case .shadow:
                "Shadows are written again every frame, so call this from draw(). This was "
                    + "called outside a frame, so it belongs to no frame, and was ignored"
            case .material:
                "Materials are written again every frame, so call this from draw(). This was "
                    + "called outside a frame, so it belongs to no frame, and was ignored"
            case .particles:
                "Particles are handled where you draw, in draw(). This was called outside a "
                    + "frame, so it belongs to no frame, and was ignored"
            case .compute:
                "Compute is a preamble to drawing, so ask for it from draw(). This was called "
                    + "outside a frame, so it belongs to no frame, and was ignored"
            case .placing:
                "Shapes, images and backgrounds are placed in setup(), draw() or an input "
                    + "callback, or between beginDraw() and endDraw() on a drawing target. This was "
                    + "placed outside all of them, so it belongs to no frame, and was ignored"
            case .pixelWrite:
                "Pixels are written in setup(), draw() or an input callback, or between "
                    + "beginDraw() and endDraw() on a drawing target. This pixel was written "
                    + "outside all of them, so it belongs to no frame, and was ignored"
            }
        }
    }

    /// フレームの外で設定を置き直したことを、初回だけ知らせる。
    ///
    /// **文は面で選ぶ** ([#2780])。ランタイムの面 (``isRuntimeSurface``) の外 — 描き場所
    /// (`createGraphics`) と、直に使う ``Canvas`` — は、自分でフレームを開く。描き場所は `draw()` の
    /// 中に居ても `beginDraw()`〜`endDraw()` の外ならフレームの外で (`isDrawing` は面ごとに持つ)、直に使う
    /// 面も `setup()` や入力のコールバックを持たない。本体向けの「call this from draw()」「placed in
    /// setup(), draw() or an input callback」を言うと、すでに `draw()` の中に居る利用者に直す場所を取り
    /// 違えさせるので、そちらには ``OutsideFrame/drawingTargetNotice`` を言う。控えは面ごとなので、その面の
    /// 1 通は必ずその面の場面で出る。ランタイムの面の文は変えない。
    ///
    /// [#2780]: https://github.com/mokume-metal/mokume/issues/2780
    ///
    /// 呼ぶ側は `guard admits(.shadow) else { return }` の形になる。
    /// 守り (``admits(_:)``) はフレームの外と形の組み立ての中を 1 か所で見る (#1529)。
    /// **`guard` そのものは畳んでいない** — 値の検査を挟む口があり、守りと検査の
    /// どちらが先かが口によって違うためである (`Canvas+Material.swift` の口と、
    /// `Canvas+LightColor.swift` の数で書く光・材質の口は検査が先)。
    /// 順序を揃えると診断の出方が変わるので、それは畳みとは別の判断として分ける。
    func warnOutsideFrame(_ subject: OutsideFrame) {
        let opensItsOwnFrames = !isRuntimeSurface
        warnOnce(
            subject.warning,
            opensItsOwnFrames ? subject.drawingTargetNotice : subject.notice)
    }
}
