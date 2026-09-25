// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import mokume

/// 参照スケッチ 1 本。名前は窓を開く・書き出す・台帳の行の 3 つで同じものを使う。
///
/// **`main.swift` の外に置く。** あちらの global は top-level のコードが走る順に初期化
/// されるので、そのコードが走らない検査のプロセスから読むと、初期化される前の値を読む。
/// 別のファイルの global は最初に読まれたときに初期化される (台帳の検査が読む — #1377)。
nonisolated struct ReferenceSketch: Sendable, CustomStringConvertible {
    let name: String
    let make: @MainActor @Sendable () -> any Sketch

    init(name: String, make: @escaping @MainActor @Sendable () -> any Sketch) {
        self.name = name
        self.make = make
    }

    var description: String { name }
}

/// 1 枚で書き出すときに描くフレームの番号。**台帳もこの番号の絵を指紋にする**ので、
/// 綴りはここ 1 箇所に置く。時計はフレーム番号から導くので、何度撮っても同じ絵になる
nonisolated let stillFrame = 45

nonisolated let catalogue: [ReferenceSketch] = [
    ReferenceSketch(name: "shapes-and-style") { ShapesAndStyle() },
    ReferenceSketch(name: "curves-and-vertices") { CurvesAndVertices() },
    ReferenceSketch(name: "color-and-scale") { ColorAndScale() },
    ReferenceSketch(name: "type-and-imagery") { TypeAndImagery() },
    ReferenceSketch(name: "type-and-measure") { TypeAndMeasure() },
    ReferenceSketch(name: "textured-surfaces") { TexturedSurfaces() },
    ReferenceSketch(name: "pixels-and-paint") { PixelsAndPaint() },
    ReferenceSketch(name: "noise-and-seed") { NoiseAndSeed() },
    ReferenceSketch(name: "surface-and-grain") { SurfaceAndGrain() },
    ReferenceSketch(name: "band-and-pattern") { BandAndPattern() },
    ReferenceSketch(name: "facing-and-view") { FacingAndView() },
    ReferenceSketch(name: "surfaces-and-blend") { SurfacesAndBlend() },
    ReferenceSketch(name: "field-and-flow") { FieldAndFlow() },
    ReferenceSketch(name: "sparks-and-forces") { SparksAndForces() },
    ReferenceSketch(name: "sparks-in-space") { SparksInSpace() },
    ReferenceSketch(name: "glow-and-detail") { GlowAndDetail() },
    ReferenceSketch(name: "effects-and-custom") { EffectsAndCustom() },
    // 触って確かめるためのもの。**書き出しても触っていない 1 枚しか出ない**が、台帳には
    // 「走っても落ちない」の検査として載る。カタログを 2 つに割るほどの違いではない
    ReferenceSketch(name: "pointer-and-keys") { PointerAndKeys() },
    ReferenceSketch(name: "knobs-and-values") { KnobsAndValues() },
    ReferenceSketch(name: "solids-and-light") { SolidsAndLight() },
    ReferenceSketch(name: "materials-and-surroundings") { MaterialsAndSurroundings() },
    ReferenceSketch(name: "crowd-and-model") { CrowdAndModel() },
]
