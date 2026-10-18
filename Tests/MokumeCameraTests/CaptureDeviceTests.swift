// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeCamera

/// カメラ 1 台の値 (``CaptureDevice``) と、出せる形式 (``CaptureFormat``) の並べ方 (#2453)。機材も GPU も要らない。
@Suite("カメラ機材の形式")
struct CaptureDeviceTests {
    private let hd = CaptureFormat(width: 1280, height: 720, frameRates: 1...30)
    private let full = CaptureFormat(width: 1920, height: 1080, frameRates: 1...30)

    @Test("同じ機材は、形式の並びが違っても (読めたかどうかによらず) 等しく、同じハッシュになる")
    func equalityIgnoresFormats() {
        let plain = CaptureDevice(id: "cam-1", name: "FaceTime HD Camera")
        let listed = CaptureDevice(id: "cam-1", name: "FaceTime HD Camera", formats: [full, hd])
        #expect(plain == listed)
        #expect(plain.hashValue == listed.hashValue)
        #expect(Set([plain, listed]).count == 1)
        // 識別子か名前が違えば別の機材
        #expect(plain != CaptureDevice(id: "cam-2", name: "FaceTime HD Camera"))
        #expect(plain != CaptureDevice(id: "cam-1", name: "Other"))
    }

    @Test("形式の名乗りを持たない機材は、形式が空")
    func noFormatsIsEmpty() {
        #expect(CaptureDevice(id: "x", name: "y").formats.isEmpty)
        #expect(CaptureFormat.listing(of: []).isEmpty)
    }

    @Test("形式の値は、大きさとフレームレートの範囲で等しい")
    func formatValue() {
        #expect(hd == CaptureFormat(width: 1280, height: 720, frameRates: 1...30))
        #expect(hd != CaptureFormat(width: 1280, height: 720, frameRates: 1...60))
        #expect(full.frameRates.upperBound == 30)
    }
}
