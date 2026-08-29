// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Metal

/// 出口が受け取る、フレーム 1 枚。
///
/// 中身は**出力段を通した後の絵**である ([ADR-0024] 決定 6) — 標準レンジへ収め、
/// ディスプレイのエンコードを掛け、チャンネルあたり 8 bit へ量子化し、アルファは
/// 乗算を戻した状態。組み込みの出口も外から足した出口も同じものを受け取るので、
/// 「画面ではこう見えるのに書き出すと違う」が起こらない ([ADR-0023] 決定 2)。
///
/// ## 受け取り方は 2 通りある
///
/// - ``texture`` — GPU の上のまま受け取る。**毎フレーム渡す出口はこちら**で、
///   読み戻しを 1 バイトも払わない
/// - ``bytes()`` — バイト列として受け取る。読み戻しを払うが、CPU から中身を見られる
///
/// ## 中身はフレームごとに書き換わる
///
/// テクスチャは**使い回している 1 枚**なので ([ADR-0023] 決定 5)、``receive(_:)``
/// から返った後は次のフレームの絵になっている。持ち帰って後で読むなら
/// ``bytes()`` で値にしてから渡す。
///
/// [ADR-0023]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0023-frame-stages-and-outputs.md
/// [ADR-0024]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0024-extension-seams.md
public struct OutputFrame {
    /// 幅 (画素)。
    public let width: Int
    /// 高さ (画素)。
    public let height: Int
    /// 何枚目か。
    public let frame: Int
    /// このフレームの時刻 (秒)。
    public let time: Double

    private let image: EncodedImage

    init(image: EncodedImage, frame: Int, time: Double) {
        self.width = image.width
        self.height = image.height
        self.frame = frame
        self.time = time
        self.image = image
    }

    /// 出力段を通した絵。GPU の上にあるまま渡す。
    ///
    /// **`MTLTexture` を面に出す唯一の点である** ([ADR-0024] 決定 8)。理由は
    /// [ADR-0020] 決定 6 の作法で書く — 毎フレーム絵を渡す出口は、他のアプリや
    /// 機材へ**その資源をそのまま手渡す**ことが仕事なので、置き換えられる自前の型が
    /// 無い。包んで隠すと、受け取った側が中身を取り出す口を別に求めることになり、
    /// 露出の点が 1 つ増えるだけになる。
    ///
    /// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
    /// [ADR-0024]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0024-extension-seams.md
    public var texture: any MTLTexture { image.texture }

    /// バイト列として読み戻す。
    ///
    /// **画素ごとの計算は 1 つも無い** (出力段は既に通っている) が、行の詰め直しの
    /// ぶんは払う。毎フレーム渡す出口は ``texture`` を使う。
    public func bytes() -> DisplayImage { image.read() }
}
