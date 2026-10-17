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
    /// **シーンの記述 (``placing``・``pixelWrite`` を除く 11 種) の文は、断った場面を名乗らない** —
    /// 「フレームの外で」とだけ言う ([#2723])。断るのは `setup()` の中だけではなく、止まっている間の
    /// コールバック・`Task.detached` の中・走る前・直に使う面の `draw { }` の外でも同じ文が出る。
    /// かつては「`setup()` の間に書いた」と決め打ちしていて、止めた後のコールバックで書いた人に
    /// 直す場所を取り違えさせた。場面ごとに文を変えないのは、鍵が種類ごとで、最初に断った場面の
    /// 文しか出ないからである。
    ///
    /// [#947]: https://github.com/mokume-metal/mokume/issues/947
    /// [#2723]: https://github.com/mokume-metal/mokume/issues/2723
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
                    + "draw(). This camera was placed outside a frame, so it belongs to no frame, "
                    + "and was ignored"
            case .transform:
                "Transforms are written again every frame, so call this from draw(). This "
                    + "transform was written outside a frame, so it belongs to no frame, and was ignored"
            case .style:
                "Pushing and popping style only works inside a frame. This style was pushed outside "
                    + "a frame, so it belongs to no frame, and was ignored"
            case .clip:
                "The clip is written again every frame, so call this from draw(). This clip was "
                    + "written outside a frame, so it belongs to no frame, and was ignored"
            case .effects:
                "Effects are written again every frame, so call this from draw(). These effects "
                    + "were written outside a frame, so they belong to no frame, and were ignored"
            case .light:
                "Lights are placed again every frame, so call this from draw(). This light was "
                    + "placed outside a frame, so it belongs to no frame, and was ignored"
            case .surroundings:
                "The surroundings are placed again every frame, so call this from draw(). These "
                    + "surroundings were placed outside a frame, so they belong to no frame, and were "
                    + "ignored"
            case .shadow:
                "Shadows are written again every frame, so call this from draw(). This shadow was "
                    + "written outside a frame, so it belongs to no frame, and was ignored"
            case .material:
                "Materials are written again every frame, so call this from draw(). This material "
                    + "was written outside a frame, so it belongs to no frame, and was ignored"
            case .particles:
                "Particles are handled where you draw, in draw(). These particles were emitted "
                    + "outside a frame, so they belong to no frame, and were ignored"
            case .compute:
                "Compute is a preamble to drawing, so ask for it from draw(). This compute was "
                    + "asked for outside a frame, so it belongs to no frame, and was ignored"
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
    /// 呼ぶ側は `guard admits(.shadow) else { return }` の形になる。
    /// 守り (``admits(_:)``) はフレームの外と形の組み立ての中を 1 か所で見る (#1529)。
    /// **`guard` そのものは畳んでいない** — 値の検査を挟む口があり、守りと検査の
    /// どちらが先かが口によって違うためである (`Canvas+Material.swift` の口と、
    /// `Canvas+LightColor.swift` の数で書く光・材質の口は検査が先)。
    /// 順序を揃えると診断の出方が変わるので、それは畳みとは別の判断として分ける。
    func warnOutsideFrame(_ subject: OutsideFrame) {
        warnOnce(subject.warning, subject.notice)
    }
}
