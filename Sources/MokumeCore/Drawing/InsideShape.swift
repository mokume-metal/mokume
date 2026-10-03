// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

extension Canvas {

    /// 形の組み立て (``createShape(_:)``) の中では効かないもの。**何が効かなかったか**を表す ([#1588])。
    ///
    /// 組み立ては入口で溜め場の長さを控え、出口でそこから先を形として抜く。**溜め場を描き切る・
    /// 捨てる口を記録の途中で通すと、控えた区間が溜め場の外を指す** — 出口の切り出しが
    /// `Range requires lowerBound <= upperBound` で落ちていた。直す先は口ごとに分かれる。
    ///
    /// - 塗り直し (``background``) と画素の口 (``pixels``) は、呼ばれた時点で断る。どちらも形に
    ///   焼き付く先が無い — 塗り直しは面全体を描き直すことで、画素はまだ描いていない形を読めない
    /// - 描き切りそのものは断れない口がある (置いた描き場所の描き換え・揺らぎの設定の書き換え・
    ///   描き場所の組み立ての中の `endDraw()`)。そこは出口が見て、空の形を返す (``drawnOut``)
    /// - 形に焼き付かない設定 (シーンの記述と、露出・明るさの丸め方) も、呼ばれた時点で断る
    ///   ([#1529] の案 A)。フレームの中で組み立てても `setup()` で組み立てても同じ扱いで、守りは
    ///   ``Canvas/admits(_:)`` の 1 つである
    ///
    /// 文面は ``OutsideFrame`` と同じく、種類ごとの完全な 1 文で持つ (ADR-0038 決定 3)。
    /// **鍵も種類ごとに分ける** — 光の注意が視点の注意を黙らせない (``OutsideFrame`` と同じ契約)。
    ///
    /// [#1588]: https://github.com/mokume-metal/mokume/issues/1588
    /// [#1529]: https://github.com/mokume-metal/mokume/issues/1529
    enum InsideShape: CaseIterable {
        /// 塗り直した。塗り 1 色の背景と周囲の背景の 2 系統が鍵を共有する。
        case background
        /// 画素を読み書きした。`get` / `set` / `pixels` / `loadPixels()` の 4 つが鍵を共有する。
        case pixels
        /// 記録の途中で溜め場が描き切られ、記録したものを失った。**出口の安全網**が言う。
        ///
        /// 来る経路は 3 つ: 同じフレームで置いた描き場所の描き換え (`endDraw()` などが置いた側を
        /// 描き切らせる)・揺らぎの設定の書き換え (`noiseSeed()` / `noiseDetail()`・#1855)・描き場所
        /// の組み立ての中で自分の `endDraw()` を呼ぶこと。どれも描き切りそのものは断れないので、
        /// 描き切りまでに組み立てたぶんはフレームに描かれる (#1684)。
        case drawnOut
        /// 視点・投影を書いた。
        case camera
        /// 切り抜きを書いた。切り抜きは描画先の座標で効くので、形と一緒に持ち運べない。
        case clip
        /// 効果を頼んだ。
        case effects
        /// 光を置いた・外した。
        case light
        /// 周囲の光を置いた。
        case surroundings
        /// 影を書いた (落とす・受ける・範囲・細かさ・ずらし)。
        case shadow
        /// 材質を書いた。
        case material
        /// 粒を進めた・描いた・力を掛けた・湧かせた。
        case particles
        /// 計算を頼んだ。
        case compute
        /// 露出か明るさの丸め方を書いた。**描き方なのでフレームの外でも効く**が、面全体の明るさを
        /// 決めるもので形には焼き付かない ([#1529] の条件 3)。
        ///
        /// [#1529]: https://github.com/mokume-metal/mokume/issues/1529
        case brightness

        /// フレームの外で書いたときに言う種類。**フレームに属するものだけが持つ** — 露出と明るさの
        /// 丸め方はフレームの外でも効き、塗り直しと画素の口はフレームの外での扱いを口が自分で持つ。
        var outsideFrame: OutsideFrame? {
            switch self {
            case .camera: .camera
            case .clip: .clip
            case .effects: .effects
            case .light: .light
            case .surroundings: .surroundings
            case .shadow: .shadow
            case .material: .material
            case .particles: .particles
            case .compute: .compute
            case .background, .pixels, .drawnOut, .brightness: nil
            }
        }

        /// 初回だけ言うための鍵。
        var warning: Warning {
            switch self {
            case .background: .backgroundInsideShape
            case .pixels: .pixelsInsideShape
            case .drawnOut: .shapeDrawnOutWhileBuilding
            case .camera: .cameraInsideShape
            case .clip: .clipInsideShape
            case .effects: .effectsInsideShape
            case .light: .lightInsideShape
            case .surroundings: .surroundingsInsideShape
            case .shadow: .shadowInsideShape
            case .material: .materialInsideShape
            case .particles: .particlesInsideShape
            case .compute: .computeInsideShape
            case .brightness: .brightnessInsideShape
            }
        }

        /// 言う中身。
        var notice: String {
            switch self {
            case .background:
                "background() does nothing inside createShape { }. A shape cannot hold a repaint "
                    + "of the whole surface, so call it before or after building the shape"
            case .pixels:
                "Pixels are not read or written inside createShape { }, because what is built "
                    + "there has not been drawn yet. There, get() returns transparent, set() and "
                    + "loadPixels() do nothing, and pixels is not read again"
            case .drawnOut:
                "createShape { }: the frame was drawn out while the shape was being built (a "
                    + "drawing target placed earlier in the frame was changed, the noise settings "
                    + "changed, or endDraw() was called), so what was built up to then went into "
                    + "the frame and the shape is empty. Do those before or after building the shape"
            case .camera:
                "The camera and projection do nothing inside createShape { }. A shape cannot hold "
                    + "a camera, so place it before or after building the shape"
            case .clip:
                "The clip does nothing inside createShape { }. A clip works in the coordinates of "
                    + "the surface, so a shape cannot hold it. Write it before or after building the shape"
            case .effects:
                "Effects do nothing inside createShape { }. A shape cannot hold effects, so write "
                    + "them before or after building the shape"
            case .light:
                "Lights do nothing inside createShape { }. A shape cannot hold a light, so place "
                    + "it before or after building the shape"
            case .surroundings:
                "The surroundings do nothing inside createShape { }. A shape cannot hold them, so "
                    + "place them before or after building the shape"
            case .shadow:
                "Shadows do nothing inside createShape { }. A shape cannot hold how shadows are "
                    + "cast or received, so write it before or after building the shape"
            case .material:
                "Materials do nothing inside createShape { }. A shape cannot hold a material, so "
                    + "write it before or after building the shape"
            case .particles:
                "Particles are not moved or drawn inside createShape { }. A shape cannot hold "
                    + "them, so handle them before or after building the shape"
            case .compute:
                "Compute is not run inside createShape { }. A shape cannot hold it, so ask for it "
                    + "before or after building the shape"
            case .brightness:
                "exposure() and toneMapping() do nothing inside createShape { }. They set the "
                    + "brightness of the whole surface, which a shape cannot hold, so call them "
                    + "before or after building the shape"
            }
        }
    }

    /// 組み立ての中で効かなかったことを、初回だけ知らせる。
    func warnInsideShape(_ subject: InsideShape) {
        warnOnce(subject.warning, subject.notice)
    }

    /// 形に焼き付かない設定を、いま書いてよいか。**書けなければ、なぜ効かないかを種類ごとに
    /// 1 度知らせて `false` を返す** ([#1529]・[#1684])。
    ///
    /// 呼ぶ側は `guard admits(.light) else { return }` の形になる。
    ///
    /// - フレームに属するもの (``InsideShape/outsideFrame`` を持つもの) は、フレームの外では
    ///   ``OutsideFrame`` の注意を言う。**`setup()` の中の組み立てもこちら**で、組み立ての外の
    ///   `setup()` と同じ文面になる
    /// - フレームの中でも、形の組み立ての中では ``InsideShape`` の注意を言う
    ///
    /// 以前は口ごとに `guard isDrawing` だけを見ていた。`draw()` の中で組み立てると守りを
    /// 素通りし、`Style` に入っている切り抜き・材質・影の落とし方は形にも入らず出口で黙って消え、
    /// 光・視点・効果などはそのフレームにそのまま効いていた — 組み立てる場所で扱いが割れていた
    /// ([#1529])。守りを 1 つにしたので、口を足すときはこれを通せば両方の場面が揃う。
    ///
    /// [#1529]: https://github.com/mokume-metal/mokume/issues/1529
    /// [#1684]: https://github.com/mokume-metal/mokume/issues/1684
    func admits(_ subject: InsideShape) -> Bool {
        if let outside = subject.outsideFrame, !isDrawing {
            warnOutsideFrame(outside)
            return false
        }
        guard !recordingShape else {
            warnInsideShape(subject)
            return false
        }
        return true
    }
}
