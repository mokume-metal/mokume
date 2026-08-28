// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// 線の端の形。
///
/// 太い線を引くと、端をどう仕上げるかが見えるようになる。太さ 1 の線では 3 つとも
/// ほとんど同じに見えるので、**確かめるときは太さを振る**。
public enum StrokeCap: Sendable, Equatable {
    /// 端を丸める (既定)。
    case round
    /// 与えた長さちょうどで切る。
    case square
    /// 与えた長さから、太さの半分だけはみ出させる。
    ///
    /// ``square`` と同じ四角い端だが、線が半分ぶん長くなる。目盛りのように
    /// 「線の端をぴったり合わせたい」ときに効く。
    case project
}

/// 線の折れ目の形。
///
/// 折れ線と、閉じた図形の輪郭の角に効く。
public enum StrokeJoin: Sendable, Equatable {
    /// 角を尖らせる (既定)。
    ///
    /// - Note: 鋭い角では尖りが極端に伸びるため、いまの実装は ``bevel`` と同じ形で
    ///   埋める。伸びの限界を持つ尖りは、輪郭の作り込みが進んでから足す。
    case miter
    /// 角を削ぐ。
    case bevel
    /// 角を丸める。
    case round
}
