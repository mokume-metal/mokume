// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import simd

extension Canvas {
    // MARK: - 読む・作る

    /// 絵を読む。読み終わるまで返らない。
    ///
    /// **同じファイルを二度読んでも、探索と復号は一度だけ。** 返る絵は毎回新しいので、
    /// 読んでから塗り替えても次の読み込みには影響しない ([#886])。
    ///
    /// **読んだ絵の成分は、面が表せる範囲へ移る。** 数でない成分・無限の成分はそのまま残り (図形を描く
    /// 経路が面へ移すときと同じ)、有限の成分は面が表せる ±65504 で止まる。浮動小数の絵 (TIFF・
    /// OpenEXR など) の、白をずっと越える成分も同じである。
    ///
    /// [#886]: https://github.com/mokume-metal/mokume/issues/886
    ///
    /// **名前が `http://` か `https://` で始まれば、URL から受け取る** ([#3715])。URL の画像は
    /// 実行のあいだ URL ごとに 1 度だけ受け取り、サーバの側で差し替わっても読み直さない。
    ///
    /// [#3715]: https://github.com/mokume-metal/mokume/issues/3715
    public func loadImage(_ path: String) throws(ImageFailure) -> Image {
        try loadImage(path, kind: nil)
    }

    /// 種類の手がかり (拡張子) を添えて絵を読む。手がかりは中身から種類が分からないときだけ効く
    /// (`ImageFile.hints(_:)`)。**控えの鍵は名前だけ** — 同じ名前を手がかりを変えて読んでも、2 度目は控えを返す。
    public func loadImage(_ path: String, extension kind: String) throws(ImageFailure) -> Image {
        try loadImage(path, kind: Optional(kind))
    }

    private func loadImage(_ path: String, kind: String?) throws(ImageFailure) -> Image {
        if let fresh = freshDecoded(for: path) { return try makeImage(fresh) }
        if let web = try ImageFile.webURL(path) {
            let decoded = try ImageFile.decode(ImageFile.fetchWaiting(web, path: path), name: path, kind: kind)
            remember(decoded, path: path, origin: .web)
            return try makeImage(decoded)
        }
        let url = try ImageFile.locate(path)
        let stamp = ImageFile.stamp(of: url)
        let decoded = try ImageFile.decode(at: url, name: path, kind: kind)
        remember(decoded, path: path, origin: .file(url: url, stamp: stamp))
        return try makeImage(decoded)
    }

    /// 絵を読む。**読んでいる間、他の仕事を止めない。**
    ///
    /// 控えに当たれば別の仕事を起こさない (`requestModel` と同じ形)。
    ///
    /// **読んだ絵の成分は、面が表せる範囲へ移る。** 数でない成分・無限の成分はそのまま残り (図形を描く
    /// 経路が面へ移すときと同じ)、有限の成分は面が表せる ±65504 で止まる。浮動小数の絵 (TIFF・
    /// OpenEXR など) の、白をずっと越える成分も同じである。
    public func requestImage(_ path: String) async throws(ImageFailure) -> Image {
        try await requestImage(path, kind: nil)
    }

    /// 種類の手がかり (拡張子) を添えて絵を読む。読んでいる間、他の仕事を止めない。手がかりと控えの
    /// 扱いは ``loadImage(_:extension:)`` と同じ。
    public func requestImage(_ path: String, extension kind: String) async throws(ImageFailure) -> Image {
        try await requestImage(path, kind: Optional(kind))
    }

    private func requestImage(_ path: String, kind: String?) async throws(ImageFailure) -> Image {
        if let fresh = freshDecoded(for: path) { return try makeImage(fresh) }
        if let web = try ImageFile.webURL(path) {
            let body = try await ImageFile.fetch(web, path: path)
            let decoded = try await Self.away { () throws(ImageFailure) in
                try ImageFile.decode(body, name: path, kind: kind)
            }
            remember(decoded, path: path, origin: .web)
            return try makeImage(decoded)
        }
        let read = try await Self.away { () throws(ImageFailure) in try ImageFile.read(path, kind: kind) }
        remember(read.decoded, path: path, origin: .file(url: read.url, stamp: read.stamp))
        return try makeImage(read.decoded)
    }

    /// 探索・復号を別の仕事として回し、終わりを待つ。
    private static func away<Value: Sendable>(
        _ work: @escaping @Sendable () throws(ImageFailure) -> Value
    ) async throws(ImageFailure) -> Value {
        let outcome = await Task.detached(priority: .utility) {
            Result { () throws(ImageFailure) in try work() }
        }.value
        return try outcome.get()
    }

    // MARK: - 控え

    /// 控えのうち、**いまも元と一致しているもの**を返す。
    ///
    /// ファイルは名前だけを鍵にしない。走らせたまま絵を差し替える書き方は、いまは毎フレーム読み直す
    /// ことで成り立っており、名前だけで引くとそれが黙って効かなくなる。更新時刻を読めな
    /// かったときも当たりにしない — 読み直す側 (安全な側) へ倒す。
    ///
    /// **URL は名前だけで当てる** (#3715 の決定)。実行のあいだ URL ごとに 1 度だけ受け取り、サーバの
    /// 側の差し替えは拾わない — 毎フレーム読む書き方で、毎フレーム通信しないため。
    private func freshDecoded(for path: String) -> ImageFile.Decoded? {
        guard let cached = imageCache[ImageRequest(path: path)] else { return nil }
        switch cached.origin {
        case .web:
            return cached.decoded
        case .file(let url, let stamp):
            guard let now = ImageFile.stamp(of: url), now == stamp else { return nil }
            return cached.decoded
        }
    }

    /// 復号したものを控えに入れる。**量が上限を超えたら、収まるまで古い順に捨てる**
    /// (``BoundedCache``。いま読んだものは、1 枚で上限を超えても残る)。
    private func remember(_ decoded: ImageFile.Decoded, path: String, origin: DecodedImage.Origin) {
        imageCache.insert(DecodedImage(origin: origin, decoded: decoded), for: ImageRequest(path: path))
    }

    /// 空の絵を作る。中身は透明。
    ///
    /// **範囲の外の指定は、画素を組む前に断る。** 範囲は面の関所と同じ
    /// `RenderDevice.textureSides` の 1 つで、後段 (`RenderDevice.makeTexture`) も同じ範囲を
    /// 見る。ここで先に見るのは**組めないもの・捨てるものを作らない**ため — 20000×20000 は
    /// Metal に触る前に 3.2 GB の画素配列を組むことになり
    /// ([#885](https://github.com/mokume-metal/mokume/issues/885))、負の辺では画素配列の数が
    /// 組めない。
    ///
    /// **1 を割る指定を 1 へ丸めない** — 丸めると 1×1 の絵が黙って返る
    /// ([#1642](https://github.com/mokume-metal/mokume/issues/1642))。
    public func createImage(_ width: Int, _ height: Int) throws(ImageFailure) -> Image {
        let sides = RenderDevice.textureSides
        guard sides.contains(width), sides.contains(height) else {
            throw .unplaceable(width: width, height: height)
        }
        return try makeImage(
            ImageFile.Decoded(
                width: width, height: height,
                pixels: [SIMD4<Float16>](repeating: .zero, count: width * height)))
    }

    // MARK: - 置き方

    public func imageMode(_ mode: ShapeMode) { style.imageMode = mode }

    /// 絵に掛ける色。**掛け算なので、白は何も変えない。**
    public func tint(_ color: LinearRGBA) {
        // 数でない成分・無限の成分は、色合いを変えずに断る (#1706)
        guard color.isFinite else { return warnNotANumberColor(.tint) }
        style.tint = color
    }

    public func noTint() { style.tint = .linear(red: 1, green: 1, blue: 1) }

    // MARK: - 貼る

    // これから置く塗りに絵を貼る。
    public func texture(_ image: Image) { style.picture = .loaded(image) }

    /// 描き場所を貼る。
    public func texture(_ graphics: Canvas) {
        note(placing: graphics)
        style.picture = graphics.drawnPicture
    }

    public func noTexture() { style.picture = nil }

    // MARK: - 置く

    /// この描き場所を読む絵として渡す値。**大きさは座標の大きさ**で、画素数ではない ([#3453])。
    /// 書き出しの倍率 (`mokume render --scale`) の下では描き場所は倍率の画素で刻まれるが、置く大きさ・
    /// 切り出し・読み取り位置は、倍率 1 で書いた作品と同じ数のまま読めなければならない。
    ///
    /// **置く側で倍率を掛け直さない。** 座標と画素の分け方は `init(output:gpu:pixelDensity:upscale:outputScale:)`
    /// の 1 本で、読む側はここで座標の大きさを受け取るだけ — 描き場所だけの換算を別に足すと、片方だけ直る。
    ///
    /// [#3453]: https://github.com/mokume-metal/mokume/issues/3453
    var drawnPicture: Picture { .drawn(output, width: Int(width), height: Int(height)) }

    /// 絵を等倍で置く。(`a`, `b`) の読み方は ``imageMode(_:)`` が決め、大きさは絵の画素数のまま。
    public func image(_ image: Image, _ a: some ScalarConvertible, _ b: some ScalarConvertible) {
        let (a, b) = (a.asFloat, b.asFloat)
        place(.loaded(image), a, b)
    }

    /// 絵を、指定した寸法に合わせて置く。
    public func image(_ image: Image, _ a: some ScalarConvertible, _ b: some ScalarConvertible, _ c: some ScalarConvertible, _ d: some ScalarConvertible) {
        let (a, b, c, d) = (a.asFloat, b.asFloat, c.asFloat, d.asFloat)
        place(.loaded(image), a, b, c, d)
    }

    /// 絵の一部を切り出して置く。
    ///
    /// 前の 4 つが置き先、後の 4 つが**絵の中のどこを切り出すか** (左上と大きさ)。
    public func image(
        _ image: Image, _ a: some ScalarConvertible, _ b: some ScalarConvertible, _ c: some ScalarConvertible, _ d: some ScalarConvertible,
        _ sourceX: some ScalarConvertible, _ sourceY: some ScalarConvertible, _ sourceWidth: some ScalarConvertible, _ sourceHeight: some ScalarConvertible
    ) {
        let (a, b, c, d, sourceX, sourceY, sourceWidth, sourceHeight) = (a.asFloat, b.asFloat, c.asFloat, d.asFloat, sourceX.asFloat, sourceY.asFloat, sourceWidth.asFloat, sourceHeight.asFloat)
        place(.loaded(image), a, b, c, d, sourceX, sourceY, sourceWidth, sourceHeight)
    }

    /// 描き場所を等倍で置く。(`a`, `b`) の読み方は ``imageMode(_:)`` が決め、大きさは描き場所の座標の大きさのまま (書き出しの倍率の下でも変わらない)。
    public func image(_ graphics: Canvas, _ a: some ScalarConvertible, _ b: some ScalarConvertible) {
        let (a, b) = (a.asFloat, b.asFloat)
        note(placing: graphics)
        place(graphics.drawnPicture, a, b)
    }

    /// 描き場所を、指定した寸法に合わせて置く。
    public func image(_ graphics: Canvas, _ a: some ScalarConvertible, _ b: some ScalarConvertible, _ c: some ScalarConvertible, _ d: some ScalarConvertible) {
        let (a, b, c, d) = (a.asFloat, b.asFloat, c.asFloat, d.asFloat)
        note(placing: graphics)
        place(graphics.drawnPicture, a, b, c, d)
    }

    /// 描き場所の一部を切り出して置く。
    public func image(
        _ graphics: Canvas, _ a: some ScalarConvertible, _ b: some ScalarConvertible, _ c: some ScalarConvertible, _ d: some ScalarConvertible,
        _ sourceX: some ScalarConvertible, _ sourceY: some ScalarConvertible, _ sourceWidth: some ScalarConvertible, _ sourceHeight: some ScalarConvertible
    ) {
        let (a, b, c, d, sourceX, sourceY, sourceWidth, sourceHeight) = (a.asFloat, b.asFloat, c.asFloat, d.asFloat, sourceX.asFloat, sourceY.asFloat, sourceWidth.asFloat, sourceHeight.asFloat)
        note(placing: graphics)
        place(
            graphics.drawnPicture, a, b, c, d, sourceX, sourceY, sourceWidth, sourceHeight)
    }

    // MARK: - 範囲を Rect で渡す形 (#3783)
    //
    // **`imageMode` に従わない** — `Rect` は左上で置く値なので、値のとおり左上から置く
    // (ADR-0045 決定 5・`Rect.draw()` が `rectMode` に従わないのと同じ)。

    /// 絵を `destination` に合わせて置く。``imageMode(_:)`` が既定 (`.corner`) のときの
    /// `image(_:_:_:_:_:)` に `destination` の左上と大きさを渡すのと同じ。
    public func image(_ image: Image, in destination: Rect) {
        place(.loaded(image), destination.left, destination.top, destination.width, destination.height, mode: .corner)
    }

    /// 絵の `source` の範囲を切り出して `destination` に置く。``imageMode(_:)`` が既定のときの
    /// 9 つの引数の形に、2 つの範囲の左上と大きさを渡すのと同じ。
    public func image(_ image: Image, in destination: Rect, from source: Rect) {
        place(
            .loaded(image), destination.left, destination.top, destination.width, destination.height,
            source.left, source.top, source.width, source.height, mode: .corner)
    }

    /// 描き場所を `destination` に合わせて置く。``imageMode(_:)`` が既定のときの 5 つの引数の形と同じ。
    public func image(_ graphics: Canvas, in destination: Rect) {
        note(placing: graphics)
        place(
            graphics.drawnPicture, destination.left, destination.top, destination.width, destination.height,
            mode: .corner)
    }

    /// 描き場所の `source` の範囲を切り出して `destination` に置く。``imageMode(_:)`` が既定のときの
    /// 9 つの引数の形と同じ。
    public func image(_ graphics: Canvas, in destination: Rect, from source: Rect) {
        note(placing: graphics)
        place(
            graphics.drawnPicture, destination.left, destination.top, destination.width, destination.height,
            source.left, source.top, source.width, source.height, mode: .corner)
    }

    // MARK: - 置き方は 1 本

    /// 絵を置く。**読み込んだ絵も描き場所もここへ集まる** ([ADR-0023] 決定 1)。
    ///
    /// [ADR-0023]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0023-frame-stages-and-outputs.md
    private func place(_ picture: Picture, _ a: Float, _ b: Float) {
        // 3 つの数の形は、(a, b) の読み方だけを imageMode に任せ、大きさは絵の画素数の
        // ままにする。幅と高さを後の 2 つの数としてそのまま渡すと、.corners はそれを
        // 2 つ目の角として、.radius は半径として読んでしまう (#1531)
        let (width, height) = (Float(picture.width), Float(picture.height))
        let (c, d): (Float, Float) =
            switch style.imageMode {
            case .corner, .center: (width, height)
            case .corners: (a + width, b + height)
            case .radius: (width / 2, height / 2)
            }
        place(picture, a, b, c, d)
    }

    /// `mode` を渡さなければ ``imageMode(_:)`` で読む。`Rect` を取る形は `.corner` を渡し、値の
    /// とおり左上で置く (#3783)。
    private func place(
        _ picture: Picture, _ a: Float, _ b: Float, _ c: Float, _ d: Float, mode: ShapeMode? = nil
    ) {
        place(
            picture, a, b, c, d, 0, 0, Float(picture.width), Float(picture.height), mode: mode)
    }

    private func place(
        _ picture: Picture, _ a: Float, _ b: Float, _ c: Float, _ d: Float,
        _ sourceX: Float, _ sourceY: Float, _ sourceWidth: Float, _ sourceHeight: Float,
        mode: ShapeMode? = nil
    ) {
        let box = Self.resolveBox(a, b, c, d, mode: mode ?? style.imageMode)
        guard box.width > 0, box.height > 0, picture.width > 0, picture.height > 0 else {
            return
        }

        // 切り出しは絵の中へ収める。外を指しても落ちず、重なった分だけが同じ倍率で
        // 指した場所に出る (置き先は下で同じ割合で締める)
        let full = SIMD2(Float(picture.width), Float(picture.height))
        let left = min(max(0, sourceX), full.x)
        let top = min(max(0, sourceY), full.y)
        let right = min(max(left, sourceX + sourceWidth), full.x)
        let bottom = min(max(top, sourceY + sourceHeight), full.y)
        guard right > left, bottom > top else { return }
        // 絵はベクターへ埋め込まない (#3139)
        noteVectorDrop(.image)

        // **置き先も、切り出しを締めた割合で締める** (#1532)。締めずに置くと、重なった分が
        // 置き先いっぱいに引き伸ばされ、はみ出した量で倍率と縦横比が変わる。倍率は
        // `置き先 / 切り出し` のまま (canvas の `drawImage` と同じ扱い)。上の guard を
        // 通ったなら切り出しの幅と高さは正なので、0 では割らない
        let scale = SIMD2(box.width / sourceWidth, box.height / sourceHeight)
        let x = box.x + (left - sourceX) * scale.x
        let y = box.y + (top - sourceY) * scale.y
        let width = (right - left) * scale.x
        let height = (bottom - top) * scale.y

        appendImageQuad(
            picture, x: x, y: y, width: width, height: height,
            uvMin: SIMD2(left / full.x, top / full.y),
            uvMax: SIMD2(right / full.x, bottom / full.y),
            color: style.tint)
    }
}

/// 控えの鍵。**整え方の選択肢が無いので、名前だけ** (`ModelRequest` は整え方も含む)。
struct ImageRequest: Hashable {
    var path: String
}

/// 控えた復号結果。**読んだ場所と更新時刻も持つ** — 差し替えを見逃さないため。
struct DecodedImage {
    /// どこから読んだか。
    enum Origin {
        /// ファイル。読んだ場所と、そのときの更新時刻 (読めなければ nil)。
        case file(url: URL, stamp: FileStamp?)
        /// URL から受け取った。実行のあいだ読み直さない (#3715)。
        case web
    }

    var origin: Origin
    var decoded: ImageFile.Decoded

    /// 画素が占める大きさ (バイト)。控えの量を数えるのに使う。
    var bytes: Int { decoded.pixels.count * MemoryLayout<SIMD4<Float16>>.stride }
}
