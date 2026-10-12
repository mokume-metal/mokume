# G5 再検証の要点 (58eea05c、行番号変化なし)
## #2383
- 確認(条件付き): readAvailable 4KB 確保 StandardInputEvents:116。2回目は watch の子 (relayed != nil, SketchApplication:483) のみ。pollStopSignal(:799→:862→SketchRuntime:793→takeDeparture 106-107) と collectInput(689/733→770→drain:80)。pause(:602)/録り閉じ(:595) では1回
- O(n²) 確認 136-141。ただし管は 64KB で詰まり書く側は溢れを捨てる (WatchSession 373-391)。1行≈40B → 最大約1500行/刻み。マウスは合体されふだん数行
- 訂正: 溜まるのは closingRecorder と外からの pause() の間で takeDeparture だけが読み pendingLimit 1MB (約25,000行) まで。pause() は Sources から呼ばれない公開口。ExternalQueue を使うのは OSCPort と TextPort のみ
- decoder 毎行: :146 確認
- drain: ExternalQueue 195-202 確認 + 補足: 連結・map・removeAll は全部 waiting.withLock の中 (:118) → 送り手 (Network の糸) を塞ぐ時間
- 追加の兄弟: InputState.enqueue (InputState 78-84) は上限4096超で pending.removeFirst() O(n)
- 原因: #716 (2c443e8a) で「素朴に始める (ADR-0008)」。2回読みは #1430 (e44b7306)。ExternalQueue は #1962 (65920cd1) で ADR-0010 決定5 改訂と同日。drain の形は実装の細部 → 容量保持は決定に触れない。測っていないだけ
- 影響: 管は watch の子のみ。受け口は createOSC/TextPort、作例 Sketches/OSCAndReply, NetAndReply
## #2382
- 確認: ParamSurface 204-213/267-284、collectInput (SketchRuntime:772) で draw 前 main。区画ありのみ (ParamSurface 155-162, SketchRuntime 382, WatchCommand 321)
- 拡大: ParamBox 34-38 (_modify 39-44) → 値が同じ再代入でも毎フレーム公開
- DeclarationWatcher 69-101 で張り直しのたび registry.declarations を組む (ParamRegistry:41)、1フレーム計3回
- AtomicFile 162-166 (encoder 毎回)、83-99 (createDirectory→write→replaceItemAt)
- 訂正: 道具は WatchedFile 49-57 で更新時刻が動けば読み直し decoder 毎回。駆動は道具の display link (SharedFrameStage 308-309→SharedFramePreview 145-147)。描き直しは値が変わった箱だけ (RemoteParams 159-162, 72-76)
- ParamStore 39/160-169 は 30 フレーム静まってから (ADR-0030 決定6)
- 原因: #578 (79b478e5) からの設計。ADR-0030 決定2「値が変わるたびに改訂番号が進む」。間引くのは決定6 (保存) の側だけ。#1704/#1835 (5a2f6391) は頻度を変えていない → 間引きは改訂番号の意味を変える = メンテナ判断が要る
- 影響: watch 下で draw 中に @Param を書く作品のみ。作例・文書の該当 0 (KnobsAndValues は draw で書かない)
## #2378
- frameTimeMs: SketchRuntime:1097、FrameTempo 41-49/60-63 (平均と最大)、schema observe-report 84-86。#1554 は measure(_:_:) (SketchRuntime:1345) を入れて閉じた → 作者の区間の CPU 壁時計は測れる
- feedback: RenderDevice 434-466 用途は解放 (#1594) と打ち切り記録 (#1932) のみ
- SDK: Xcode 27.0 / SDK 27.0 の MTL4CommitFeedback.h:36-40 に GPUStartTime/GPUEndTime (CFTimeInterval, macos 26.0)。typecheck 通過。#2038 (f3e9a830)・#2187 (f62e742e) で一時の仕掛けとして使いコミットせず (ADR-0039 :185, :247)
- signpost: grep 0、git log -S 0
- probe: measure-frame-rate.sh 38,67,118 debug。ただし probe の目的は ADR-0012 決定5 の確認で絵も rect 24 本と軽い → release にしても退行検出にならない
- 性能検査: ShapeTests 205-249 のみ。hosted ランナーに Metal 4 GPU 無し、merge_group の test-release でも skip (ci.yml 127-131)。走るのは専用機 test-release-scheduled (Makefile 361-363) と手動のみ
- 計数: Canvas 3500/3509/3517 更新 3782-3784。drawCallsInLastFrame は列の数、実際の描画呼び出しは drawsEncodedInLastFrame。パスの描画のみ (効果・拡大・compute 含まず)、flush ごと上書き、internal
- #1744 条件2 との差: 中央値/p95 の集計器なし、GPU 時間の口なし、copy/割当は Instruments、draw 数は internal、最大メモリは task_vm_info.ledger_phys_footprint_peak で読める
- 制約: 専用機1台、#2303 (未決)、#1711 hosted 同時5本 → 定期比較は scheduled-release に短い1本として
- 原因: ADR-0008 (先回りで作らない)。手で組んだ回数自体が実害の記録
- 所見: コミットの口は Sources に 10 か所、1 フレーム複数コミット → フレームの GPU 時間の定義を先に決める。値は 1〜2 フレーム遅れ。GPU 時間は Metal System Trace で見えるので signpost の価値は CPU 区間
