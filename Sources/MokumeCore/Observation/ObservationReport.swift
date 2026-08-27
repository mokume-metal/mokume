// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

/// 観測の応答。
///
/// 形の正典は `Schemas/observe-report.schema.json`。**採取できなかったときも必ず書く**
/// ([ADR-0018] 決定 3) — 無応答は「相手が死んでいる」と区別が付かないためで、
/// そのときは ``image`` を省き、理由を ``warnings`` に載せる。
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

    /// 応答した要求の識別子。
    public let id: String
    /// 書き出した画像のファイル名。採取できなかったときは `nil`。
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
        stamp: String? = nil
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
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, image, frame, time, size, warnings, stats, load, values, stamp
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
    }
}
