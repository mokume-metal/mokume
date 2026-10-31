// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

// 道 (``Path``)。
extension SketchPart {
    /// 頂点を並べた形を、**道**として記録する。長さを測り、道の上の点を引き、内側かを問える。
    ///
    /// 閉包の中で ``beginShape(_:)`` から ``endShape(_:)`` まで並べた頂点 (``beginContour()``・
    /// ``bezierVertex(_:_:_:_:_:_:)``・``quadraticVertex(_:_:_:_:)``・``curveVertex(_:_:)`` を含む) が、道になる。
    /// 記録するのは**形だけ**で、色や線の太さなどの設定は道に入らない — 閉包の中で変えた ``fill(_:)-(LinearRGBA)`` などは、
    /// 抜けると元に戻る。描くのは ``shape(_:_:_:)-(Path,_,_)`` で、そのときの塗りと線に従う。
    ///
    /// 4 つの頂点を閉じた正方形は、1 辺ずつ辿った長さ 400 の道になる。`path.point(at: 0.25)` は弧長で 4 分の 1
    /// 進んだ角の点を返し、`path.contains([50, 50])` は内側かを答える。開いたままの形は、閉じる辺を長さに数えない。
    ///
    /// - 入口で変換は単位に戻り、中で書いた ``translate(_:_:)`` などは頂点に焼き込まれる (``createShape(_:)`` と同じ)。
    /// - 部分道が複数あるとき (``beginShape(_:)`` を何度か呼んだとき、``beginContour()`` で穴を置いたとき)、
    ///   全部を 1 つの形とみなし、回り数が 0 でない所を内側とする。
    /// - **基本図形 (``rect(_:_:_:_:)`` など)・字・画像・立体・画素・粒・効果の頼み・塗り直しは、道に入らず、描かれない。**
    ///   種類ごとに 1 度だけ知らせる。道には ``beginShape(_:)`` で並べた輪郭だけが入る。奥行きのある頂点も断る。
    ///
    /// 走っている実行の面を取れない所 (初期化子の中・後片付けの後など) で呼ぶと、落ちずに空の道を返し、1 度だけ
    /// 警告する。中身は呼ばれる。
    public func createPath(_ body: () -> Void) -> Path {
        guard let canvas = Self.liveCanvas(.make(returning: "an empty path")) else {
            body()
            return Path()
        }
        return canvas.createPath(body)
    }

    /// 道を描く。
    ///
    /// 塗りと線は、いまの ``fill(_:)-(LinearRGBA)`` と ``stroke(_:)-(LinearRGBA)`` に従う。道は見た目を持たない。
    /// (`x`, `y`) は道の原点の置き場所で、省けば原点 (0, 0) になる。いまの変換が効く。
    ///
    /// 部分道が 1 つなら、同じ ``beginShape(_:)`` をその場で描いたときと同じ絵になる。**複数なら、塗りは全部を 1 つの形
    /// として回り数で塗り、線は部分道ごとに 1 つの図形として引く** — 部分道どうしの線が重なる所は、2 回混ざることが
    /// ある。
    public func shape(_ path: Path, _ x: some ScalarConvertible = 0, _ y: some ScalarConvertible = 0) {
        guard let canvas = Self.liveCanvas() else { return }
        canvas.shape(path, x, y)
    }
}
