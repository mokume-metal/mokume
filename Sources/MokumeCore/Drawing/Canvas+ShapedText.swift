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
        // 字はベクターへ書けない。字形の輪郭を持たない (#3139)
        noteVectorDrop(.text)
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
        // 拡大した字 (段 0 より上) は、`shapedText()` が別の鍵の画素で焼く。**段 0 の画素を預けても引き取られない**
        // ので、預けない (`textBounds` と同じ・#2560・#2446)。墨の測りは段 0 のまま
        let keepsPixels = glyphStep == 0

        for line in lines {
            let shaped = face.shape(String(line))
            let pen = shapedPenStart(at: x, width: shaped.width)
            for glyph in shaped.glyphs {
                let resolved = glyph.resolved
                guard
                    let ink = face.ink(
                        of: resolved, keeping: atlas, as: glyphKey(for: resolved),
                        keepsPixels: keepsPixels),
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
    ///
    /// **字を焼く段と先送りは `text()` の ``drawLine(_:face:x:baseline:color:)`` と同じ** (#3251) — 変換が字を拡げる
    /// 量から焼く段を行ごとに 1 度決め、段 > 0 の字形は拡大に合わせた画素で引く。上限を越えて近い段で置いた字は、
    /// 先送りした四角として控え、フレームの終わりに払う (``settleDeferredGlyphs(baking:)``)。
    private func drawShapedLine(_ line: ShapedLine, x: Float, baseline: Float, color: LinearRGBA) {
        guard canPlace else { return warnOutsideFrame(.placing) }
        guard !line.glyphs.isEmpty else { return }
        let pen = shapedPenStart(at: x, width: line.width)
        // 変換が字を拡げる量から、焼く段を決める。**行ごとに 1 度** (行の中で変換は変わらない・#2446)
        let step = glyphStep

        for (index, glyph) in line.glyphs.enumerated() {
            let penX = pen + glyph.x
            let glyphBaseline = baseline - glyph.y
            // 同じ頁で、同じ段で引いたことのある字形は、焼き場を引かない
            let known = step == 0 ? line.placed[index] : line.scaledPlacement(step: step, at: index)
            if let placed = known, placed.pageSerial == atlas.pageSerial {
                if !placed.entry.isBlank {
                    appendGlyphQuad(placed.entry, penX: penX, baseline: glyphBaseline, color: color)
                }
                continue
            }
            guard let found = glyphLookup(for: glyph.resolved, step: step, from: .shapedText) else { continue }
            let entry = found.entry
            // 引いた後の頁の番号で控える — 引く途中で頁を広げていれば、番号も新しい
            let placed = PlacedGlyph(pageSerial: atlas.pageSerial, entry: entry, advance: 0)
            if step == 0 {
                line.placed[index] = placed
            } else if found.settled {
                // 頼んだ段について答えが決まったときだけ (`text()` の ``Typeface/placedScaled`` と同じ)。
                // 先送りした字と、頁が溢れて低い段で描いた字は控えない — 次のフレームで頼んだ段を焼き直す
                line.notePlacedScaled(placed, step: step, at: index)
            }
            if !entry.isBlank {
                // 先送りした字は、先送りした字だけの列へ置き、フレームの終わりに絵が残るなら払う
                if let key = found.deferredKey, prepareDeferredRun() {
                    let start = appendGlyphQuad(
                        entry, penX: penX, baseline: glyphBaseline, color: color, inDeferredRun: true)
                    noteDeferredGlyph(
                        start: start, placedWith: entry, key: key, font: glyph.resolved.font,
                        penX: penX, baseline: glyphBaseline, color: color, from: .shapedText)
                } else {
                    appendGlyphQuad(entry, penX: penX, baseline: glyphBaseline, color: color)
                }
            }
        }
    }
}
