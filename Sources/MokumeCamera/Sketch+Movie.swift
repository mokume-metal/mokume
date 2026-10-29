// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import MokumeCore

// 動画ファイル。**説明文の正本はこちら** ([ADR-0020] 決定 4)。
//
// 呼べば使える標準の機能である ([ADR-0042] 決定 1)。`plugins` には何も書かない —
// 作る口が、走っているスケッチへ自分で入り口を足す (``SketchPart/attach(_:)-(Inlet)``)。
//
// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
// [ADR-0042]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0042-camera-and-audio-standard.md
extension Sketch {

    /// 動画ファイルを開く。いま映っているコマは ``Movie/image`` に入る。
    ///
    /// 手元の動画を流しながら、その上にマウスで動く円を重ねる:
    ///
    /// ```swift
    /// final class Overlay: Sketch {
    ///     var settings: SketchSettings { SketchSettings(width: 1280, height: 720) }
    ///     var clip: Movie?
    ///     func setup() throws {
    ///         clip = try createVideo("assets/clip.mov")
    ///         clip?.loop()
    ///     }
    ///     func draw() {
    ///         if let clip { image(clip.image, 0, 0, width, height) }
    ///         circle(mouseX, mouseY, 80)
    ///     }
    /// }
    /// ```
    ///
    /// - **作っただけでは流れない。** 最初のコマが映ったまま止まっている。``Movie/loop()`` か
    ///   ``Movie/play()`` で流す
    /// - **どのコマが映るかはスケッチの時刻で決まる。** 固定の時計で書き出す (`mokume render`) と、
    ///   何度書き出しても同じフレーム番号に同じコマが出る ([ADR-0028] 決定 7)
    /// - 絵の大きさは動画の大きさ (回転の印を当てた後の、見えている向きの大きさ)。色は動画が名乗る色空間から作業空間へ移してある ([ADR-0011])
    /// - 透過の動画 (ProRes 4444・アルファ付き HEVC) は、透明・半透明のまま映る。背景を描いてから
    ///   重ねれば、動画の透明な所で背景が見える
    /// - 縦に撮った動画など、回転の印 (`preferredTransform`) を持つ動画は、その向きを当てて正しい向きで映す
    ///   (90° 刻みの回転と反転。それ以外の変換は当てない)。``Movie/width``・``Movie/height``・``Movie/image`` の
    ///   大きさも当てた後の値
    /// - 流す速さは ``Movie/speed(_:)`` で変えられる。音は鳴らさない
    ///
    /// 探す場所は ``SketchPart/loadImage(_:)`` と同じ (``SketchPart/assetURL(_:)``)。開くときに最初のコマまで読んで
    /// 確かめる。`setup()`・`draw()`・入力のコールバックの中で呼ぶ。
    ///
    /// - Parameter file: 動画ファイルの名前。macOS が再生できる形式 (QuickTime の `.mov`・
    ///   MPEG-4 の `.mp4` / `.m4v` で、H.264・HEVC・ProRes など)。
    /// - Throws: 見つからない・見つかったが開けない (ディレクトリだった・読む権利が無い。解けた場所が載る
    ///   ``MovieFailure/unopenable(path:location:reason:)``)・動画として読めない・映像が入っていない・
    ///   絵として置けないとき
    ///   (``MovieFailure``)。`setup()`・`draw()`・入力のコールバックの外 (初期化子の中・後片付けの後・
    ///   `Task` の中) で呼ぶと、ファイルを開く前に ``MovieFailure/notRunning(call:)`` (プロセスは落ちない)。
    ///
    /// [ADR-0011]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0011-color-model.md
    /// [ADR-0028]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0028-external-inputs.md
    public func createVideo(_ file: String) throws(MovieFailure) -> Movie {
        let call = #function
        // 映す絵を作る面を取れなければ、`attachedOnSurface` がファイルを開く (最初のコマまで読む) 前に断る
        return try attachedOnSurface(MovieFailure.self, calledAs: call) { () throws(MovieFailure) -> Movie in
            let url: URL
            do throws(AssetFailure) {
                url = try assetURL(file)
            } catch {
                switch error {
                case .notFound(let path, let searched): throw MovieFailure.notFound(path: path, searched: searched)
                case .unreachable(let path, let location, let reason):
                    throw MovieFailure.unopenable(
                        path: path, location: location, reason: AssetOpening.unreachableReason(reason))
                }
            }
            let reader = try MovieReader(url: url, path: file)
            let image: Image
            do throws(ImageFailure) {
                image = try createImage(reader.width, reader.height, calledAs: call)
            } catch {
                // **大きさの失敗だけを言い換える。** 面を取れないことまで大きさの話にすると、利用者は
                // 置ける大きさを探しに行く (#2683 の反証 1)
                switch error {
                case .notRunning(let named): throw MovieFailure.notRunning(call: named)
                case .notFound, .unopenable, .undecodable, .unplaceable, .unwritable:
                    throw MovieFailure.unplaceable(width: reader.width, height: reader.height)
                }
            }
            return Movie(image: image, reader: reader, name: "video: \(file)", owner: self)
        }
    }
}
