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
    /// **鍵は 7 つのまま分けてある** — 光の注意が視点の注意を黙らせないことを
    /// `WarnOnceTests` が契約として見ている。ここが畳むのは文面だけである。
    ///
    /// [#947]: https://github.com/mokume-metal/mokume/issues/947
    enum OutsideFrame: CaseIterable {
        case camera
        case transform
        case style
        case light
        case surroundings
        case shadow
        case material
        case particles
        case compute

        /// 初回だけ言うための鍵。
        var warning: Warning {
            switch self {
            case .camera: .cameraOutsideFrame
            case .transform: .transformOutsideFrame
            case .style: .styleOutsideFrame
            case .light: .lightOutsideFrame
            case .surroundings: .surroundingsOutsideFrame
            case .shadow: .shadowOutsideFrame
            case .material: .materialOutsideFrame
            case .particles: .particlesOutsideFrame
            case .compute: .computeOutsideFrame
            }
        }

        /// 言う中身。**9 通を完全な文として持つ。**
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
                    + "draw(). The camera placed during setup belongs to no frame, and was ignored"
            case .transform:
                "Transforms are written again every frame, so call this from draw(). The "
                    + "transform written during setup belongs to no frame, and was ignored"
            case .style:
                "Pushing and popping style only works inside a frame. The style pushed during "
                    + "setup belongs to no frame, and was ignored"
            case .light:
                "Lights are placed again every frame, so call this from draw(). The light "
                    + "placed during setup belongs to no frame, and was ignored"
            case .surroundings:
                "The surroundings are placed again every frame, so call this from draw(). The "
                    + "surroundings placed during setup belong to no frame, and were ignored"
            case .shadow:
                "Shadows are written again every frame, so call this from draw(). The shadow "
                    + "written during setup belongs to no frame, and was ignored"
            case .material:
                "Materials are written again every frame, so call this from draw(). The "
                    + "material written during setup belongs to no frame, and was ignored"
            case .particles:
                "Particles are handled where you draw, in draw(). The particles emitted during "
                    + "setup belong to no frame, and were ignored"
            case .compute:
                "Compute is a preamble to drawing, so ask for it from draw(). The compute asked "
                    + "for during setup belongs to no frame, and was ignored"
            }
        }
    }

    /// フレームの外で設定を置き直したことを、初回だけ知らせる。
    ///
    /// 呼ぶ側は `guard isDrawing else { return warnOutsideFrame(.shadow) }` の形になる。
    /// **`guard` そのものは畳んでいない** — 値の検査を挟む口があり、`isDrawing` と検査の
    /// どちらが先かが口によって違うためである (`Canvas+Material.swift` だけ検査が先)。
    /// 順序を揃えると診断の出方が変わるので、それは畳みとは別の判断として分ける。
    func warnOutsideFrame(_ subject: OutsideFrame) {
        warnOnce(subject.warning, subject.notice)
    }
}
