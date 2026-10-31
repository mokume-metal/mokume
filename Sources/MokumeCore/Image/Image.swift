// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Metal
import MokumeDiagnostics
import simd

/// 読み込んだ、あるいは自分で作った絵。
///
/// ## 画素は作業空間の値で持つ
///
/// 読み書きする画素と描画に使う面は**線形・アルファ乗算済み**の半精度 4 成分で、色域は作業空間と同じ
/// ([ADR-0011])。入力は画素を読むか描くまでに変換し、描くたびには変換しない。
/// ``get(_:_:)`` と ``set(_:_:_:)`` が扱う色も同じ表現なので、
/// **`set(x, y, get(x, y))` は絵を変えない。**
///
/// ## 書き換えたら、描くときに自動で送られる
///
/// ``set(_:_:_:)`` は書き換えを控え、「送り直しが要る」と印を付けるだけである。
/// 実際の送りは描くときに 1 度だけ起きるので、**送り直しを呼び忘れて絵が変わらない**
/// という形の不具合が起きない。
///
/// 送るのは**描き切りの時点**の画素で、描き切りが GPU 側のコピーで面へ届ける
/// ([#749](https://github.com/mokume-metal/mokume/issues/749))。だから描いた後で置き直さずに
/// 書き換えても、そのフレームには書き換えた後の絵が出る (同じフレームで 2 回置いた
/// ときに、両方へ最後の絵が出るのと同じ理屈である)。
///
/// [ADR-0011]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0011-color-model.md
// `isolated deinit` を持つ型は隔離を明示する。**理由は `RenderDevice` の冒頭が持つ**
// (release のテストビルドでは既定隔離が取り込み側から見失われる・#761)。
@MainActor public final class Image {
    /// 横の画素数。
    public let width: Int
    /// 縦の画素数。
    public let height: Int

    /// 作業空間の画素 (線形・アルファ乗算済み)。行は上から下へ。
    ///
    /// 公開の ``pixels`` (画素の面) とは別で、こちらは値の並びを写して返す内部の口である。
    var workingPixels: [SIMD4<Float16>] {
        materializePixels()
        return cpuPixels
    }
    private var cpuPixels: [SIMD4<Float16>]
    /// 大きな入力は値として保持し、GPU で作業空間へ変換する。呼び手が元の配列を書き換えてもこの控えは変わらない。
    private(set) var deferredInput: DeferredInput?
    /// 遅らせた入力のうち、8 bit の並び (``DisplayImage``) で届いたもの。
    var displayInput: DisplayImage? {
        if case .display(let picture) = deferredInput { picture } else { nil }
    }
    /// 遅らせた入力のうち、面 (``PixelSurface``) で届いたもの。
    var surfaceInput: PixelSurface? {
        if case .surface(let surface) = deferredInput { surface } else { nil }
    }
    private(set) var inputPatches: [Int: SIMD4<Float16>] = [:]
    private(set) var inputNeedsDecode = false
    // 公開のモードにせず、小さい入力の dispatch 費用と編集の控えの上限を内部で持つ (#1753)。
    static let metalInputMinimumPixels = 1 << 20
    static let inputPatchLimit = 4096
    /// GPU 側の面。
    let texture: any MTLTexture
    /// 送りを頼む先 (控えの登録簿) と、逃げ道で待つ相手。
    let gpu: RenderDevice
    /// 入力の控え (raw / CPU 半精度) が GPU 側より新しいか。
    ///
    /// **検査が読む。** 描き切りが待てずに送れなかったときは立ったままになり、次の
    /// 描き切りへ持ち越す ([#934](https://github.com/mokume-metal/mokume/issues/934))。
    private(set) var needsUpload = false {
        didSet { if needsUpload { writeGeneration &+= 1 } }
    }
    /// 画素を書き換えた世代。**送った後に書き換えられていたら、旗を下ろさない。**
    private var writeGeneration: UInt64 = 0
    var isQueuedForUpload = false
    /// 全体を届けた (CPU の画素の全体か、大きな入力の復号) 最後の投入の番号。結末が正常に届くか、
    /// 直接書いたら 0 ([#2199])。
    ///
    /// [#2199]: https://github.com/mokume-metal/mokume/issues/2199
    private var wholeDeliveredBy: UInt64 = 0
    /// 逃げ道で直接送った回数。**検査が読む。**
    private(set) var directUploads = 0
    /// 大きさの違う絵を渡されたことを、もう知らせたか。
    private var warnedMismatch = false
    /// ``filtered(_:)`` が効果を通す作業の面のうち、この絵が最後に使ったもの。**大きさが同じ絵どうしで
    /// 使い回す** (``FilterWorkspaces``) ので、この絵だけのものではない。持つのは、掛け終えた面がすぐ手放されて、
    /// 次の呼び出しで作り直すことにならないため。注意を 1 度だけ言う控えは面が持つ。
    var filterWorkspace: Canvas?

    /// 画素を渡して作る。
    init(width: Int, height: Int, pixels: [SIMD4<Float16>], gpu: RenderDevice) throws(
        RenderFailure
    ) {
        self.width = width
        self.height = height
        self.cpuPixels = pixels

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
        descriptor.usage = width * height >= Self.metalInputMinimumPixels
            ? [.shaderRead, .renderTarget] : .shaderRead
        descriptor.storageMode = .shared
        let texture = try gpu.makeTexture(descriptor: descriptor)
        texture.label = "mokume.image"
        self.texture = texture
        self.gpu = gpu
        // **待たずに送る。** いま作った面を GPU はまだ知らないので、読み終わるのを待つ
        // 相手が居ない
        replaceTexture()
    }

    /// **面を常駐から退かせる** ([#738])。
    ///
    /// 常駐の集合は入れたものを抱えるので、絵を手放しても面は解放されない。`draw()` の
    /// 中で `loadImage` を呼ぶ書き方は、これでフレームごとに 1 枚ずつ積んでいた
    /// (実測: 256x256 を 200 フレームで +108 MiB)。退かせるだけで待たないので、
    /// 手放す側は寿命を気にしなくてよい。置いた列や、置いて作った形がまだ読むなら、
    /// それらが絵を抱えているのでここは走らない ([#1079]・[#1178])。
    ///
    /// [#738]: https://github.com/mokume-metal/mokume/issues/738
    /// [#1079]: https://github.com/mokume-metal/mokume/issues/1079
    /// [#1178]: https://github.com/mokume-metal/mokume/issues/1178
    isolated deinit { gpu.retire(texture) }

    /// 1 画素の色。範囲の外は透明を返す (**読み取りは決して落ちない** — [ADR-0020] 決定 5)。
    ///
    /// 返す値は線形・アルファ乗算済みの ``LinearRGBA`` である ([ADR-0011] 決定 4)。
    /// ``set(_:_:_:)`` が受けるのも同じ表現なので、`set(x, y, get(x, y))` は絵を変えない。
    /// 0–255 の乗算していない数で読むときは ``red(_:)`` ほかを通す。
    ///
    /// [ADR-0011]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0011-color-model.md
    /// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
    public func get(_ x: Int, _ y: Int) -> LinearRGBA {
        guard x >= 0, y >= 0, x < width, y < height else { return .transparent }
        materializePixels()
        let texel = cpuPixels[y * width + x]
        return LinearRGBA(
            premultipliedRed: Float(texel.x), green: Float(texel.y), blue: Float(texel.z),
            alpha: Float(texel.w))
    }

    /// 1 画素の色を書き換える。範囲の外は何もしない。
    ///
    /// 色は検めずに面へ移す。数でない成分・無限の成分もそのまま書き (図形を描く経路が面へ
    /// 移すときと同じ)、有限の成分は面が表せる ±65504 で止まる (``fill(_:)`` も同じ)。
    public func set(_ x: Int, _ y: Int, _ color: LinearRGBA) {
        guard x >= 0, y >= 0, x < width, y < height else { return }
        let index = y * width + x
        let texel = HalfSurface.texel(color)
        if deferredInput != nil,
            inputPatches[index] != nil || inputPatches.count < Self.inputPatchLimit
        {
            inputPatches[index] = texel
        } else {
            materializePixels()
            cpuPixels[index] = texel
        }
        needsUpload = true
    }

    /// 表示できる形の絵を、まとめて書き込む。**外から届いた映像を絵にする道である。**
    ///
    /// 受け取るのは出口が出すのと同じ形 (``DisplayImage``) で、作業空間への変換は
    /// ここが引き受ける ([ADR-0011] 決定 3 の「入力側は作業空間へ入る時点で線形へ
    /// 変換する」)。**呼ぶ側は色を変換しない。**
    ///
    /// 1 画素ずつ ``set(_:_:_:)`` を呼ぶのと結果は同じだが、費用が違う — 1920×1080
    /// では呼び出しだけで 1 フレームの予算を超える
    /// ([#487](https://github.com/mokume-metal/mokume/issues/487))。
    ///
    /// ## 大きさは絵が持つ
    ///
    /// **書き込みで絵の大きさは変わらない。** 大きさの違う絵を渡しても何も起きず、
    /// 理由が 1 度だけ診断に出る。送り元の解像度が変わったら ``Canvas/createImage(_:_:)``
    /// で作り直す — 毎フレーム触る口の中に面の作り直しを置かないためである。
    ///
    /// <!-- example: 文脈 var settings = SketchSettings(width: 400, height: 300) -->
    /// ```swift
    /// private var video: Image?
    ///
    /// func setup() throws {
    ///     // 面は 1 度だけ作る。書き込みでは大きさが変わらない
    ///     video = try createImage(320, 180)
    /// }
    ///
    /// func draw() {
    ///     guard let video else { return }
    ///     // ふつうはここへ外から届いた 1 枚をそのまま渡す。この例では自分で組み立てる
    ///     var bytes = [UInt8](repeating: 255, count: 320 * 180 * 4)
    ///     for index in 0..<(320 * 180) {
    ///         bytes[index * 4] = UInt8(index % 320 * 255 / 319)
    ///         bytes[index * 4 + 1] = UInt8(index / 320 * 255 / 179)
    ///         bytes[index * 4 + 2] = 90
    ///     }
    ///     video.write(DisplayImage(width: 320, height: 180, bytes: bytes))
    ///     image(video, 0, 0, width, height)
    /// }
    /// ```
    ///
    /// [ADR-0011]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0011-color-model.md
    public func write(_ picture: DisplayImage) {
        guard picture.width == width, picture.height == height else {
            warnMismatchOnce(width: picture.width, height: picture.height)
            return
        }
        if width * height >= Self.metalInputMinimumPixels {
            deferToGPU(.display(picture))
        } else {
            OutputStage.decode(picture, into: &cpuPixels)
        }
        needsUpload = true
    }

    /// 外から届いた面を、CPU で画素を作り直さずに書き込む。**動画とカメラのコマを絵にする速い道である。**
    ///
    /// 色の変換は面が持つ表 (``PixelSurface/ColorTable``) を GPU で引いて行い、結果は同じ表で作った
    /// ``DisplayImage`` を ``write(_:)-(DisplayImage)`` で書いたときと 1 bit も違わない。いつも不透明として書く。
    /// 大きさの扱い (違えば何もせず 1 度だけ知らせる) も同じである。
    ///
    /// **面は、次に書き込むか絵を捨てるまで絵が持つ** (``PixelSurface`` の「面の寿命」)。100 万画素に満たない
    /// 絵へ書くときと、絵の画素を CPU で読むとき (``get(_:_:)``・``pixels``・``copy()``・``save(_:)`` ほか) は、
    /// その場で表を CPU で引いて写す — 写した後は面を持たない。
    ///
    /// <!-- example: 組めない 面は外から届くもので、例の中で用意できない -->
    /// ```swift
    /// // frame は動画やカメラ、外のパッケージから届いた PixelSurface
    /// picture.write(frame)
    /// image(picture, 0, 0, width, height)
    /// ```
    public func write(_ surface: PixelSurface) {
        guard surface.width == width, surface.height == height else {
            warnMismatchOnce(width: surface.width, height: surface.height)
            return
        }
        if width * height >= Self.metalInputMinimumPixels {
            deferToGPU(.surface(surface))
        } else {
            OutputStage.decode(surface.converted(), into: &cpuPixels)
        }
        needsUpload = true
    }

    /// 入力を GPU の変換へ遅らせる。前の入力と編集は捨てる。
    private func deferToGPU(_ input: DeferredInput) {
        deferredInput = input
        cpuPixels = []
        inputPatches = [:]
        inputNeedsDecode = true
    }

    /// 絵を写して、新しい `Image` にする。Processing の `PImage.copy()` に当たる。
    ///
    /// 写しは元と**画素も面も共有しない**。写した後で片方を ``set(_:_:_:)``・``fill(_:)``・
    /// ``write(_:)-(DisplayImage)`` で書き換えても、もう片方は変わらない。画素は作業空間の値のまま写す
    /// (8 bit を経由しない・[ADR-0011])。
    ///
    /// **毎フレーム書き換わる絵を取っておくのに使う。** カメラの `image` は毎フレーム同じ 1 枚に
    /// 上書きされるので、`image` をそのまま配列へ入れると、全部が次のフレームでいまの絵になる。
    /// 撮った時点の絵は `copy()` で取る。
    ///
    /// ```swift
    /// var camera: Capture?
    /// var shots: [Image] = []
    ///
    /// func setup() throws { camera = try createCapture() }
    ///
    /// func draw() {
    ///     background(0)
    ///     if let camera { image(camera.image, 0, 0, width, height) }
    ///     for (i, s) in shots.suffix(4).enumerated() {
    ///         image(s, Float(i) * 160, height - 90, 160, 90)
    ///     }
    /// }
    ///
    /// func keyPressed() {
    ///     // 撮った時点の絵を取って、ファイルにも残す
    ///     if let shot = camera?.image.copy() {
    ///         shots.append(shot)
    ///         try? shot.save("out/shot-\(shots.count).png")
    ///     }
    /// }
    /// ```
    ///
    /// ファイルへ残すのは付け足しで、書けなくても取った写しは `shots` に残るので、`try?` で受けている。
    ///
    /// - Returns: 大きさも画素も同じ、新しい `Image`。
    ///
    /// [ADR-0011]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0011-color-model.md
    // shot: 撮れない 例はカメラの映像を要し、写しが元と独立なことは書き換えた後の画素で見る (絵では見えない)
    public func copy() -> Image {
        materializePixels()
        do {
            return try Image(width: width, height: height, pixels: cpuPixels, gpu: gpu)
        } catch {
            // 同じ大きさの面が既にあるので、作れないのは置き場が尽きたときだけである
            preconditionFailure("copy(): the GPU could not hold another \(width)x\(height) image: \(error)")
        }
    }

    /// 絵の画素を、一度に ``PixelBuffer`` で読む。``write(_:)-(DisplayImage)`` の逆に当たる。
    ///
    /// 1 画素ずつ ``get(_:_:)`` で読む代わりに、全画素を 1 回の呼び出しで取る。外のパッケージが絵を
    /// 解析に渡すとき (画像認識など) の入口である。返る ``PixelBuffer`` の `width`・`height` は絵の大きさで、
    /// 原点は左上、行優先。
    ///
    /// **値は ``get(_:_:)`` と同じ表現で、変換を挟まない。** `components` は線形・アルファ乗算済み
    /// (``PixelBuffer`` の説明のとおり) で、``Image/get(_:_:)`` が返す色の成分をそのまま並べたものになる。
    /// 乗算を外す・sRGB へ写すといった変換は、受け取る側が必要なところで行う。
    ///
    /// ```swift
    /// func setup() throws {
    ///     let picture = try createImage(2, 2)
    ///     picture.set(0, 0, LinearRGBA(premultipliedRed: 1, green: 0, blue: 0, alpha: 1))
    ///
    ///     let buffer = picture.readPixels()
    ///     // buffer.components の先頭 4 つ (赤・緑・青・不透明度) は picture.get(0, 0) と同じ
    ///     print(buffer.width, buffer.height, buffer.components.prefix(4))
    /// }
    /// ```
    ///
    /// **撮った時点の値の写しを返す。** 読んだ後で絵を ``set(_:_:_:)``・``fill(_:)``・``write(_:)-(DisplayImage)`` で
    /// 書き換えても、すでに返した ``PixelBuffer`` は変わらない。窓として開いたまま読み書きする
    /// ``pixels`` (``Pixels``) とは役割が違う — あちらは絵そのものを指して自分を変え、こちらは
    /// 全体の値を 1 度に取って手元に置く。
    ///
    /// 全画素の写しを作るので、絵の大きさに比例する費用がかかる (毎フレーム呼ぶ前に、要る頻度か
    /// 確かめる)。読み取りなので落ちない (ADR-0020 決定 5)。
    // shot: 撮れない 結果が絵ではなく、読み出した画素の値になる
    public func readPixels() -> PixelBuffer {
        let components = workingPixels.withUnsafeBytes { Array($0.bindMemory(to: Float16.self)) }
        return PixelBuffer(width: width, height: height, components: components)
    }

    /// 絵を PNG ファイルにして書く。Processing の `PImage.save()` に当たる。**書き終えてから返る。**
    ///
    /// ```swift
    /// func setup() throws {
    ///     let swatch = try createImage(64, 64)
    ///     swatch.fill(.linear(red: 1, green: 0.4, blue: 0.1))
    ///     try swatch.save("out/swatch.png")
    /// }
    /// ```
    ///
    /// 行き先の探し方は、スケッチの ``SketchPart/save(_:)`` と同じである — 相対の名前は走らせた場所から
    /// 数え、途中のディレクトリは無ければ作る。形式は PNG で、色空間は作業空間と同じ Display P3、
    /// **透けた画素は透けたまま残る** ([ADR-0011])。出力の変換も ``SketchPart/save(_:)`` と同じ出力段を通る
    /// ので、表示できる範囲を超えた明るさは端へ寄り、色は 8 bit へ丸まる。
    ///
    /// ## スケッチの `save(_:)` との違い
    ///
    /// スケッチの ``SketchPart/save(_:)`` はフレームの外で書くので予約するだけで、呼んだ時点では
    /// 失敗が分からない。**この口は呼んだその場で書く**ので、書けなければその場で投げる。
    ///
    /// **名前が `.svg` で終わるものは受けない。** この口は PNG の絵を書くので、`.svg` の名前では PNG の中身が
    /// 黙って並ぶ。図形の線を SVG に書くのはスケッチの ``SketchPart/save(_:)`` で、`save("plot.svg")` と呼ぶ。
    ///
    /// - Parameter path: 書き出す先。
    /// - Throws: 書けなかったとき ``ImageFailure/unwritable(path:reason:)``。行き先と事情が載る。
    ///
    /// [ADR-0011]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0011-color-model.md
    // shot: 撮れない 結果が絵ではなくファイルになる
    public func save(_ path: String) throws(ImageFailure) {
        // `.svg` の名前で PNG の中身を書かない (#3139)。線を書く口は、スケッチの `save("plot.svg")`
        guard !FrameRecorder.isVector(path) else {
            throw .unwritable(path: path, reason: FrameRecorder.vectorSeriesReason)
        }
        let picture = OutputStage.encode(readPixels())
        let url = FrameWriter.url(for: path)
        do {
            try FrameWriter.createParentDirectory(of: url)
            try PNGFile.write(picture, to: url)
        } catch let failure as ImageWriteFailure {
            throw .unwritable(path: path, reason: failure.description)
        } catch {
            // 置き場を作れない事情は OS の文面で名乗る (#2839 の 1 か所)
            throw .unwritable(path: path, reason: Diagnostics.reason(error))
        }
    }

    /// 全体を 1 色で埋める。色は ``set(_:_:_:)`` と同じく、検めずに面へ移す。
    public func fill(_ color: LinearRGBA) {
        let texel = HalfSurface.texel(color)
        if deferredInput != nil {
            // 捨てる入力は復号しない。
            cpuPixels = Array(repeating: texel, count: width * height)
            deferredInput = nil
            inputPatches = [:]
            inputNeedsDecode = false
        } else {
            for index in cpuPixels.indices { cpuPixels[index] = texel }
        }
        needsUpload = true
    }

    /// この絵の画素を読み書きする面。``Canvas/pixels`` と同じ ``Pixels`` を返す。
    ///
    /// **面は `Image` が持つ画素そのものへの窓** — 1 画素ずつ書く ``Pixels/subscript(_:_:)``・
    /// 全体を埋める ``Pixels/fill(_:)``・全画素を 1 つの関数で書き換える ``Pixels/update(_:)`` が、
    /// ``get(_:_:)``・``set(_:_:_:)``・``fill(_:)`` と同じ値を、同じ向き (左上が原点) で読み書きする。
    /// 書き換えは描くときに自動で送られる (送り直しの口は無い)。Processing の `loadPixels()` /
    /// `updatePixels()` と 2 重ループに当たる。
    ///
    /// ```swift
    /// var camera: Capture?
    ///
    /// func setup() throws { camera = try createCapture() }
    ///
    /// func draw() {
    ///     guard let camera else { return }
    ///     camera.image.pixels.update { _, _, c in
    ///         let level = (brightness(c) / 25).rounded(.down) * 25   // 0, 25, 50, 75, 100
    ///         return color(level * 2.55)
    ///     }
    ///     image(camera.image, 0, 0, width, height)
    /// }
    /// ```
    ///
    /// **`Image` は参照型なので、書き換えは同じ 1 枚を変える。** カメラの ``Capture/image`` のように
    /// 次のフレームで上書きされる絵に書いても、書いた分は次のフレームで消える。取っておくなら先に
    /// ``copy()`` で写す。**絵ごとに効果を掛けて新しい絵を返す口 (``Image/filtered(_:)``) とは違い、この口は
    /// 自分を変える** — ``set(_:_:_:)``・``fill(_:)``・``Pixels/update(_:)`` が揃って、同じ絵を書き換える。
    public var pixels: Pixels { Pixels(image: self) }

    /// 全画素を、位置と元の色から決めた色で書き換える (``Pixels/update(_:)`` の `Image` 側)。
    ///
    /// **走査の間は、絵の画素を触らせない。** 閉包が同じ絵を読んでも (`get`)、書き換え中の並びと
    /// 衝突して落ちることがないよう、元の画素を保ったまま別の並びへ書き、最後に差し替える。
    /// 閉包の中で同じ絵を読むと、呼ぶ前の値が読める。
    func transformPixels(_ transform: (_ x: Int, _ y: Int, _ color: LinearRGBA) -> LinearRGBA) {
        guard width > 0, height > 0 else { return }
        materializePixels()
        let source = cpuPixels
        var result = source
        let columns = width
        result.withUnsafeMutableBufferPointer { out in
            source.withUnsafeBufferPointer { input in
                for y in 0..<height {
                    let row = y * columns
                    for x in 0..<columns {
                        let texel = input[row + x]
                        let color = LinearRGBA(
                            premultipliedRed: Float(texel.x), green: Float(texel.y),
                            blue: Float(texel.z), alpha: Float(texel.w))
                        out[row + x] = HalfSurface.texel(transform(x, y, color))
                    }
                }
            }
        }
        cpuPixels = result
        needsUpload = true
    }

    /// CPU が読むとき、または GPU の準備に失敗したときの逃げ道。論理的な値と世代は変えない。
    func materializePixels() {
        guard let deferredInput else { return }
        switch deferredInput {
        case .display(let picture): cpuPixels = OutputStage.decode(picture)
        case .surface(let surface): cpuPixels = OutputStage.decode(surface.converted())
        }
        for (index, texel) in inputPatches { cpuPixels[index] = texel }
        self.deferredInput = nil
        inputPatches = [:]
        inputNeedsDecode = false
    }

    var uploadGeneration: UInt64 { writeGeneration }

    /// 大きさの違う絵を渡されたことを、**最初の 1 度だけ**知らせる。
    ///
    /// 毎フレーム呼ばれる口なので、毎回出すと同じ行が診断を埋めて他が読めなくなる
    /// ([ADR-0020] 決定 5 の「警告を出して安全な既定へ倒す」は、出し続けよとは
    /// 言っていない)。
    ///
    /// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
    private func warnMismatchOnce(width passedWidth: Int, height passedHeight: Int) {
        guard !warnedMismatch else { return }
        warnedMismatch = true
        Diagnostics.warn(
            "write(): the picture passed is \(passedWidth)x\(passedHeight), which differs "
                + "from this image's \(width)x\(height), so nothing was written. If the source "
                + "changed size, make it again with createImage()")
    }

    /// 書き換えた画素を送るよう頼む。描く直前に呼ばれる。
    ///
    /// **その場では送らない。** 描き切りは GPU の完了を待たずに返る (#727) ので、前の
    /// フレームがまだこの面を読んでいるかもしれない。その場で面へ書くには投入済みの全部を
    /// 待つしかなく、毎フレーム映像を差し替えるスケッチでは CPU と GPU の重なりがそこで
    /// 消えていた (#749)。登録簿に載せて、描き切りが GPU 側のコピーで届ける。
    /// 書き換えないフレームは GPU へ送る仕事を積まない。
    func requestUpload() {
        guard needsUpload else { return }
        gpu.pendingUploads.enqueue(self)
    }

    private var pixelBytes: Int { width * height * MemoryLayout<SIMD4<Float16>>.stride }
    private var bytesPerRow: Int { width * MemoryLayout<SIMD4<Float16>>.stride }

    private func replaceTexture() {
        materializePixels()
        cpuPixels.withUnsafeBytes { source in
            texture.replace(
                region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                withBytes: source.baseAddress!, bytesPerRow: bytesPerRow)
        }
    }
}

extension Image: PendingUpload {
    var pendingUploadByteCount: Int { needsUpload ? pixelBytes : 0 }

    func stageUpload(
        into bytes: UnsafeMutableRawPointer, of staging: any MTLBuffer, at offset: Int,
        on encoder: any MTL4ComputeCommandEncoder
    ) -> UInt64 {
        materializePixels()
        cpuPixels.withUnsafeBytes { source in
            bytes.copyMemory(from: source.baseAddress!, byteCount: pixelBytes)
        }
        encoder.copy(
            sourceBuffer: staging, sourceOffset: offset, sourceBytesPerRow: bytesPerRow,
            sourceBytesPerImage: 0, sourceSize: MTLSize(width: width, height: height, depth: 1),
            destinationTexture: texture, destinationSlice: 0, destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        return writeGeneration
    }

    func uploadDirectly() -> UInt64? {
        // **待てなければ送らない** (#934)。旗は立ったままなので、次の描き切りへ持ち越す
        guard
            gpu.settleBeforeWriting(
                orWarn: "Could not wait for the GPU before sending an image to a surface, so "
                    + "the write was held back")
        else { return nil }
        replaceTexture()
        directUploads += 1
        return writeGeneration
    }

    @discardableResult
    func markUploaded(through generation: UInt64, by submission: UInt64?) -> Bool {
        guard generation == writeGeneration else { return false }
        // **全体を届けたかを、下ろす前に見る。** CPU の画素は毎回全体を、大きな入力は復号するときだけ
        // 全体を届ける。復号した後の編集だけの届けは、編集の画素しか書かない (`ImageInputPass`)
        let whole = deferredInput == nil || inputNeedsDecode
        needsUpload = false
        inputNeedsDecode = false
        // 直接書いた分は届いている (全体を書く)
        if whole || submission == nil { wholeDeliveredBy = submission ?? 0 }
        return submission != nil
    }

    /// 届けた投入の結末が届いた。打ち切られていたら、その投入が書くはずだった分を次の描き切りでもう
    /// 一度届ける ([#2199])。
    ///
    /// - **全体を届けた最後の投入** (``wholeDeliveredBy``) なら、全体を届け直す。大きな入力は復号から
    ///   やり直す — 打ち切られた投入の復号も面に書かれていない
    /// - それより後の、**編集だけを届けた投入**なら、編集を届け直す (編集は次に書き込むまで控えに残る)
    /// - それより前の投入なら何もしない — 後の投入が全体を書いた
    ///
    /// 控え (CPU の画素か、大きな入力とその後の編集) は届けた後も持っているので、届け直せば面が揃う。
    /// 打ち切りの後に書き換えていれば、既に送る旗が立っているので、送るのは 1 回である。
    ///
    /// [#2199]: https://github.com/mokume-metal/mokume/issues/2199
    func submissionSettled(_ submission: UInt64, dropped: Bool) {
        if submission == wholeDeliveredBy {
            wholeDeliveredBy = 0
            guard dropped else { return }
            if deferredInput != nil { inputNeedsDecode = true }
        } else {
            guard dropped, submission > wholeDeliveredBy else { return }
        }
        needsUpload = true
        requestUpload()
    }
}

/// GPU で作業空間へ変換するまで遅らせた入力。
enum DeferredInput {
    /// 8 bit の並び。
    case display(DisplayImage)
    /// 面と色の表。
    case surface(PixelSurface)
}
