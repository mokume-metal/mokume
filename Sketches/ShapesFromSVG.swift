// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import mokume

/// 外の描画ツールで書いた SVG を読んで、形として置く (`loadShape`)。
///
/// **左**は Illustrator の書き出しの形 (`<style>` のクラス・群の変換・相対の命令・弧・角丸の
/// 矩形) で書いたロゴを、ファイルの色のまま等倍で置いたもの。**まん中**は同じ形を 4 倍に
/// 拡大して置いたもので、縁は粗くならずに滑らかに出る — 画像に焼いて貼った絵を拡大したの
/// とは違う。**右**は Figma の書き出しの形 (`fill-rule="evenodd"` の穴) で白く描いた印を、
/// 置き場所ごとに色を掛けて (`Placement` の `fill`) 回しながら並べたもの。白に掛けた色は、
/// そのまま印の色になる。
///
/// **上端の波は書き出しの絵には出ない。** 読んでいる間フレームを止めない読み方
/// (`requestShape`) で読んでいて、書き出しはフレームを続けて進めるだけで読み終わりを受け取る
/// 番が回らない (`crowd-and-model` の波打つ板と同じ)。窓で走らせれば、起動して間もなく現れる。
final class ShapesFromSVG: Sketch {
    var settings = SketchSettings(width: 1200, height: 600, title: "shapes from svg")

    /// ファイルの色のまま読んだロゴ。
    private var logo: Shape?
    /// 白い印を、中心が原点に来るように置き直した形 (回すときに中心で回るように)。
    private var mark: Shape?
    /// 待たない口で読む上端の波。**届くまでは `nil`**
    private var wave: Shape?

    /// 印に掛ける色。
    private static let tints: [LinearRGBA] = [
        color(242, 154, 71), color(89, 191, 242), color(120, 200, 140),
        color(230, 90, 120), color(250, 220, 90), color(180, 140, 250),
    ]

    func setup() {
        // **リポジトリには SVG のファイルを置かない**ので、検体をここで書き出してから読んで
        // いる。**普通のスケッチにこの書き出しは要らない** — 手元にあるファイルの場所を
        // `loadShape` へ渡すだけでよい
        logo = try? loadShape(Self.written(Self.logoSource, as: "mokume-reference-logo.svg"))
        if let read = try? loadShape(Self.written(Self.markSource, as: "mokume-reference-mark.svg")) {
            // 印の viewBox は 64 四方。読んだ形を組み立ての中で置き直すと、中心が原点に来る
            mark = createShape { shape(read, -32, -32) }
        }
        // 読んでいる間フレームを止めない読み方。読み解きは別の仕事で回り、形にするのは届いた後
        let wavePath = Self.written(Self.waveSource, as: "mokume-reference-wave.svg")
        Task { wave = try? await requestShape(wavePath) }
    }

    func draw() {
        background(18, 22, 30)

        if let logo {
            // 左: 等倍。SVG の原点 (viewBox の左上) が渡した位置に来る
            shape(logo, 80, 190)

            // まん中: 4 倍。左上の 4 分の 1 ほど (葉の縁・三日月・輪の縁) を切り抜いて見せる
            clip(360, 40, 400, 520)
            push()
            translate(360 - 15 * 4, 40 - 10 * 4)
            scale(4, 4)
            shape(logo)
            pop()
            noClip()
        }

        if let mark {
            // 右: 置き場所ごとに位置・大きさ・回転・掛ける色を変える
            var places: [Placement] = []
            for index in 0..<6 {
                let column = Float(index % 2)
                let row = Float(index / 2)
                places.append(
                    Placement(
                        x: 900 + column * 170, y: 130 + row * 170,
                        scale: 1.2 + 0.3 * Float(index % 3),
                        rotation: SIMD3(0, 0, time * (0.4 + 0.2 * Float(index)) + Float(index)),
                        fill: Self.tints[index]))
            }
            shape(mark, at: places)
        }

        if let wave { shape(wave, 0, 6) }

        fill(200, 205, 215)
        noStroke()
        text("loadShape(\"logo.svg\") — file colors, 1x", 60, 400)
        text("same shape, 4x", 360, 585)
        text("white mark × Placement(fill:)", 860, 585)
    }

    /// 文字を一時ディレクトリへ書いて、その場所を返す。
    private static func written(_ text: String, as name: String) -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try? text.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    /// Illustrator の「書き出し形式 → SVG」(スタイル: 内部 CSS) の形を真似て手で書いたロゴ。
    /// 輪・葉・葉脈・三日月・2 つの粒 (群を回して置く)・角丸の札でできている。
    static let logoSource = """
        <?xml version="1.0" encoding="UTF-8"?>
        <svg id="Layer_1" data-name="Layer 1" xmlns="http://www.w3.org/2000/svg" width="160" height="160" viewBox="0 0 160 160">
          <defs>
            <style>
              .cls-1 { fill: #1f6f78; }
              .cls-2 { fill: #f29a47; }
              .cls-3 { fill: none; stroke: #fdf6e3; stroke-linecap: round; stroke-miterlimit: 10; stroke-width: 4px; }
              .cls-4 { fill: #fdf6e3; }
            </style>
          </defs>
          <title>leaf mark</title>
          <circle class="cls-1" cx="80" cy="80" r="76"/>
          <path class="cls-2" d="M80 22c26 18 38 42 34 68-3 22-18 38-34 46-16-8-31-24-34-46-4-26 8-50 34-68z"/>
          <path class="cls-3" d="M80 128V48m0 30 18-16M80 98l-20-18"/>
          <path class="cls-4" d="M44 34a14 14 0 1 0 8 26 18 18 0 1 1-8-26z"/>
          <g transform="translate(80 80) rotate(-30)">
            <ellipse class="cls-4" cx="0" cy="-64" rx="6" ry="4"/>
            <ellipse class="cls-4" cx="0" cy="64" rx="6" ry="4"/>
          </g>
          <rect class="cls-4" x="56" y="140" width="48" height="10" rx="5"/>
        </svg>
        """

    /// 上端の波。半円の弧 (`a`) を交互の向きに 30 回つないだ 1 本の線。
    static let waveSource = """
        <svg xmlns="http://www.w3.org/2000/svg" width="1200" height="24" viewBox="0 0 1200 24">
          <path d="M0 12\(String(repeating: "a20 10 0 0 1 40 0a20 10 0 0 0 40 0", count: 15))" fill="none" stroke="#3a4a5c" stroke-width="3"/>
        </svg>
        """

    /// Figma の書き出しの形を真似て手で書いた、白い印。輪は外周と穴を同じ向きに書いて
    /// `evenodd` で抜いてある (Figma がよく書く形)。
    static let markSource = """
        <svg width="64" height="64" viewBox="0 0 64 64" fill="none" xmlns="http://www.w3.org/2000/svg">
        <path fill-rule="evenodd" clip-rule="evenodd" d="M32 4C47.464 4 60 16.536 60 32C60 47.464 47.464 60 32 60C16.536 60 4 47.464 4 32C4 16.536 16.536 4 32 4ZM32 14C22.059 14 14 22.059 14 32C14 41.941 22.059 50 32 50C41.941 50 50 41.941 50 32C50 22.059 41.941 14 32 14Z" fill="white"/>
        <path d="M32 21L42 39H22L32 21Z" fill="white"/>
        </svg>
        """
}
