// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import CoreGraphics
import CoreText

// 組版した文字列を描く・測る入口 (#2404)。意味の説明は `Sketch` が正本 ([ADR-0020] 決定 4)。
//
// 既存の `text()`・`textWidth()`・`textBounds()` (Unicode のスカラ 1 つずつ・幅の加法性) は変えず、
// 別の口として足す。**描く・幅・整列・墨の範囲は、どれも `Typeface.shape(_:)` の 1 つの結果から出す。**
//
// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
extension Canvas {
    /// 組版した文字列の送り幅 (画素)。改行を含む文字列では、いちばん長い行の幅。
    public func shapedTextWidth(_ string: String) -> Float {
        guard style.textSize > 0 else { return 0 }
        let face = typeface
        var widest: Float = 0
        for line in string.lines {
            widest = max(widest, face.shape(String(line)).width)
        }
        return widest
    }

    /// 組版した文字列を描く。
    public func shapedText(_ string: String, _ x: some ScalarConvertible, _ y: some ScalarConvertible) {
        let (x, y) = (x.asFloat, y.asFloat)
        guard let color = textFillColor, !string.isEmpty, style.textSize > 0 else { return }
        let face = typeface
        let lines = string.lines
        let leading = resolvedTextLeading
        var baseline = firstBaseline(at: y, face: face, lines: lines.count)

        for line in lines {
            drawShapedLine(face.shape(String(line)), x: x, baseline: baseline, color: color)
            baseline += leading
        }
    }

    /// 組版した文字列の墨が載る範囲。墨が無ければ `nil`。
    public func shapedTextBounds(
        _ string: String, _ x: some ScalarConvertible, _ y: some ScalarConvertible
    ) -> TextBounds? {
        let (x, y) = (x.asFloat, y.asFloat)
        guard !string.isEmpty, style.textSize > 0, x.isFinite, y.isFinite else { return nil }
        let face = typeface
        let lines = string.lines
        let leading = resolvedTextLeading
        var baseline = firstBaseline(at: y, face: face, lines: lines.count)
        var box = CGRect.null

        for line in lines {
            let shaped = face.shape(String(line))
            let pen = shapedPenStart(at: x, width: shaped.width)
            for glyph in shaped.glyphs {
                let resolved = glyph.resolved
                guard
                    let ink = face.ink(
                        of: resolved, keeping: atlas, as: glyphKey(for: resolved)),
                    !ink.isNull, ink.width > 0 || ink.height > 0
                else { continue }
                // 字形の座標は基準線から上向き。面の縦向きへ折り返す (`textBounds` と同じ)
                let origin = CGPoint(
                    x: CGFloat(pen + glyph.x), y: CGFloat(baseline - glyph.y))
                box = box.union(
                    CGRect(
                        x: origin.x + ink.minX, y: origin.y - ink.maxY, width: ink.width,
                        height: ink.height))
            }
            baseline += leading
        }
        guard !box.isNull else { return nil }
        return TextBounds(
            x: Float(box.minX), y: Float(box.minY), width: Float(box.width), height: Float(box.height))
    }

    /// 1 行の書き始め。**横の整列と、組版した行の幅から決まる。**
    private func shapedPenStart(at x: Float, width: Float) -> Float {
        switch style.horizontalTextAlign {
        case .left: return x
        case .center: return x - width / 2
        case .right: return x - width
        }
    }

    /// 組版した 1 行を置く。字形は組版が決めた位置 (`x`・`y`) に置く。
    private func drawShapedLine(_ line: ShapedLine, x: Float, baseline: Float, color: LinearRGBA) {
        guard canPlace else { return warnOutsideFrame(.placing) }
        guard !line.glyphs.isEmpty else { return }
        let pen = shapedPenStart(at: x, width: line.width)

        for (index, glyph) in line.glyphs.enumerated() {
            let entry: GlyphAtlas.Entry
            // 同じ頁で引いたことのある字形は、焼き場を引かない
            if let placed = line.placed[index], placed.pageSerial == atlas.pageSerial {
                entry = placed.entry
            } else if let found = glyphEntry(for: glyph.resolved) {
                // 引いた後の頁の番号で控える — 引く途中で頁を広げていれば、番号も新しい
                line.placed[index] = PlacedGlyph(
                    pageSerial: atlas.pageSerial, entry: found, advance: 0)
                entry = found
            } else {
                continue
            }
            if !entry.isBlank {
                appendGlyphQuad(
                    entry, penX: pen + glyph.x, baseline: baseline - glyph.y, color: color)
            }
        }
    }
}
