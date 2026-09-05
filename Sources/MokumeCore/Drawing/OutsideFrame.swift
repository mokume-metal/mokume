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
            case .light: .lightOutsideFrame
            case .surroundings: .surroundingsOutsideFrame
            case .shadow: .shadowOutsideFrame
            case .material: .materialOutsideFrame
            case .particles: .particlesOutsideFrame
            case .compute: .computeOutsideFrame
            }
        }

        /// 言う中身。**第 2 文は 7 つで共通**で、変わるのは何が無視されたかだけ。
        var notice: String {
            opening + "初期化のときに\(pastVerb)\(subject)はどのフレームにも属さないため、無視しました"
        }

        /// なぜフレームの中で呼ぶのか。**5 つは同じ言い出しを共有する**が、粒と計算は
        /// 「置き直すもの」ではない (出すもの・前置き) ので別の文を持つ。
        private var opening: String {
            switch self {
            case .camera: Self.replacedEachFrame("視点と投影", "置き")
            case .light: Self.replacedEachFrame("光", "置き")
            case .surroundings: Self.replacedEachFrame("周囲", "置き")
            case .shadow: Self.replacedEachFrame("影", "書き")
            case .material: Self.replacedEachFrame("材質", "書き")
            case .particles: "粒は描くところ (draw) で扱います。"
            case .compute: "計算は描くところ (draw) の前置きなので、そこで頼んでください。"
            }
        }

        private static func replacedEachFrame(_ subject: String, _ verb: String) -> String {
            "\(subject)はフレームごとに\(verb)直すものなので、描くところ (draw) で呼んでください。"
        }

        /// 第 2 文が名指すもの。**言い出しの主語とは限らない** — 視点だけは
        /// 「視点と投影」を相手に話しかけてから「視点」を無視したと言う。
        private var subject: String {
            switch self {
            case .camera: "視点"
            case .light: "光"
            case .surroundings: "周囲"
            case .shadow: "影"
            case .material: "材質"
            case .particles: "粒"
            case .compute: "計算"
            }
        }

        /// 「初期化のときに◯◯」の◯◯。置くもの・書くもの・出すもの・頼むもので違う。
        ///
        /// **「た」まで含めて持つ。** 語幹だけにして `\(pastVerb)た` と組むと、音便の
        /// ある動詞が濁らない — 実際に畳んだとき「頼んだ」が「頼んた」になった。
        private var pastVerb: String {
            switch self {
            case .camera, .shadow, .material: "書いた"
            case .light, .surroundings: "置いた"
            case .particles: "出した"
            case .compute: "頼んだ"
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
