// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// ``SketchPart/vertex(_:_:_:_:)`` の読み取り位置 `u`・`v` の単位 (``SketchPart/textureMode(_:)``)。
///
/// Processing の `textureMode(IMAGE)`・`textureMode(NORMAL)` に当たる。
public nonisolated enum TextureMode: Sendable, Equatable {
    /// 貼る画像の画素で読む (既定)。120 画素四方の画像の右下の角は `(120, 120)`。
    case image
    /// 画像の大きさによらず 0〜1 で読む。どの画像でも右下の角は `(1, 1)`。
    case normal
}

/// 貼る画像の端の外の読み方 (``SketchPart/textureWrap(_:)``)。
///
/// Processing の `textureWrap(CLAMP)`・`textureWrap(REPEAT)` に当たる。
public nonisolated enum TextureWrap: Sendable, Equatable {
    /// 端の外は端の色で延ばす (既定)。
    case clamp
    /// 端の外は反対側から読み、画像を繰り返す。
    case `repeat`
}
