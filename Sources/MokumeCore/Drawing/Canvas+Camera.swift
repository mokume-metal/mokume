// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import simd

// どこから、どう見るかを決める。**視点はシーンの記述なのでフレームを越えない**
// ([ADR-0021] 決定 4)。寿命と空間の取り方は ``Camera`` と同 ADR が定める。
//
// [ADR-0021]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0021-solid-space-and-frame-assembly.md
extension Canvas {

    // 視点を既定へ戻す。
    public func camera() {
        apply(defaultCamera, name: "camera")
    }

    // 見る位置・見ている先・上方向を決める。
    public func camera(
        _ eyeX: Float, _ eyeY: Float, _ eyeZ: Float,
        _ centerX: Float, _ centerY: Float, _ centerZ: Float,
        _ upX: Float, _ upY: Float, _ upZ: Float
    ) {
        var camera = currentCamera
        camera.eye = SIMD3(eyeX, eyeY, eyeZ)
        camera.center = SIMD3(centerX, centerY, centerZ)
        camera.up = SIMD3(upX, upY, upZ)
        apply(camera, name: "camera")
    }

    // 作っておいた視点を当てる。
    public func setCamera(_ camera: Camera) {
        apply(camera, name: "setCamera")
    }

    // 透視投影を既定へ戻す。
    public func perspective() {
        apply(replacingProjection: Camera.defaultPerspective(width: width, height: height))
    }

    // 遠くのものほど小さく写す。
    public func perspective(_ fieldOfView: Float, _ aspect: Float, _ near: Float, _ far: Float) {
        apply(
            replacingProjection: .perspective(
                fieldOfView: fieldOfView, aspect: aspect, near: near, far: far))
    }

    // 平行投影を既定へ戻す。
    public func ortho() {
        apply(replacingProjection: Camera.defaultOrthographic(width: width, height: height))
    }

    // 距離によらず同じ大きさで写す。
    public func ortho(
        _ left: Float, _ right: Float, _ bottom: Float, _ top: Float, _ near: Float, _ far: Float
    ) {
        apply(
            replacingProjection: .orthographic(
                left: left, right: right, bottom: bottom, top: top, near: near, far: far))
    }

    // MARK: - 当てる

    /// 視点を当てる。**列をその場で閉じる**ので、既に置いた立体は置いた時点の視点で
    /// 描かれる ([ADR-0021] 決定 2 の「記録した列だけで絵が決まる」)。
    ///
    /// フレームの外 (初期化のとき) に書かれた視点は、どのフレームにも属さないので
    /// 警告して無視する (同 決定 4)。黙って捨てると「書いたのに効かない」だけが残る。
    private func apply(_ camera: Camera, name: String) {
        guard isDrawing else { return warnCameraOutsideFrame() }
        guard camera.isUsable else { return warnBadCamera(name) }
        closeBatch()
        cameraStorage = camera
    }

    /// 投影だけを差し替える。**視点の位置は動かさない** — どこから見るかと、どう写すかは
    /// 別の指定なので、片方を書いたときにもう片方が既定へ戻ると驚きになる。
    private func apply(replacingProjection projection: Camera.Projection) {
        guard isDrawing else { return warnCameraOutsideFrame() }
        guard Self.isUsable(projection) else { return warnBadProjection(projection) }
        var camera = currentCamera
        camera.projection = projection
        closeBatch()
        cameraStorage = camera
    }

    /// 投影として成り立つか。**範囲が潰れていると絵が丸ごと消える**ので、当てる前に見る。
    private static func isUsable(_ projection: Camera.Projection) -> Bool {
        switch projection {
        case let .perspective(fieldOfView, aspect, near, far):
            guard Camera.isDrawable(fieldOfView, aspect, near, far) else { return false }
            return fieldOfView > 0 && fieldOfView < .pi && aspect > 0 && near > 0 && far > near
        case let .orthographic(left, right, bottom, top, near, far):
            guard Camera.isDrawable(left, right, bottom, top, near, far) else { return false }
            return left != right && bottom != top && near != far
        }
    }

    /// フレームの外で視点を書いたことを、初回だけ知らせる。
    private func warnCameraOutsideFrame() {
        warnOnce(
            .cameraOutsideFrame,
            "視点と投影はフレームごとに置き直すものなので、描くところ (draw) で呼んでください。"
                + "初期化のときに書いた視点はどのフレームにも属さないため、無視しました")
    }

    /// 成り立たない視点を、初回だけ知らせる。描画は投げずに、いまの視点のまま続ける。
    private func warnBadCamera(_ name: String) {
        warnOnce(
            .badCamera,
            "\(name)(): 見る位置と見ている先が同じ・上方向が視線と重なる・数でない値の"
                + "いずれかなので、視点を変えませんでした")
    }

    /// 成り立たない投影を、初回だけ知らせる。
    private func warnBadProjection(_ projection: Camera.Projection) {
        let name: String
        switch projection {
        case .perspective: name = "perspective"
        case .orthographic: name = "ortho"
        }
        warnOnce(
            .badCamera,
            "\(name)(): 写す範囲が潰れている・数でない値が渡されたので、投影を変えませんでした")
    }
}
