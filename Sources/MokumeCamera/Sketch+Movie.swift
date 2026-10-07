// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import MokumeCore

// 動画ファイル。**説明文の正本はこちら** ([ADR-0020] 決定 4)。
//
// 呼べば使える標準の機能である ([ADR-0042] 決定 1)。`plugins` には何も書かない —
// 作る口が、走っているスケッチへ自分で入り口を足す (``Sketch/attach(_:)-(Inlet)``)。
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
    ///     var settings = SketchSettings(width: 1280, height: 720)
    ///     var clip: Movie?
    ///     func setup() {
    ///         clip = try? createVideo("assets/clip.mov")
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
    /// - 絵の大きさは動画の大きさ。色は動画が名乗る色空間から作業空間へ移してある ([ADR-0011])
    /// - 音は鳴らさない。回転の印 (縦に撮った動画の向き) は当てず、記録された向きのまま映す
    ///
    /// 探す場所は ``loadImage(_:)`` と同じ (``assetURL(_:)``)。開くときに最初のコマまで読んで
    /// 確かめる。`setup()`・`draw()`・入力のコールバックの中で呼ぶ。
    ///
    /// - Parameter file: 動画ファイルの名前。macOS が再生できる形式 (QuickTime の `.mov`・
    ///   MPEG-4 の `.mp4` / `.m4v` で、H.264・HEVC・ProRes など)。
    /// - Throws: 見つからない・動画として読めない・映像が入っていない・絵として置けないとき。
    ///
    /// [ADR-0011]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0011-color-model.md
    /// [ADR-0028]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0028-external-inputs.md
    public func createVideo(_ file: String) throws(MovieFailure) -> Movie {
        let url: URL
        do {
            url = try assetURL(file)
        } catch {
            switch error {
            case .notFound(let path, let searched): throw .notFound(path: path, searched: searched)
            }
        }
        let reader = try MovieReader(url: url, path: file)
        let image: Image
        do {
            image = try createImage(reader.width, reader.height)
        } catch {
            throw .unplaceable(width: reader.width, height: reader.height)
        }
        let movie = Movie(image: image, reader: reader, name: "video: \(file)", owner: self)
        attach(movie)
        return movie
    }
}
