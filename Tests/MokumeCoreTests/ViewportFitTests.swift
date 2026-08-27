// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeCore

@Suite("面への収まり方")
struct ViewportFitTests {
    @Test("縦横比が一致していれば、面いっぱいに広がる")
    func matchingAspectFillsTheSurface() {
        let fit = ViewportFit.fit(contentAspect: 16.0 / 9, surfaceWidth: 1600, surfaceHeight: 900)
        #expect(fit == ViewportFit(x: 0, y: 0, width: 1600, height: 900))
    }

    @Test("面のほうが横長なら、左右に帯が出る")
    func widerSurfaceGetsSideBands() {
        // 16:9 の絵を 2:1 の面へ。高さいっぱい (900)、幅は 1600 に収まる
        let fit = ViewportFit.fit(contentAspect: 16.0 / 9, surfaceWidth: 1800, surfaceHeight: 900)
        #expect(fit.height == 900)
        #expect(fit.width == 1600)
        #expect(fit.y == 0)
        #expect(fit.x == 100)
    }

    @Test("面のほうが縦長なら、上下に帯が出る")
    func tallerSurfaceGetsTopAndBottomBands() {
        // 16:9 の絵を 1:1 の面へ。幅いっぱい (900)、高さは 506.25 に収まる
        let fit = ViewportFit.fit(contentAspect: 16.0 / 9, surfaceWidth: 900, surfaceHeight: 900)
        #expect(fit.width == 900)
        #expect(abs(fit.height - 506.25) < 1e-9)
        #expect(fit.x == 0)
        #expect(abs(fit.y - (900 - 506.25) / 2) < 1e-9)
    }

    @Test("帯は上下・左右で均等に分かれる")
    func bandsAreSplitEvenly() {
        let fit = ViewportFit.fit(contentAspect: 1, surfaceWidth: 1000, surfaceHeight: 400)
        #expect(fit.x == 300)
        #expect(fit.x + fit.width == 700)
    }

    @Test("面が潰れていても壊れない", arguments: [(0.0, 100.0), (100.0, 0.0)])
    func degenerateSurfaceIsHarmless(size: (width: Double, height: Double)) {
        let fit = ViewportFit.fit(
            contentAspect: 16.0 / 9, surfaceWidth: size.width, surfaceHeight: size.height)
        #expect(fit == ViewportFit(x: 0, y: 0, width: 0, height: 0))
    }
}
