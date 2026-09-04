// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT


// 揺らぎ。説明文の正本は ``Sketch`` 側にある (ADR-0020 決定 4)。
//
// **種と細かさをここに置くのは、断片へ届ける必要があるためである。** 値は
// uniforms を通って ``Fragment`` に入り、断片の `mokume_noise()` が同じ模様を出す。
// 影と違ってフレームを越えて残る — 毎フレーム消える種は種として役に立たない。
extension Canvas {

    // 揺らぎの種。
    public func noiseSeed(_ seed: Int) {
        noiseSettings.seed = UInt32(bitPattern: Int32(truncatingIfNeeded: seed))
    }

    // 揺らぎの細かさ (重ねる枚数と、1 枚ごとの弱まり)。
    public func noiseDetail(_ lod: Int, _ falloff: Float = 0.5) {
        guard ValueNoise.octaveRange.contains(lod) else { return warnBadNoise("noiseDetail") }
        guard falloff.isFinite, (0...1).contains(falloff) else {
            return warnBadNoise("noiseDetail")
        }
        noiseSettings.octaves = lod
        noiseSettings.falloff = falloff
    }

    // その座標の揺らぎ (0…1)。
    public func noise(_ x: Float, _ y: Float = 0, _ z: Float = 0) -> Float {
        noiseSettings.value(x, y, z)
    }

    /// 受け取れない値を、初回だけ知らせる。
    private func warnBadNoise(_ name: String) {
        warnOnce(
            .badNoise,
            "\(name)(): 数でない値・範囲の外の値が渡されたので、揺らぎの設定を変えませんでした")
    }
}
