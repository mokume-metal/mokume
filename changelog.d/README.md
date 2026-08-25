# changelog.d

ユーザー影響のある変更 1 件につき 1 ファイルを置く。リリース時に集約されて CHANGELOG.md へ昇格する (断片はその時点で削除)。

## 形式

ファイル名: `<slug>.<category>.md`

- `<slug>`: 変更を表す短い kebab-case (例: `add-noise-api`)
- `<category>`: `feature` / `fix` / `docs` / `perf` / `breaking`

中身は Markdown の 1 段落。リリースノートにそのまま載る文として書く (「何ができるようになったか / 何が直ったか」を利用者の言葉で)。

破壊的変更は `.breaking.md` とし、移行手順を必ず含める。

<!-- review-gate 実地検証のための一時変更 (この PR は merge しない) -->
