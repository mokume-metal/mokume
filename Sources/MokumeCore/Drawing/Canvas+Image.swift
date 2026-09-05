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
    /// [#886]: https://github.com/mokume-metal/mokume/issues/886
    public func loadImage(_ path: String) throws(ImageFailure) -> Image {
        if let fresh = freshDecoded(for: path) { return try makeImage(fresh) }
        let url = try ImageFile.locate(path)
        let stamp = ImageFile.stamp(of: url)
        let decoded = try ImageFile.decode(at: url, name: path)
        remember(decoded, path: path, url: url, stamp: stamp)
        return try makeImage(decoded)
    }

    /// 絵を読む。**読んでいる間、他の仕事を止めない。**
    ///
    /// 控えに当たれば別の仕事を起こさない (`requestModel` と同じ形)。
    public func requestImage(_ path: String) async throws(ImageFailure) -> Image {
        if let fresh = freshDecoded(for: path) { return try makeImage(fresh) }
        let read: ImageFile.Read
        do {
            read = try await Task.detached(priority: .utility) {
                try ImageFile.read(path)
            }.value
        } catch let failure as ImageFailure {
            throw failure
        } catch {
            throw .undecodable(path: path)
        }
        remember(read.decoded, path: path, url: read.url, stamp: read.stamp)
        return try makeImage(read.decoded)
    }

    // MARK: - 控え

    /// 控えのうち、**いまもファイルと一致しているもの**を返す。
    ///
    /// 名前だけを鍵にしない。走らせたまま絵を差し替える書き方は、いまは毎フレーム読み直す
    /// ことで成り立っており、名前だけで引くとそれが黙って効かなくなる。更新時刻を読めな
    /// かったときも当たりにしない — 読み直す側 (安全な側) へ倒す。
    private func freshDecoded(for path: String) -> ImageFile.Decoded? {
        let request = ImageRequest(path: path)
        guard let cached = imageCache[request],
            let stamp = ImageFile.stamp(of: cached.url), stamp == cached.stamp
        else { return nil }
        touch(request)
        return cached.decoded
    }

    /// 復号したものを控えに入れる。**量が上限を超えたら、収まるまで古い順に捨てる**
    /// (追い出しの形は `solidMesh(for:)` と同じで、数える単位だけが違う)。
    private func remember(
        _ decoded: ImageFile.Decoded, path: String, url: URL, stamp: Date?
    ) {
        let request = ImageRequest(path: path)
        imageCacheBytes -= imageCache[request]?.bytes ?? 0
        let entry = DecodedImage(url: url, stamp: stamp, decoded: decoded)
        imageCache[request] = entry
        imageCacheBytes += entry.bytes
        imagesDecoded += 1
        touch(request)
        // **いま読んだものは残す。** 1 枚で上限を超える絵はありうるが、そこで空にしても
        // 読み直しが増えるだけで、抱える量は減らない (その絵は読んだ側が持っている)
        while imageCacheBytes > Canvas.imageCacheBudget, imageCache.count > 1,
            let oldest = imageCacheUse.min(by: { $0.value < $1.value })?.key
        {
            imageCacheBytes -= imageCache.removeValue(forKey: oldest)?.bytes ?? 0
            imageCacheUse.removeValue(forKey: oldest)
        }
    }

    /// 最後に使った時刻を進める。
    private func touch(_ request: ImageRequest) {
        imageCacheUse[request] = imageCacheClock
        imageCacheClock += 1
    }

    /// 空の絵を作る。中身は透明。
    ///
    /// **大きすぎる指定は、画素を組む前に断る。** 面が作れないことは後段
    /// (`RenderDevice.makeTexture`) が同じ ``ImageFailure/unplaceable(width:height:)``
    /// として返すので、守りはそちらの 1 箇所のままである。ここで先に見るのは
    /// **捨てるものを確保しない**ため — 20000×20000 は Metal に触る前に 3.2 GB の
    /// 画素配列を組むことになる ([#885](https://github.com/mokume-metal/mokume/issues/885))。
    public func createImage(_ width: Int, _ height: Int) throws(ImageFailure) -> Image {
        let width = max(1, width)
        let height = max(1, height)
        guard width <= RenderDevice.maxTextureSide, height <= RenderDevice.maxTextureSide else {
            throw .unplaceable(width: width, height: height)
        }
        return try makeImage(
            ImageFile.Decoded(
                width: width, height: height,
                pixels: [SIMD4<Float16>](repeating: .zero, count: width * height)))
    }

    // MARK: - 置き方

    public func imageMode(_ mode: ShapeMode) { currentImageMode = mode }

    /// 絵に掛ける色。**掛け算なので、白は何も変えない。**
    public func tint(_ color: LinearRGBA) { currentTint = color }

    public func noTint() { currentTint = .linear(red: 1, green: 1, blue: 1) }

    // MARK: - 貼る

    // これから置く塗りに絵を貼る。
    public func texture(_ image: Image) { currentPicture = .loaded(image) }

    /// 描き場所を貼る。
    public func texture(_ graphics: Canvas) {
        note(placing: graphics)
        currentPicture = .drawn(graphics.output)
    }

    public func noTexture() { currentPicture = nil }

    // MARK: - 置く

    /// 絵を等倍で置く。
    public func image(_ image: Image, _ a: Float, _ b: Float) {
        place(.loaded(image), a, b)
    }

    /// 絵を、指定した寸法に合わせて置く。
    public func image(_ image: Image, _ a: Float, _ b: Float, _ c: Float, _ d: Float) {
        place(.loaded(image), a, b, c, d)
    }

    /// 絵の一部を切り出して置く。
    ///
    /// 前の 4 つが置き先、後の 4 つが**絵の中のどこを切り出すか** (左上と大きさ)。
    public func image(
        _ image: Image, _ a: Float, _ b: Float, _ c: Float, _ d: Float,
        _ sourceX: Float, _ sourceY: Float, _ sourceWidth: Float, _ sourceHeight: Float
    ) {
        place(.loaded(image), a, b, c, d, sourceX, sourceY, sourceWidth, sourceHeight)
    }

    /// 描き場所を等倍で置く。
    public func image(_ graphics: Canvas, _ a: Float, _ b: Float) {
        note(placing: graphics)
        place(.drawn(graphics.output), a, b)
    }

    /// 描き場所を、指定した寸法に合わせて置く。
    public func image(_ graphics: Canvas, _ a: Float, _ b: Float, _ c: Float, _ d: Float) {
        note(placing: graphics)
        place(.drawn(graphics.output), a, b, c, d)
    }

    /// 描き場所の一部を切り出して置く。
    public func image(
        _ graphics: Canvas, _ a: Float, _ b: Float, _ c: Float, _ d: Float,
        _ sourceX: Float, _ sourceY: Float, _ sourceWidth: Float, _ sourceHeight: Float
    ) {
        note(placing: graphics)
        place(
            .drawn(graphics.output), a, b, c, d, sourceX, sourceY, sourceWidth, sourceHeight)
    }

    // MARK: - 置き方は 1 本

    /// 絵を置く。**読み込んだ絵も描き場所もここへ集まる** ([ADR-0023] 決定 1)。
    ///
    /// [ADR-0023]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0023-frame-stages-and-outputs.md
    private func place(_ picture: Picture, _ a: Float, _ b: Float) {
        place(picture, a, b, Float(picture.width), Float(picture.height))
    }

    private func place(
        _ picture: Picture, _ a: Float, _ b: Float, _ c: Float, _ d: Float
    ) {
        place(
            picture, a, b, c, d, 0, 0, Float(picture.width), Float(picture.height))
    }

    private func place(
        _ picture: Picture, _ a: Float, _ b: Float, _ c: Float, _ d: Float,
        _ sourceX: Float, _ sourceY: Float, _ sourceWidth: Float, _ sourceHeight: Float
    ) {
        let box = Self.resolveBox(a, b, c, d, mode: currentImageMode)
        guard box.width > 0, box.height > 0, picture.width > 0, picture.height > 0 else {
            return
        }

        // 切り出しは絵の中へ収める。外を指しても落ちず、指した分だけが出る
        let full = SIMD2(Float(picture.width), Float(picture.height))
        let left = min(max(0, sourceX), full.x)
        let top = min(max(0, sourceY), full.y)
        let right = min(max(left, sourceX + sourceWidth), full.x)
        let bottom = min(max(top, sourceY + sourceHeight), full.y)
        guard right > left, bottom > top else { return }

        appendImageQuad(
            picture, x: box.x, y: box.y, width: box.width, height: box.height,
            uvMin: SIMD2(left / full.x, top / full.y),
            uvMax: SIMD2(right / full.x, bottom / full.y),
            color: currentTint)
    }
}

/// 控えの鍵。**整え方の選択肢が無いので、名前だけ** (`ModelRequest` は整え方も含む)。
struct ImageRequest: Hashable {
    var path: String
}

/// 控えた復号結果。**読んだ場所と更新時刻も持つ** — 差し替えを見逃さないため。
struct DecodedImage {
    var url: URL
    var stamp: Date?
    var decoded: ImageFile.Decoded

    /// 画素が占める大きさ (バイト)。控えの量を数えるのに使う。
    var bytes: Int { decoded.pixels.count * MemoryLayout<SIMD4<Float16>>.stride }
}
