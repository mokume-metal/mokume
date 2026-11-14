// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

// 画像。
extension SketchPart {
    /// 画像を読む。読み終わるまで返らない。
    ///
    /// <!-- example: 文脈 var grain: Image? -->
    /// ```swift
    /// func setup() throws {
    ///     grain = try loadImage("assets/grain.png")
    /// }
    /// ```
    ///
    /// **読み込みは投げる。** 読めなかったときに別の方法を選ぶ判断が要るので、黙って
    /// 既定値にフォールバックしない。見つからないときの説明には**探した場所**が載る。
    ///
    /// 名前は、作業ディレクトリと**実行ファイルの隣に置かれたアセットのバンドル**から探す
    /// (`/` で始まる名前は、その場所だけを読む)。
    /// スケッチのパッケージがアセットの置き場所を宣言していないと、ビルドは静かに通って
    /// 実行時に読めないだけになるので、宣言を確かめること。
    ///
    /// **読んだ画像は、ファイルの画素数のまま置かれる。** 下の 3 枚は、右へ行くほど赤く、
    /// 下へ行くほど青い画像を例がその場で PNG に書き出し、読んで ``image(_:_:_:)-(Image,_,_)``
    /// で等倍に置いたもので、変えたのは書き出す画像の縦横だけである。下の文字は、読んだ画像の
    /// ``Image/width`` と ``Image/height``。このリポジトリは画像のファイルを持たないので、
    /// 読む先は例が自分で作っている。画像を手続きで作るだけなら、書き出さずに
    /// ``createImage(_:_:)`` で作れる。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     <!-- example: 文脈 var tile: Image? -->
    ///     ```swift
    ///     import Foundation
    ///
    ///     func setup() throws {
    ///         // 横 120・縦 80 画素の絵を、一時ディレクトリへ PNG で書き出す
    ///         let (w, h) = (120, 80)
    ///         var bytes: [UInt8] = []
    ///         for y in 0..<h {
    ///             for x in 0..<w {
    ///                 bytes += [UInt8(255 * x / (w - 1)), 90, UInt8(255 * y / (h - 1)), 255]
    ///             }
    ///         }
    ///         let path = NSTemporaryDirectory() + "tile-\(w)x\(h).png"
    ///         let picture = DisplayImage(width: w, height: h, bytes: bytes)
    ///         try PNGFile.write(picture, to: URL(fileURLWithPath: path))
    ///
    ///         tile = try loadImage(path)
    ///     }
    ///
    ///     func draw() {
    ///         background(23, 26, 31)
    ///         guard let tile else { return }
    ///         image(tile, 40, 40)
    ///         fill(242, 242, 242)
    ///         textSize(24)
    ///         text("\(tile.width) × \(tile.height)", 40, 270)
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 右へ行くほど赤く、下へ行くほど青い横 120・縦 80 画素の画像が等倍で置かれ、下に 120 × 80 と出る -->
    ///     ![右へ行くほど赤く、下へ行くほど青い横 120・縦 80 画素の画像が等倍で置かれ、下に 120 × 80 と出る](https://i.gyazo.com/6a1fc85b39b44b4d02d24a48f4fb623d.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     <!-- example: 文脈 var tile: Image? -->
    ///     ```swift
    ///     import Foundation
    ///
    ///     func setup() throws {
    ///         // 横だけ 2 倍の 240 画素にする
    ///         let (w, h) = (240, 80)
    ///         var bytes: [UInt8] = []
    ///         for y in 0..<h {
    ///             for x in 0..<w {
    ///                 bytes += [UInt8(255 * x / (w - 1)), 90, UInt8(255 * y / (h - 1)), 255]
    ///             }
    ///         }
    ///         let path = NSTemporaryDirectory() + "tile-\(w)x\(h).png"
    ///         let picture = DisplayImage(width: w, height: h, bytes: bytes)
    ///         try PNGFile.write(picture, to: URL(fileURLWithPath: path))
    ///
    ///         tile = try loadImage(path)
    ///     }
    ///
    ///     func draw() {
    ///         background(23, 26, 31)
    ///         guard let tile else { return }
    ///         image(tile, 40, 40)
    ///         fill(242, 242, 242)
    ///         textSize(24)
    ///         text("\(tile.width) × \(tile.height)", 40, 270)
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 横だけ 240 画素にして書き出すと、置かれた画像も高さはそのままで横幅が 2 倍になり、下に 240 × 80 と出る -->
    ///     ![横だけ 240 画素にして書き出すと、置かれた画像も高さはそのままで横幅が 2 倍になり、下に 240 × 80 と出る](https://i.gyazo.com/6760474cf06f998d5c964f883273a83c.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     <!-- example: 文脈 var tile: Image? -->
    ///     ```swift
    ///     import Foundation
    ///
    ///     func setup() throws {
    ///         // 縦だけ 2 倍の 160 画素にする
    ///         let (w, h) = (120, 160)
    ///         var bytes: [UInt8] = []
    ///         for y in 0..<h {
    ///             for x in 0..<w {
    ///                 bytes += [UInt8(255 * x / (w - 1)), 90, UInt8(255 * y / (h - 1)), 255]
    ///             }
    ///         }
    ///         let path = NSTemporaryDirectory() + "tile-\(w)x\(h).png"
    ///         let picture = DisplayImage(width: w, height: h, bytes: bytes)
    ///         try PNGFile.write(picture, to: URL(fileURLWithPath: path))
    ///
    ///         tile = try loadImage(path)
    ///     }
    ///
    ///     func draw() {
    ///         background(23, 26, 31)
    ///         guard let tile else { return }
    ///         image(tile, 40, 40)
    ///         fill(242, 242, 242)
    ///         textSize(24)
    ///         text("\(tile.width) × \(tile.height)", 40, 270)
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 縦だけ 160 画素にして書き出すと、置かれた画像も横幅はそのままで高さが 2 倍になり、下に 120 × 160 と出る -->
    ///     ![縦だけ 160 画素にして書き出すと、置かれた画像も横幅はそのままで高さが 2 倍になり、下に 120 × 160 と出る](https://i.gyazo.com/3b4f35e8384933aacf3a4991d3b59f0a.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// **読んだ画像の成分は、描画先が表せる範囲へ移る。** 数でない成分・無限の成分はそのまま残り (図形を描く
    /// 経路が描画先へ移すときと同じ)、有限の成分は描画先が表せる ±65504 で止まる。浮動小数の画像 (TIFF・
    /// OpenEXR など) の、白をずっと越える成分も同じである。
    ///
    /// ## 同じ描画結果は一度しか読まない
    ///
    /// 二度目からは探すのも復号するのも省く ([#886])。**それでも `setup()` で読むこと** —
    /// 返る画像は毎回新しいので、テクスチャを作って送る分は毎回かかる。
    ///
    /// 毎回新しいということは、**読んだ画像を塗り替えても次の読み込みには影響しない**
    /// ということでもある。走らせたままファイルを差し替えれば、次の読み込みからそちらが出る。
    ///
    /// ## URL から読む
    ///
    /// **名前が `http://` か `https://` で始まれば、その URL から受け取る** (Processing の
    /// `loadImage(url)`・[#3715])。他の読み込み (``loadStrings(_:)``・``loadJSONObject(_:)`` など) と同じ
    /// 決まりで、`file://` で始まる名前はファイルの名前として探す。受け取るまで最長 60 秒フレームを止めるので、
    /// 待たない ``requestImage(_:)`` を使うほうがよい。
    ///
    /// <!-- example: 文脈 var photo: Image? -->
    /// ```swift
    /// func setup() throws {
    ///     photo = try loadImage("https://example.com/photo.png")
    /// }
    /// ```
    ///
    /// **URL の画像は、実行のあいだ URL ごとに 1 度だけ受け取る。** 2 度目からは通信せず、1 度目に受け取った
    /// 画像を返す — サーバの側で画像が差し替わっても、走らせている間は拾わない (ファイルと違い、更新を
    /// 確かめる手段を持たない)。拡張子の無い URL は ``loadImage(_:extension:)`` で種類を添えて読める。
    ///
    /// - Throws: 見つからないとき・見つかったが開けないとき (ディレクトリだった・読む権利が無い。解けた
    ///   場所が載る ``ImageFailure/unopenable(path:location:reason:)``)・画像として読めないとき・GPU 側へ
    ///   置けないときに ``ImageFailure``。URL から受け取れなかったとき (繋がらない・時間切れ・2xx 以外の状態)
    ///   は ``ImageFailure/unreachable(url:reason:)`` で、受け取った本文が画像でなければ
    ///   ``ImageFailure/undecodable(path:)``。
    ///   `setup()`・`draw()`・入力のコールバックの外 (初期化子の中・終了処理の後・`Task` の中) で呼ぶと
    ///   ``ImageFailure/notRunning(call:)`` (プロセスは落ちない)。
    ///
    /// [#886]: https://github.com/mokume-metal/mokume/issues/886
    /// [#3715]: https://github.com/mokume-metal/mokume/issues/3715
    // shot: 1 snippet=d21cd07f
    // shot: 2 snippet=75a302ec
    // shot: 3 snippet=1417ff4a
    public func loadImage(_ path: String) throws(ImageFailure) -> Image {
        noticeBlockingLoad("loadImage(_:)", instead: "requestImage(_:)")
        return try resourceCanvas(ImageFailure.self).loadImage(path)
    }

    /// 種類 (拡張子) を添えて画像を読む。読み終わるまで返らない。
    ///
    /// Processing の `loadImage(filename, extension)` に当たる。URL が拡張子で終わらず、中身からも種類が
    /// 分からないときのための形で、`extension` は `"png"`・`"jpg"` のように点を付けずに渡す。
    ///
    /// <!-- example: 文脈 var photo: Image? -->
    /// ```swift
    /// func setup() throws {
    ///     photo = try loadImage("https://example.com/photo", extension: "png")
    /// }
    /// ```
    ///
    /// **種類は手がかりで、中身に勝たない。** 中身の先頭から種類が分かる画像 (PNG・JPEG など) は、渡した
    /// 種類によらず中身のとおりに読む。手がかりが効くのは、中身に種類の印の無い形式 (TGA など) だけである。
    /// 知らない種類を渡したときは、手がかり無しで中身から読む。ファイルの名前にも同じく効く。
    ///
    /// 探し方・URL の扱い・控えは ``loadImage(_:)`` と同じ。**控えの鍵は名前だけ**なので、同じ名前を
    /// 種類を変えて読み直しても、2 度目は 1 度目の画像を返す。
    ///
    /// - Throws: ``loadImage(_:)`` と同じ (``ImageFailure``)。
    // shot: 参照 loadImage(_:)
    public func loadImage(_ path: String, extension: String) throws(ImageFailure) -> Image {
        noticeBlockingLoad("loadImage(_:extension:)", instead: "requestImage(_:extension:)")
        return try resourceCanvas(ImageFailure.self).loadImage(path, extension: `extension`)
    }

    /// 画像を読む。**読んでいる間、他の仕事を止めない。**
    ///
    /// 復号を別の仕事として回すので、大きな画像を読んでもフレームが詰まらない。
    ///
    /// **読んだ画像の成分は、描画先が表せる範囲へ移る。** 数でない成分・無限の成分はそのまま残り (図形を描く
    /// 経路が描画先へ移すときと同じ)、有限の成分は描画先が表せる ±65504 で止まる。浮動小数の画像 (TIFF・
    /// OpenEXR など) の、白をずっと越える成分も同じである。
    ///
    /// **`setup()` の中で `Task` を起動し、そこから呼ぶ。** `setup()` も ``Sketch/draw()`` も
    /// 待てないので、待つのは `Task` の仕事になる。
    ///
    /// <!-- example: 文脈 var grain: Image? -->
    /// ```swift
    /// func setup() {
    ///     Task { grain = try? await requestImage("assets/grain.png") }
    /// }
    ///
    /// func draw() {
    ///     background(23, 26, 31)
    ///     if let grain { image(grain, 0, 0) }
    /// }
    /// ```
    ///
    /// **`Task` の中の `try?` は、届かなかった画像を黙って `nil` のままにする。** `Task` の中の失敗は
    /// `setup()` へ投げ返せないので、届かなくても画像が成り立つ (届くまでと同じ姿で描く) ときに限って
    /// `try?` で受ける。理由が要るときは `do` / `catch` で受けて `print(error)` する。無いと画像が成り立たない
    /// 画像は、待たずに ``loadImage(_:)`` を `setup() throws` の中で `try` する。他の `request…` の API の
    /// `try?` も同じである。
    ///
    /// **届くまでの ``Sketch/draw()`` は、画像が無いまま呼ばれる。** 待っている間もフレームは進む
    /// ので、届く前の姿 (何も置かない・仮の画像を置く) を `draw()` の側で決めておく。届くのは
    /// フレームとフレームの間で、届いた次のフレームから置かれる。
    ///
    /// **置くのは ``Sketch/draw()`` の中で、`Task` の中ではない。** `Task` の中から描く API
    /// (``image(_:_:_:)-(Image,_,_)`` や ``width``) を呼んでも、そこからは描画先を取れないので描かれず、
    /// 0 が返る (API ごとに 1 度だけ警告する)。`Task` がするのは、届いたものを持っておくところまでである。
    ///
    /// 起動するのは ``Sketch/draw()`` や入力のコールバックの中でもよい。そこで起動した `Task` も
    /// 呼べる。呼べないのは、実行中の実行から起動されていない所 — `init`・終了処理の後・
    /// `Task.detached` — で、そこから呼ぶと ``ImageFailure/notRunning(call:)`` を投げる。
    ///
    /// スケッチが終わった後に届いても落ちない。画像はそのまま返り、置く ``Sketch/draw()`` が
    /// もう来ないだけである。
    ///
    /// **呼んだ `Task` を取り消しても、読み込みは止まらない。** 画像は読み終えて返り、取り消した
    /// ことが失敗として返ることはない (読み込みは取消を見ない)。取消の扱いは [#2760] と合わせて
    /// 決めるので、これは**いまの振る舞いであって保証ではない**。
    ///
    /// ## 続けて要求し直すとき
    ///
    /// 取り消しても前の読み込みは届く。**別の画像を要求し直すときは、要求に番号を付けて、
    /// 届いたものが最後の要求のものかを照合する。** 下の例は ``Sketch/keyPressed()`` ごとに
    /// 別の画像を要求し直し、遅れて届いた前の画像を採らない。前の `Task` を取り消すのは、その結果を
    /// もう使わないと自分で決めたことを示すためで、止めるのは番号の照合である。
    ///
    /// <!-- example: 文脈 var photo: Image?; var loading: Task<Void, Never>?; var latest = 0 -->
    /// ```swift
    /// func showPhoto(_ path: String) {
    ///     loading?.cancel()
    ///     latest += 1
    ///     let mine = latest
    ///     loading = Task {
    ///         let arrived = try? await requestImage(path)
    ///         guard mine == latest else { return }
    ///         photo = arrived
    ///     }
    /// }
    ///
    /// func setup() {
    ///     showPhoto("assets/morning.png")
    /// }
    ///
    /// func keyPressed() {
    ///     showPhoto("assets/evening.png")
    /// }
    ///
    /// func draw() {
    ///     background(23, 26, 31)
    ///     if let photo { image(photo, 0, 0) }
    /// }
    /// ```
    ///
    /// > Note: 届いた画像の見え方は ``loadImage(_:)`` と同じなので、画像はそちらを見ること。
    /// > 何枚目のフレームで届くかは画像の大きさとフレームの間隔で変わり、同じ条件でも実行ごとに
    /// > ずれうるので、この API だけの画像は撮っていない。
    ///
    /// ## URL から読む
    ///
    /// **名前が `http://` か `https://` で始まれば、その URL から受け取る** (Processing の
    /// `requestImage(url)`・[#3715])。受け取る間もフレームは進む。URL ごとに 1 度だけ受け取り、サーバの側の
    /// 差し替えを拾わないのは ``loadImage(_:)`` と同じ。
    ///
    /// <!-- example: 文脈 var photo: Image? -->
    /// ```swift
    /// func setup() {
    ///     Task { photo = try? await requestImage("https://example.com/photo.png") }
    /// }
    ///
    /// func draw() {
    ///     background(23, 26, 31)
    ///     if let photo { image(photo, 0, 0) }
    /// }
    /// ```
    ///
    /// - Throws: ``loadImage(_:)`` と同じ (``ImageFailure``)。
    ///   実行中の実行から起動していない所 (`init`・終了処理の後・`Task.detached`) で呼ぶと
    ///   ``ImageFailure/notRunning(call:)`` (プロセスは落ちない)。
    ///
    /// [#2760]: https://github.com/mokume-metal/mokume/issues/2760
    /// [#3715]: https://github.com/mokume-metal/mokume/issues/3715
    // shot: 参照 loadImage(_:)
    public func requestImage(_ path: String) async throws(ImageFailure) -> Image {
        let canvas = try loadingCanvas(ImageFailure.self)
        return try await canvas.requestImage(path)
    }

    /// 種類 (拡張子) を添えて画像を読む。**読んでいる間、他の仕事を止めない。**
    ///
    /// Processing の `requestImage(filename, extension)` に当たる。種類の手がかりの効き方と控えは
    /// ``loadImage(_:extension:)``、呼び方と届く前の扱いは ``requestImage(_:)`` と同じ。
    ///
    /// <!-- example: 文脈 var photo: Image? -->
    /// ```swift
    /// func setup() {
    ///     Task { photo = try? await requestImage("https://example.com/photo", extension: "png") }
    /// }
    ///
    /// func draw() {
    ///     background(23, 26, 31)
    ///     if let photo { image(photo, 0, 0) }
    /// }
    /// ```
    ///
    /// - Throws: ``requestImage(_:)`` と同じ (``ImageFailure``)。
    // shot: 参照 loadImage(_:)
    public func requestImage(_ path: String, extension: String) async throws(ImageFailure) -> Image {
        let canvas = try loadingCanvas(ImageFailure.self)
        return try await canvas.requestImage(path, extension: `extension`)
    }

    /// 空の画像を作る。中身は透明。
    ///
    /// ``Image/set(_:_:_:)`` で書き換えると、**描くときに自動で送られる** —
    /// 送り直しを呼び忘れて画像が変わらない、という形の不具合が起きない。
    ///
    /// **投げるので `setup()` で作って持ち回る。** 下の例は 16 画素四方の画像を 1 度だけ
    /// 作り、毎フレーム大きく引き伸ばして置いている。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     <!-- example: 文脈 var tile: Image! -->
    ///     ```swift
    ///     func setup() throws {
    ///         tile = try createImage(16, 16)
    ///         for y in 0..<16 {
    ///             for x in 0..<16 {
    ///                 tile.set(x, y, .display(
    ///                     red: Float(x) / 15, green: 0.35, blue: Float(y) / 15))
    ///             }
    ///         }
    ///     }
    ///
    ///     func draw() {
    ///         background(23, 26, 31)
    ///         image(tile, 80, 30, 240, 240)
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 16 画素四方の画像を大きく置いたもの。右へ行くほど赤く、下へ行くほど青い -->
    ///     ![16 画素四方の画像を大きく置いたもの。右へ行くほど赤く、下へ行くほど青い](https://i.gyazo.com/1af862782ae3453fbe658504ce53abdd.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// - Throws: 幅・高さのどちらかが 1 を割るか描画先の上限を越えるときに
    ///   ``ImageFailure/unplaceable(width:height:)``。1 を割る指定を 1×1 へ丸めない。
    ///   `setup()`・`draw()`・入力のコールバックの外 (初期化子の中・終了処理の後・`Task` の中) で呼ぶと
    ///   ``ImageFailure/notRunning(call:)`` (プロセスは落ちない)。
    // shot: 1 snippet=687277ab
    public func createImage(_ width: Int, _ height: Int) throws(ImageFailure) -> Image {
        try resourceCanvas(ImageFailure.self).createImage(width, height)
    }

    /// 画像を等倍で置く。
    ///
    /// (`x`, `y`) の読み方は ``imageMode(_:)`` が決める — 既定の `.corner` と `.corners` なら
    /// 左上の角、`.center` と `.radius` なら中心が (`x`, `y`) に来る。**大きさは、どの読み方でも
    /// 画像の画素数のまま**である。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     <!-- example: 文脈 var tile: Image! -->
    ///     ```swift
    ///     func setup() throws {
    ///         tile = try createImage(64, 64)
    ///         tile.fill(color(51, 71, 102))
    ///         for y in 0..<24 {
    ///             for x in 0..<40 {
    ///                 tile.set(x, y, color(242, 115, 64))
    ///             }
    ///         }
    ///     }
    ///
    ///     func draw() {
    ///         background(23, 26, 31)
    ///         image(tile, 90, 60)
    ///         stroke(242, 242, 242)
    ///         strokeWeight(2)
    ///         line(50, 60, 90, 60)
    ///         line(90, 20, 90, 60)
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 64 画素四方の画像が等倍で置かれ、白い 2 本の線が外からその左上の角を指している -->
    ///     ![64 画素四方の画像が等倍で置かれ、白い 2 本の線が外からその左上の角を指している](https://i.gyazo.com/fcff4988c6589f8f2cfb049cefee57a3.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=cbfaab04
    public func image(_ image: Image, _ x: some ScalarConvertible, _ y: some ScalarConvertible) {
        guard let canvas = liveCanvas() else { return }
        let (x, y) = (x.asFloat, y.asFloat)
        canvas.image(image, x, y)
    }

    /// 画像を、指定した寸法に合わせて置く。
    ///
    /// 4 つの数の読み方は ``imageMode(_:)`` が決める。**画像の画素数と合っていなくてよい** —
    /// 下の例は同じ 64 画素四方の画像を、等倍と 3 倍ほどで並べている。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     <!-- example: 文脈 var tile: Image! -->
    ///     ```swift
    ///     func setup() throws {
    ///         tile = try createImage(64, 64)
    ///         tile.fill(color(51, 71, 102))
    ///         for y in 0..<24 {
    ///             for x in 0..<40 {
    ///                 tile.set(x, y, color(242, 115, 64))
    ///             }
    ///         }
    ///     }
    ///
    ///     func draw() {
    ///         background(23, 26, 31)
    ///         image(tile, 30, 40, 64, 64)
    ///         image(tile, 140, 40, 200, 200)
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 同じ描画結果が 2 つ。左は小さく等倍、右は 3 倍ほどに引き伸ばされている -->
    ///     ![同じ描画結果が 2 つ。左は小さく等倍、右は 3 倍ほどに引き伸ばされている](https://i.gyazo.com/593a42598806d6b9fcc200be5d33e373.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=03eb840b
    public func image(_ image: Image, _ a: some ScalarConvertible, _ b: some ScalarConvertible, _ c: some ScalarConvertible, _ d: some ScalarConvertible) {
        guard let canvas = liveCanvas() else { return }
        let (a, b, c, d) = (a.asFloat, b.asFloat, c.asFloat, d.asFloat)
        canvas.image(image, a, b, c, d)
    }

    /// 画像の一部を切り出して置く。
    ///
    /// 前の 4 つが置き先、後の 4 つが**画像の中のどこを切り出すか**。切り出しが画像の
    /// 外へ出ても落ちず、**重なった分だけが、同じ倍率で指した場所に出る** — 置き先も切り出しを
    /// 締めたのと同じ割合で締まるので、倍率は `置き先 / 切り出し` のまま変わらない。
    /// たとえば 64 画素四方の画像の `(32, 0, 64, 64)` を `128×128` へ置くと、置き先の右半分
    /// (画像の右端を越えた所) には何も置かれず、重なった分 (画像の右半分) が 2 倍の
    /// `64×128` で置き先の左半分に出る。
    ///
    /// 下の例は同じ描画結果を 2 度置いている — 左は全体、右は左上の 28 画素四方だけを
    /// 同じ大きさへ引き伸ばしたもの。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     <!-- example: 文脈 var tile: Image! -->
    ///     ```swift
    ///     func setup() throws {
    ///         tile = try createImage(64, 64)
    ///         tile.fill(color(51, 71, 102))
    ///         for y in 0..<24 {
    ///             for x in 0..<40 {
    ///                 tile.set(x, y, color(242, 115, 64))
    ///             }
    ///         }
    ///     }
    ///
    ///     func draw() {
    ///         background(23, 26, 31)
    ///         image(tile, 20, 40, 128, 128)
    ///         image(tile, 190, 40, 128, 128, 4, 4, 28, 28)
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 左に画像の全体、右はその左上 28 画素四方だけを同じ大きさへ引き伸ばしたもの。右は橙色が大半を占め、下端にだけ青が残る -->
    ///     ![左に画像の全体、右はその左上 28 画素四方だけを同じ大きさへ引き伸ばしたもの。右は橙色が大半を占め、下端にだけ青が残る](https://i.gyazo.com/245c551e0af7485fa3f4ac9c6ff238f2.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    // shot: 1 snippet=2a1a23bd
    public func image(
        _ image: Image, _ a: some ScalarConvertible, _ b: some ScalarConvertible, _ c: some ScalarConvertible, _ d: some ScalarConvertible,
        _ sourceX: some ScalarConvertible, _ sourceY: some ScalarConvertible, _ sourceWidth: some ScalarConvertible, _ sourceHeight: some ScalarConvertible
    ) {
        guard let canvas = liveCanvas() else { return }
        let (a, b, c, d, sourceX, sourceY, sourceWidth, sourceHeight) = (a.asFloat, b.asFloat, c.asFloat, d.asFloat, sourceX.asFloat, sourceY.asFloat, sourceWidth.asFloat, sourceHeight.asFloat)
        canvas.image(image, a, b, c, d, sourceX, sourceY, sourceWidth, sourceHeight)
    }

    /// 画像を、`destination` の範囲に合わせて置く。範囲を ``Rect`` で渡す。
    ///
    /// ``imageMode(_:)`` が既定 (`.corner`) のときの 5 つの引数の形に、`destination` の左上と幅・高さを
    /// 渡すのと同じ絵になる。違いは 2 つで、**どの数が何かを呼び出しの行で読める**ことと、
    /// **``imageMode(_:)`` に従わない**ことである — ``Rect`` は左上で置く値なので、モードが `.center`
    /// でも値のとおり左上から置く (``Rect/draw()`` が ``rectMode(_:)`` に従わないのと同じ)。
    ///
    /// <!-- example: 文脈 var tile: Image! -->
    /// ```swift
    /// // image(tile, 10, 20, 64, 64) (既定のモード) と同じ絵
    /// image(tile, in: Rect(left: 10, top: 20, width: 64, height: 64))
    /// ```
    // shot: 参照 image(_:_:_:_:_:) (Image, some ScalarConvertible, some ScalarConvertible, some ScalarConvertible, some ScalarConvertible)
    public func image(_ image: Image, in destination: Rect) {
        guard let canvas = liveCanvas() else { return }
        canvas.image(image, in: destination)
    }

    /// 画像の `source` の範囲を切り出して、`destination` の範囲に置く。2 つの範囲を ``Rect`` で渡す。
    ///
    /// ``imageMode(_:)`` が既定 (`.corner`) のときの 9 つの引数の形に、置き先と切り出しの左上と幅・高さを
    /// 渡すのと同じ絵になる。切り出しが画像の外へ出たときの扱いもそちらと同じで、違いは
    /// **どの範囲が置き先でどれが切り出しかを呼び出しの行で読める**ことと、**``imageMode(_:)`` に
    /// 従わない**ことである (置き先は値のとおり左上から置く)。
    ///
    /// <!-- example: 文脈 var tile: Image! -->
    /// ```swift
    /// // image(tile, 190, 40, 128, 128, 4, 4, 28, 28) (既定のモード) と同じ絵
    /// image(
    ///     tile,
    ///     in: Rect(left: 190, top: 40, width: 128, height: 128),
    ///     from: Rect(left: 4, top: 4, width: 28, height: 28))
    /// ```
    // shot: 参照 image(_:_:_:_:_:_:_:_:_:) (Image, some ScalarConvertible, some ScalarConvertible, some ScalarConvertible, some ScalarConvertible, some ScalarConvertible, some ScalarConvertible, some ScalarConvertible, some ScalarConvertible)
    public func image(_ image: Image, in destination: Rect, from source: Rect) {
        guard let canvas = liveCanvas() else { return }
        canvas.image(image, in: destination, from: source)
    }

    /// 4 つの数を、画像のどこの寸法として読むか。既定は**左上の角と、幅と高さ**。
    ///
    /// 下の 4 枚はどれも同じ 4 つの数 `200, 150, 120, 90` を渡していて、変えたのは
    /// 読み方だけである (白い点が `200, 150`)。``rectMode(_:)`` と同じ保証。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     <!-- example: 文脈 var tile: Image! -->
    ///     ```swift
    ///     func setup() throws {
    ///         tile = try createImage(64, 64)
    ///         tile.fill(color(51, 71, 102))
    ///         for y in 0..<24 {
    ///             for x in 0..<40 {
    ///                 tile.set(x, y, color(242, 115, 64))
    ///             }
    ///         }
    ///     }
    ///
    ///     func draw() {
    ///         background(23, 26, 31)
    ///         imageMode(.corner)
    ///         image(tile, 200, 150, 120, 90)
    ///         noStroke()
    ///         fill(242, 242, 242)
    ///         circle(200, 150, 10)
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 白い点が画像の左上の角にあり、画像は点から右下へ広がっている -->
    ///     ![白い点が画像の左上の角にあり、画像は点から右下へ広がっている](https://i.gyazo.com/cb23740489cca038b2c0f40a7d3a0bde.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     <!-- example: 文脈 var tile: Image! -->
    ///     ```swift
    ///     func setup() throws {
    ///         tile = try createImage(64, 64)
    ///         tile.fill(color(51, 71, 102))
    ///         for y in 0..<24 {
    ///             for x in 0..<40 {
    ///                 tile.set(x, y, color(242, 115, 64))
    ///             }
    ///         }
    ///     }
    ///
    ///     func draw() {
    ///         background(23, 26, 31)
    ///         imageMode(.corners)
    ///         image(tile, 200, 150, 120, 90)
    ///         noStroke()
    ///         fill(242, 242, 242)
    ///         circle(200, 150, 10)
    ///         circle(120, 90, 10)
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 白い点が 2 つあり、それぞれ画像の右下と左上の角になっている -->
    ///     ![白い点が 2 つあり、それぞれ画像の右下と左上の角になっている](https://i.gyazo.com/ca4178b45a0ec96fb4c086c0ad31c6ba.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     <!-- example: 文脈 var tile: Image! -->
    ///     ```swift
    ///     func setup() throws {
    ///         tile = try createImage(64, 64)
    ///         tile.fill(color(51, 71, 102))
    ///         for y in 0..<24 {
    ///             for x in 0..<40 {
    ///                 tile.set(x, y, color(242, 115, 64))
    ///             }
    ///         }
    ///     }
    ///
    ///     func draw() {
    ///         background(23, 26, 31)
    ///         imageMode(.center)
    ///         image(tile, 200, 150, 120, 90)
    ///         noStroke()
    ///         fill(242, 242, 242)
    ///         circle(200, 150, 10)
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 白い点が画像のまん中にある -->
    ///     ![白い点が画像のまん中にある](https://i.gyazo.com/e186e51267c5ef1f42f837a311ee4e61.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     <!-- example: 文脈 var tile: Image! -->
    ///     ```swift
    ///     func setup() throws {
    ///         tile = try createImage(64, 64)
    ///         tile.fill(color(51, 71, 102))
    ///         for y in 0..<24 {
    ///             for x in 0..<40 {
    ///                 tile.set(x, y, color(242, 115, 64))
    ///             }
    ///         }
    ///     }
    ///
    ///     func draw() {
    ///         background(23, 26, 31)
    ///         imageMode(.radius)
    ///         image(tile, 200, 150, 120, 90)
    ///         noStroke()
    ///         fill(242, 242, 242)
    ///         circle(200, 150, 10)
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 白い点が画像のまん中にあり、画像は center のときの縦横 2 倍になっている -->
    ///     ![白い点が画像のまん中にあり、画像は center のときの縦横 2 倍になっている](https://i.gyazo.com/ad043294ff7ed30837fe0446961b468b.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// 3 つの数で置く ``image(_:_:_:)-(Image,_,_)`` (グラフィックスを置く ``image(_:_:_:)-(Canvas,_,_)``
    /// も) にも読み方は効く。ただし大きさは変わらず、決まるのは (`x`, `y`) が画像の左上の角か
    /// 中心かだけである。
    ///
    /// - Note: 座標の読み方は**フレームを越える**。一度書けば、書き換えるまで残る。
    // shot: 1 snippet=5cd997ad
    // shot: 2 snippet=5313d2ba
    // shot: 3 snippet=c541dbbc
    // shot: 4 snippet=5b4df7b6
    public func imageMode(_ mode: ShapeMode) { liveCanvas()?.imageMode(mode) }

    /// 画像に掛ける色。**掛け算なので、白は何も変えない。**
    ///
    /// 下の 2 枚はどちらも、左が掛ける前・右が掛けた後である。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     <!-- example: 文脈 var tile: Image! -->
    ///     ```swift
    ///     func setup() throws {
    ///         tile = try createImage(64, 64)
    ///         tile.fill(color(51, 71, 102))
    ///         for y in 0..<24 {
    ///             for x in 0..<40 {
    ///                 tile.set(x, y, color(242, 115, 64))
    ///             }
    ///         }
    ///     }
    ///
    ///     func draw() {
    ///         background(23, 26, 31)
    ///         image(tile, 20, 90, 160, 120)
    ///         tint(255, 255, 255, 128)
    ///         image(tile, 220, 90, 160, 120)
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 同じ描画結果が 2 つ。右は濃さが半分で、下地に沈んで見える -->
    ///     ![同じ描画結果が 2 つ。右は濃さが半分で、下地に沈んで見える](https://i.gyazo.com/735e96b7ccf71b05673efc7fab4d5f5b.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     <!-- example: 文脈 var tile: Image! -->
    ///     ```swift
    ///     func setup() throws {
    ///         tile = try createImage(64, 64)
    ///         tile.fill(color(51, 71, 102))
    ///         for y in 0..<24 {
    ///             for x in 0..<40 {
    ///                 tile.set(x, y, color(242, 115, 64))
    ///             }
    ///         }
    ///     }
    ///
    ///     func draw() {
    ///         background(23, 26, 31)
    ///         image(tile, 20, 90, 160, 120)
    ///         tint(255, 153, 153)
    ///         image(tile, 220, 90, 160, 120)
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 同じ描画結果が 2 つ。右は緑と青が抑えられて赤みが乗っている -->
    ///     ![同じ描画結果が 2 つ。右は緑と青が抑えられて赤みが乗っている](https://i.gyazo.com/9d3fd477d8122e47b5ca3a0b3bfca542.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// 数でない成分・無限の成分を持つ色は受けず、画像に掛ける色は直前のまま残る。初回だけ理由を
    /// 警告する。
    ///
    /// - Note: 画像に掛ける色は**フレームを越える**。一度書けば、書き換えるまで残る。
    // shot: 1 snippet=02205f1c
    // shot: 2 snippet=4729e607
    public func tint(_ color: LinearRGBA) { liveCanvas()?.tint(color) }

    /// 色掛けをやめる。
    ///
    /// **1 つ目と 3 つ目は同じ色で出る** — 間で ``tint(_:)`` を掛けても、外せば元に帰る。
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     <!-- example: 文脈 var tile: Image! -->
    ///     ```swift
    ///     func setup() throws {
    ///         tile = try createImage(64, 64)
    ///         tile.fill(color(51, 71, 102))
    ///         for y in 0..<24 {
    ///             for x in 0..<40 {
    ///                 tile.set(x, y, color(242, 115, 64))
    ///             }
    ///         }
    ///     }
    ///
    ///     func draw() {
    ///         background(23, 26, 31)
    ///         image(tile, 15, 100, 110, 110)
    ///         tint(255, 128, 128)
    ///         image(tile, 145, 100, 110, 110)
    ///         noTint()
    ///         image(tile, 275, 100, 110, 110)
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 同じ描画結果が 3 つ横に並び、真ん中だけ赤みが乗っている。右は左と同じ色に戻っている -->
    ///     ![同じ描画結果が 3 つ横に並び、真ん中だけ赤みが乗っている。右は左と同じ色に戻っている](https://i.gyazo.com/d43c76175f0b324dc9ddafc327c8e885.png)
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// - Note: 画像に掛ける色は**フレームを越える**。一度書けば、書き換えるまで残る。
    // shot: 1 snippet=88558c99
    public func noTint() { liveCanvas()?.noTint() }
}
