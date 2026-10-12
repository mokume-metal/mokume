# G3 再検証の要点 (58eea05c、行番号変化なし)。下書き: scratchpad/g3draft/G3Geometry.swift、Python 写し scratchpad/g3sim/tri.py
## #2370
- 確認: Triangulation 271, 275-286, 393, 410, 269, 182-188 (周の写し直しも O(H·R))
- 指数: 本文の時間から 100→400 で 2.08、400→900 で 2.06 = ほぼ2乗。Python の写しで跨ぐ検査の回数 穴25/100/400 で 8.0千/20.3万/565万 (指数 2.3〜2.4)。穴1つあたりの最良の更新 3.3→5.6→10.6
- 見落とし: (1) Canvas の経路は mergeHoles の前に必ず splitForNonzero (Canvas+Vertices 640-648)、holesAreOutOfPlace (Crossings 183-219) にも O(H²) の箱比較 (:210) (2) 費用の数え口 pointScansThisFrame は merged.count だけ (Canvas+Vertices:649) → #915/#1595 の「二乗に戻っていないことを数で確かめる」仕組みに mergeHoles が映らない (3) 光線案だけでは合計 O(H·(N+6H)) でまだ2乗。上乗せ分は消え 10〜60 倍の見込み。2乗を割るには辺の索引を畳むたびに更新 (4) EdgeBoxes は RingEdges 内の fileprivate (Crossings:919)
- 穴25で三角形が少ない件: 入力の向きの問題 (穴が外周と同じ向き)。逆向きなら 152 枚 = V+2H−2、同じ向きなら 122 枚で穴が埋まる。Canvas の経路では同じ向きの穴は holesAreOutOfPlace が分岐へ回す (:208) ので mergeHoles に直に届かない。ただし前提が mergeHoles の説明 (Triangulation 127-156) に書かれていない (Region の説明 Crossings 26-27 だけ) → 説明か assert の候補 (別件の小ネタ)
- 原因: 跨ぎの検査は #1570 (#1530 修正、c89100c6) で正しさのため。その後 #1538/#1886。費用は #1595 の範囲外 = 見落とし
- 影響: beginContour の穴の多い形、SVG の複数副経路 (Canvas+SVG 72-80) で本当に内側の穴、fillSplit (Canvas+Vertices:743)。作例は該当なし (ShapesAndStyle:97、CrowdAndModel:148 は穴1つ)
## #2376
- 確認: ThinStroke 402-406, 476。訂正: 入ったのは 37156ed3 (#1944、#1686 の修正、10-03)、#2069/#2182 ではない
- Outline:108 neighbor.map は 3d1730e8 (#1896)。開いた周1本につき2回
- strokeNet 238/243/246/254 (1369d7e5 #2168)。1点だけの群では heap 確保は2つ。検査は filter・allSatisfy・first で3回
- 3か所とも PR #1799 (#1779 の修正、09-28) の後に入った → 本文の主張は正しい
- 範囲外の同形: Canvas+Vertices:179 (curveVertex ごと)、:1112 (bezier/quadraticVertex ごと) の .last.map {} (cfbc499f、09-25) = #1799 の拾い漏れ
- 見積もり: 2D .lines 1万本 約0.8ms、3D .lines 1万本 (strokeNet) 約3ms、細い線の角1万 約2ms (同じ線の StrokeCarving が一桁重い、#1948 21.6ms)
- 再発防止の仕組みなし (#1799 は検査を足していない、grep 0、ADR-0010 決定3「機械検査は付けない」)。推奨: native = 本体を nonisolated static の補助関数へ (Triangulation・StrokeCarving が前例)。型の注釈なので新しいゲートの手順は不要。代替: release の目的ファイルで swift_task_isCurrentExecutor の箇所を数える (ノイズ多)、字面の lint (非推奨)
## #2377
- 確認: TransferFunction 42-47、ColorPrimaries 22-26/59-65、OutputStage 123-125 (使っているのは画像 decode と ImageInputPass:43)
- 逆向き red() は入力が連続 → 表は使えない
- 効くのは入力が整数のときだけ。作例の画素ループは .display(連続値) (TexturedSurfaces:22, SurfacesAndBlend:147, TypeAndImagery:64, CrowdAndModel:73)、color(map(noise…)) も整数でない → 当たる場面は狭い
- 反証: 完了条件1「行列は定数の float」は条件2 (ビット一致) と矛盾。ColorPrimaries 15-16 は往復で0成分が揺れないよう Double を意図。行列は Double の行ごとの内積順のまま定数へ移すべき (simd_double3x3 * v は列ごとで足す順が変わる)
- 境界: 負の0 は decode で -0、表では +0 → 符号を見る
- 原因: 表は出口の画像のため (#753 頃)、入口は場面を想定していなかった
## #2389
- 確認: Package.swift:139、NumberSurface:41、ColorSurface:127。radians/degrees は記録すら持たない。WarningLog (:25)・Diagnostics は nonisolated
- 訂正: noise は Canvas/Sketch のメソッドで NoiseStore (参照型、Canvas 724-740、GPU へも渡す #1855/#1503) の種を読む → B だけでは並列から呼べず C 必須。ValueNoise (Random/ValueNoise:39) は Sendable の純 struct なので C の費用は小
- LinearRGBA のプロパティ: SE-0434 で同モジュールの Sendable 格納プロパティは nonisolated 扱い。利用者モジュールからは要確認。LinearRGBA の init は隔離 → B では LinearRGBA も
- 見落とし: #2255 と干渉 (ScalarConvertible の適合 ScalarConvertible 43-51 が main actor 適合)。内部並列化は ADR-0010 決定4 で DispatchQueue 不可 → TaskGroup。利用者の concurrentPerform は @Sendable (SDK で確認) → ADR-0001 原則1 で「明示的に選ぶ人向けの道」。SE-0423 の罠 (main actor 閉包を Dispatch に渡すと実行時検査で落ちる)
## #2369
- 確認: Canvas+Pixels 53-56、RenderTarget 260-271、settle() (RenderDevice 1028-1042): settleCalls 加算・signaledValue 2回 (ObjC)・releaseFinished の lastIndex(where:)、RenderDevice は @MainActor (:78) で列が空でなければ要素ごとに隔離検査
- Pixels 90-94、Canvas+Pixels 96-112 確認。作例 Sketch+Pixels:108 (22-23, 50)、Sketches/PixelsAndPaint 71-72
- 補足: subscript set は nonmutating → pixels[x,y]=pixels[x,y] は getter 2回+許可の閉包1回。get()/set() (64-77) も呼ぶたびに settle。窓を1度だけ取る書き方 (let window = pixels) は今の API で書けて文書も許すが例は案内していない
- 原因: 待ちと許可を1か所に集める設計 (Canvas+Pixels 9-11)、#1672 の許可、#727 の待たない描画の重なり。正しさのための判断で1画素の費用は範囲外。#2206 とは独立に直せる
## #2209/#1948 追加
- 2乗の輪 StrokeCarving 408-410 確認。意図した代償: b9d275a5 (#1848、#1562 の判断)、注記 21-23「周の点は高々1025個、箱で絞れば足りる」
- 当たる場面は狭い: 基本図形 (strokesAsOneRegion、Canvas+Primitives 38/144、Canvas+Folding:450) で距離関数の経路が使えないとき (shader() か絵の塗り Canvas+Form 43-45、または畳みの雛形を作る間)。点の数は segmentCount: 半径20で約20点、350で84点、5000で約315点、1024点は半径約5.3万px
- 1個あたり take 約2n²、84点で約1.4万回。shader() 下で大きさのばらつく円1000個は雛形を毎回作り直し積み重なる
- 折れ線 (beginShape) は2乗の輪を通らない: 弧長の窓 (412-433) で線形。費用の中心は引き算 (#1948 21.6ms)
- → 前回の私のレビューの「1万点で 34 ms」は折れ線の引き算の費用で、2乗の輪のせいではない (訂正)
- #2209 完了条件7: 型板が半透明を引き受けると StrokeCarving に残るのは細い線 (#1637・#1948) と条件6の範囲。6で細い線も型板なら外せて2乗と #1948 が同時に消える。残すなら #1948 は残るが2乗の輪は狭い場面のみ → 単独の優先度は低。条件5の基準値として今の数字を取っておく
