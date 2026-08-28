// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import simd

extension Canvas {
    // MARK: - 読む・作る

    /// 絵を読む。読み終わるまで返らない。
    public func loadImage(_ path: String) throws(ImageFailure) -> Image {
        try makeImage(ImageFile.decode(path))
    }

    /// 絵を読む。**読んでいる間、他の仕事を止めない。**
    public func requestImage(_ path: String) async throws(ImageFailure) -> Image {
        let decoded: ImageFile.Decoded
        do {
            decoded = try await Task.detached(priority: .utility) {
                try ImageFile.decode(path)
            }.value
        } catch let failure as ImageFailure {
            throw failure
        } catch {
            throw .undecodable(path: path)
        }
        return try makeImage(decoded)
    }

    /// 空の絵を作る。中身は透明。
    public func createImage(_ width: Int, _ height: Int) throws(ImageFailure) -> Image {
        let width = max(1, width)
        let height = max(1, height)
        return try makeImage(
            ImageFile.Decoded(
                width: width, height: height,
                pixels: [SIMD4<Float16>](repeating: .zero, count: width * height)))
    }

    // MARK: - 置き方

    // 4 つの数を、絵のどこの寸法として読むか。既定は**左上の角と、幅と高さ**。
    public func imageMode(_ mode: ShapeMode) { currentImageMode = mode }

    /// 絵に掛ける色。**掛け算なので、白は何も変えない。**
    public func tint(_ color: LinearRGBA) { currentTint = color }

    // 色掛けをやめる。
    public func noTint() { currentTint = .opaque(red: 1, green: 1, blue: 1) }

    // MARK: - 置く

    /// 絵を等倍で置く。
    public func image(_ image: Image, _ a: Float, _ b: Float) {
        self.image(image, a, b, Float(image.width), Float(image.height))
    }

    /// 絵を、指定した寸法に合わせて置く。
    public func image(_ image: Image, _ a: Float, _ b: Float, _ c: Float, _ d: Float) {
        self.image(
            image, a, b, c, d, 0, 0, Float(image.width), Float(image.height))
    }

    /// 絵の一部を切り出して置く。
    ///
    /// 前の 4 つが置き先、後の 4 つが**絵の中のどこを切り出すか** (左上と大きさ)。
    public func image(
        _ image: Image, _ a: Float, _ b: Float, _ c: Float, _ d: Float,
        _ sourceX: Float, _ sourceY: Float, _ sourceWidth: Float, _ sourceHeight: Float
    ) {
        let box = Self.resolveBox(a, b, c, d, mode: currentImageMode)
        guard box.width > 0, box.height > 0, image.width > 0, image.height > 0 else { return }

        // 切り出しは絵の中へ収める。外を指しても落ちず、指した分だけが出る
        let full = SIMD2(Float(image.width), Float(image.height))
        let left = min(max(0, sourceX), full.x)
        let top = min(max(0, sourceY), full.y)
        let right = min(max(left, sourceX + sourceWidth), full.x)
        let bottom = min(max(top, sourceY + sourceHeight), full.y)
        guard right > left, bottom > top else { return }

        appendImageQuad(
            image, x: box.x, y: box.y, width: box.width, height: box.height,
            uvMin: SIMD2(left / full.x, top / full.y),
            uvMax: SIMD2(right / full.x, bottom / full.y),
            color: currentTint)
    }
}
