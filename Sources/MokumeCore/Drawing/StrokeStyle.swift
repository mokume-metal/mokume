// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// 線の端の形。
///
/// 太い線を引くと、端をどう仕上げるかが見えるようになる。太さ 1 の線では 3 つとも
/// ほとんど同じに見えるので、**確かめるときは太さを振る**。
public nonisolated enum StrokeCap: Sendable, Equatable {
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
public nonisolated enum StrokeJoin: Sendable, Equatable {
    /// 角を尖らせる (既定)。
    ///
    /// - Note: 矩形の角 (直角) では尖りが線幅の半分だけ伸びる。任意多角形
    ///   (``Sketch/beginShape(_:)``) の折れ目は鋭い角で尖りが極端に伸びるため、いまの
    ///   実装は ``bevel`` と同じ形で埋める。伸びの限界を持つ尖りは、輪郭の作り込みが
    ///   進んでから足す。扇形の角は折れ目の形によらず丸く出る。
    case miter
    /// 角を削ぐ。
    ///
    /// 矩形の角は 45° で削がれる。任意多角形の折れ目は、いまの実装では正方形で埋める
    /// (``miter`` の注記)。
    case bevel
    /// 角を丸める。
    case round
}
