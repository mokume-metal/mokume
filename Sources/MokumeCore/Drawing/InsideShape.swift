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
    /// - 描き切りそのものは断れない口がある。揺らぎの設定の書き換えと置いた描き場所の描き換えは、
    ///   置いた時点のものを列が持ち歩くので描き切らず、組み立ての中で自分のフレームを閉じること
    ///   (`endDraw()`) は出口まで待たせる ([#1855]・``frameEnd``)。それでも描き切るか捨てる道が残り、
    ///   そこは出口が見て、空の形を返す (``drawnOut``)
    /// - 組み立ての中で自分のフレームを始めること (`beginDraw()`・`draw { }`) は、呼ばれた時点で断る
    ///   ([#2201]・``frameStart``)。始めると、閉じ忘れたフレームとして、またはフレームの外で置いたものと
    ///   して、組み立てた分が捨てられていた
    /// - 形に焼き付かない設定 (シーンの記述と、露出・明るさの丸め方) も、呼ばれた時点で断る
    ///   ([#1529] の案 A)。フレームの中で組み立てても `setup()` で組み立てても同じ扱いで、守りは
    ///   ``Canvas/admits(_:)`` の 1 つである
    ///
    /// 文面は ``OutsideFrame`` と同じく、種類ごとの完全な 1 文で持つ (ADR-0038 決定 3)。
    /// **鍵も種類ごとに分ける** — 光の注意が視点の注意を黙らせない (``OutsideFrame`` と同じ契約)。
    ///
    /// [#1588]: https://github.com/mokume-metal/mokume/issues/1588
    /// [#1529]: https://github.com/mokume-metal/mokume/issues/1529
    /// [#1855]: https://github.com/mokume-metal/mokume/issues/1855
    /// [#2201]: https://github.com/mokume-metal/mokume/issues/2201
    enum InsideShape: CaseIterable {
        /// 塗り直した。塗り 1 色の背景と周囲の背景の 2 系統が鍵を共有する。
        case background
        /// 画素を読み書きした。`get` / `set` / `pixels` / `loadPixels()` の 4 つが鍵を共有する。
        case pixels
        /// 記録の途中で溜め場が描き切られるか捨てられ、記録したものを失った。**出口の安全網**が言う。
        ///
        /// [#1855] で、揺らぎの設定の書き換え (列ごとに写す)・置いた描き場所の描き換え (組み立ての
        /// 入口より前の列だけを写しへ差し替える)・組み立ての中で自分のフレームを閉じること (`endDraw()`。
        /// 出口まで待たせる・``frameEnd``) は来なくなった。[#2201] で、組み立ての中で自分のフレームを始める
        /// こと (`beginDraw()`・`draw { }`。断る・``frameStart``) も来なくなった。[#2509] で、描き場所の
        /// 組み立ての中で本体のフレームが始まること (スケッチの `canvas.beginDraw()` / `canvas.draw { }`、
        /// `Canvas` を直に回す使い方) も来なくなった — 本体のフレームの始まりは、組み立て中の描き場所の
        /// 開いたままのフレームを閉じ忘れとして捨てず (#1834 の捨てる規則から組み立て中の面を除いた)、
        /// 出口まで開いたまま待たせる。残る経路は 1 つ:
        ///
        /// - 同じフレームで置いた描き場所の描き換えのうち、置いた側がもう 1 枚の写しを持てなかったもの
        ///   (写しの上限 ``Canvas/placedPictureCopyLimit`` に達したか、写しを用意できなかった)。置いた時点の
        ///   絵を守るほうを取って描き切るので、それまでに組み立てたぶんはフレームに描かれる
        ///
        /// 描き切り (捨てる) そのものは断れない (#1684)。
        ///
        /// [#2201]: https://github.com/mokume-metal/mokume/issues/2201
        /// [#2509]: https://github.com/mokume-metal/mokume/issues/2509
        case drawnOut
        /// 組み立ての中で、組み立ての前に開いた自分のフレームを `endDraw()` で閉じようとした ([#1855] の
        /// 案 G)。**フレームはその時点では閉じず、一番外の組み立ての出口で閉じる** (``Canvas/createShape(_:)``)。
        /// 閉じると組み立てた区間ごと描き切られ、形が空になっていた。出口までは、その面はまだ描いている扱い
        /// である — 別の面へ置くと前の絵を読む。組み立ての残りで `beginDraw()` か `draw { }` を呼ぶと、持ち主
        /// の面でも描き場所でも、フレームを始め直さずに ``frameStart`` で断る ([#2201])。
        ///
        /// 組み立ての中の `draw { }` は、組み立ての前に開いたフレームの中なら続きとして走って閉じず、そう
        /// でなければフレームを始めずに断る (``frameStart``) ので、閉包の終わりがここへ来ることは無い。
        ///
        /// [#1855]: https://github.com/mokume-metal/mokume/issues/1855
        /// [#2201]: https://github.com/mokume-metal/mokume/issues/2201
        case frameEnd
        /// 組み立ての中で、組み立てている面のフレームを始めようとした ([#2201])。`beginDraw()` と
        /// `draw { }` の 2 つが鍵を共有する。**フレームは始めない** — `beginDraw()` は何もせず、`draw { }` は
        /// 閉包をいまの続き (組み立ての中) として走らせる。組み立ての中の `endDraw()` も、閉じるフレームが
        /// 無ければ同じ鍵で断る (始めなかった `beginDraw()` と対で呼ばれる)。
        ///
        /// 断るのは、その呼び出しがフレームを始めることになるときである: フレームの外に居る・閉じ忘れたまま
        /// 境目を越えた (持ち主の面では `beginDraw()` で開いたフレームがいつもこれに当たる)・組み立ての中で
        /// 閉じるのを待たせた (``frameEnd``)。始めると、開いたままのフレームを閉じ忘れとして捨てるか、
        /// フレームの頭の検めがそれまでの記録を「フレームの外で置いたもの」として捨て、形が空になっていた。
        /// 組み立ての前に開いたフレームがそのまま続くとき (``Canvas/draw(_:)`` の中・同じ本体のフレームの
        /// 中の描き場所) は、今までどおり開いたフレームの続きとして扱う。
        ///
        /// 断るのは**組み立てている面自身**のフレームだけで、別の面の組み立ての中で描き場所を開いて閉じる
        /// のは今までどおりである (``recordingShape`` は面ごと)。
        ///
        /// [#2201]: https://github.com/mokume-metal/mokume/issues/2201
        case frameStart
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
            case .background, .pixels, .drawnOut, .frameEnd, .frameStart, .brightness: nil
            }
        }

        /// 初回だけ言うための鍵。
        var warning: Warning {
            switch self {
            case .background: .backgroundInsideShape
            case .pixels: .pixelsInsideShape
            case .drawnOut: .shapeDrawnOutWhileBuilding
            case .frameEnd: .frameEndInsideShape
            case .frameStart: .frameStartInsideShape
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
                    + "drawing target placed earlier was changed when this canvas could not keep one "
                    + "more copy of it), so what was built up to then was drawn into the frame, and "
                    + "the shape is empty. Do that before or after building the shape"
            case .frameEnd:
                "createShape { }: the frame of the canvas being built on was closed inside the shape "
                    + "by endDraw(), so it stays open until the shape is finished and closes there; "
                    + "until then the canvas is still drawing. Close it after building the shape"
            case .frameStart:
                "createShape { }: a frame of the canvas being built on was started inside the shape "
                    + "(by beginDraw() or draw { }). Starting it would drop what was built, so it was "
                    + "not started: beginDraw() does nothing there, nor does an endDraw() with no frame "
                    + "to close, and draw { } runs its block as part of the shape. Start the frame "
                    + "before or after building the shape"
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
