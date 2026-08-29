// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

/// 観測の応答。撮った絵の**目録**でもある。
///
/// 形の正典は `Schemas/observe-report.schema.json`。**採取できなかったときも必ず書く**
/// ([ADR-0018] 決定 3) — 無応答は「相手が死んでいる」と区別が付かないためで、
/// そのときは ``image`` を省き、理由を ``warnings`` に載せる。
///
/// ## 目録は枚数によらず在る
///
/// ``frames`` は 1 枚しか頼まなくても 1 要素の並びとして在る。読み手の完成の判定を
/// 1 本にするためで、[ADR-0018] 決定 3 のとおり「目録が在り、識別子が一致し、数が
/// 宣言と合う」だけを見ればよい。枚数で応答の形が変わると、読み手はまず形を見分ける
/// ところから始めることになる。
///
/// 上の階の ``image`` / ``frame`` / ``time`` / ``stats`` は**最後に撮った 1 枚**を指す。
/// 1 枚だけ頼んだときは目録の唯一の要素と同じものになる。
///
/// [ADR-0018]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0018-observation-and-control-surface.md
public struct ObservationReport: Encodable, Equatable, Sendable {
    /// この形式の版。上げ方は [ADR-0018] 決定 5。
    ///
    /// [ADR-0018]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0018-observation-and-control-surface.md
    public static let schemaVersion = 1

    /// 大きさ。
    public struct Size: Encodable, Equatable, Sendable {
        public let width: Int
        public let height: Int
    }

    /// 撮った 1 枚。目録の 1 行。
    ///
    /// **絵のほかに数字も持つ。** 動いたかどうかを判定するのに何十枚も画像を開かせては、
    /// 目録の意味が無い。``stats`` の差と ``values`` の差だけで「動いている / 止まって
    /// いる」を言えるようにしてある。
    public struct CapturedFrame: Encodable, Equatable, Sendable {
        /// 書き出した画像のファイル名 (応答からの相対)。
        public let image: String
        /// この絵を描いたフレームの番号。
        public let frame: Int
        /// この絵を描いたフレームの時刻 (秒)。
        public let time: Double
        /// 絵の要約。
        public let stats: FrameStats?
        /// このフレームでスケッチが差し出した値。1 つも無ければ `nil`。
        public let values: [String: ExposedValue]?

        private enum CodingKeys: String, CodingKey {
            case image, frame, time, stats, values
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(image, forKey: .image)
            try container.encode(frame, forKey: .frame)
            try container.encode(time, forKey: .time)
            try container.encodeIfPresent(stats, forKey: .stats)
            try container.encodeIfPresent(values, forKey: .values)
        }
    }

    /// 応答した要求の識別子。
    public let id: String
    /// 最後に撮った絵のファイル名。1 枚も採れなかったときは `nil`。
    public let image: String?
    /// この絵を描いたフレームの番号。
    public let frame: Int
    /// この絵を描いたフレームの時刻 (秒)。
    public let time: Double
    /// 描いた面の大きさ。
    public let size: Size
    /// 採取の過程で起きたことわり。
    public let warnings: [String]
    /// 絵の要約。画像を開かずに「真っ黒か」「隅に寄っていないか」を判定するため。
    public let stats: FrameStats?
    /// 走らせている重さ。速い遅いを絵からの推測ではなく数値で答えるため。
    public let load: RuntimeLoad?
    /// スケッチがこのフレームで差し出した値。
    public let values: [String: ExposedValue]?
    /// この絵を生んだ入力の世代。読み手は等値比較だけを行う。
    public let stamp: String?
    /// 撮った絵の目録。撮った順に並ぶ。**枚数によらず在る**。
    public let frames: [CapturedFrame]

    init(
        id: String,
        image: String?,
        frame: Int,
        time: Double,
        size: Size,
        warnings: [String] = [],
        stats: FrameStats? = nil,
        load: RuntimeLoad? = nil,
        values: [String: ExposedValue]? = nil,
        stamp: String? = nil,
        frames: [CapturedFrame] = []
    ) {
        self.id = id
        self.image = image
        self.frame = frame
        self.time = time
        self.size = size
        self.warnings = warnings
        self.stats = stats
        self.load = load
        self.values = values
        self.stamp = stamp
        self.frames = frames
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, image, frame, time, size, warnings, stats, load, values, stamp
        case frames
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.schemaVersion, forKey: .schemaVersion)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(image, forKey: .image)
        try container.encode(frame, forKey: .frame)
        try container.encode(time, forKey: .time)
        try container.encode(size, forKey: .size)
        try container.encode(warnings, forKey: .warnings)
        try container.encodeIfPresent(stats, forKey: .stats)
        try container.encodeIfPresent(load, forKey: .load)
        try container.encodeIfPresent(values, forKey: .values)
        try container.encodeIfPresent(stamp, forKey: .stamp)
        try container.encode(frames, forKey: .frames)
    }
}
