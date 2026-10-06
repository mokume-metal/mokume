#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""scripts/check-adrs.sh の検査 (#500 / #545 / #1946 / #2146)。

このスクリプトが守るのは 3 つ — **番号が重複したら赤い** (#490 と #491 が並走して
両方 0026 を取ったとき、別ファイルなので git も CI も止めなかった) ことと、
**改訂を抱えているのに状態欄が印を持たなければ赤い** (29 本中 27 本の状態欄が
`採用` のままで、節が情報を運んでいなかった) ことと、**本文の改訂の見出しが 5 つを
超えたら赤い** (改訂が重なった ADR は 1 本 2〜3 万字になり、読む重さが残った・#2140)
こと。どれも通す側へ倒れれば同じことがまた起きるので、赤くなる条件を先に固定する
(ADR-0002 決定 4 の「壊しても緑の検査は検査ではない」)。

状態欄の印は一字一句固定で 1 度だけ置き、改訂の正本は本文の日付入り見出しにある
(#1946)。状態欄に改訂を書き足す形では、同じ ADR を改訂する 2 本の PR が状態欄の
1 行で必ず衝突した。並んだ 2 本が衝突しないことは ParallelRevisionTest が固定する。

状態欄の側でとくに固定したいのは**誤検出しないこと**である。日付を持たない
「〜は改訂しない」という散文は改訂ではない (ADR-0006 決定 6 が実例)。ここを
拾ってしまう検査は、正しい ADR を赤くして書き手に嘘の宿題を出す。

一時ディレクトリを `git init` して位置引数で渡すので、認証もネットワークも要らない
(検査は ADR を `git ls-files` で集める・#2072)。
実行は make hooks-test (CI もこれを呼ぶ)。
"""

import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "check-adrs.sh"


def _git_init(path):
    # 検査は ADR を `git ls-files` で集める (追跡 + 未追跡 − 無視・#2072) ので、置き場を
    # git の作業ツリーにする
    subprocess.run(["git", "init", "-q", "."], cwd=path, check=True)
    # 使い捨てのリポジトリは手元の署名設定を継ぐ (#344)。ここは commit を
    # 打たないので効き目は無いが、抜けを人の記憶で守らないための規約に従う
    subprocess.run(["git", "config", "commit.gpgsign", "false"], cwd=path, check=True)


class AdrNumbersTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)
        self.addCleanup(self.tmp.cleanup)
        _git_init(self.dir)

    def place(self, *names):
        for name in names:
            (self.dir / name).write_text("# 見出し\n", encoding="utf-8")

    def run_script(self, *args):
        return subprocess.run(
            ["/bin/bash", str(SCRIPT), *(args or (str(self.dir),))],
            capture_output=True, text=True, encoding="utf-8"
        )

    def test_番号が重複していれば赤い(self):
        self.place("0026-plugin-repository-alignment.md", "0026-readable-surfaces.md")
        r = self.run_script()
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        # どの番号が・どのファイルで衝突したかを名指しする。名指しが無いと
        # 27 本の一覧から人が探すことになる
        self.assertIn("ADR-0026", r.stderr)
        self.assertIn("0026-plugin-repository-alignment.md", r.stderr)
        self.assertIn("0026-readable-surfaces.md", r.stderr)
        # 直し方まで出す — 見出しと参照の綴りも一緒に動くので、改番だけでは済まない
        self.assertIn("改番", r.stderr)

    def test_番号が一意なら緑(self):
        self.place("0026-plugin-repository-alignment.md", "0027-readable-surfaces.md")
        r = self.run_script()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("ok:", r.stdout)

    def test_番号を名乗らないファイルは数えない(self):
        # 番号を持たないファイルは ADR-00NN の綴りで参照されようがないので、
        # 同居していても検査の対象ではない (2 つ置いても重複扱いにしない)
        self.place("0026-plugin-repository-alignment.md", "README.md", "NOTES.md")
        r = self.run_script()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("1 本検査", r.stdout)

    def test_無視されたファイルは番号の重複に数えない(self):
        # CI の木に無いものは ADR-00NN の綴りの指し先になりようがない (#2072)
        self.place("0026-plugin-repository-alignment.md", "0026-local-draft.md")
        (self.dir / ".gitignore").write_text("*-local-draft.md\n", encoding="utf-8")
        r = self.run_script()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("1 本検査", r.stdout)

    def test_置き場が無ければ赤い(self):
        # 既定の置き場を打ち間違えたまま緑を返すと、検査が「何も見ていない」ことを
        # 緑で答えることになる
        r = self.run_script(str(self.dir / "not-there"))
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        self.assertIn("置き場が無い", r.stderr)

    def test_引数を省略するとリポジトリのADRを見る(self):
        # 既定の配線 (git root の docs/decisions) が生きていることを見る。
        # ここが切れると、テストだけが緑で ci-check は何も検査しない状態になる
        r = subprocess.run(
            ["/bin/bash", str(SCRIPT)], cwd=str(REPO),
            capture_output=True, text=True, encoding="utf-8"
        )
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("ok:", r.stdout)


MARKER = "改訂あり (本文の「改訂 (日付)」見出し)"


class AdrStatusTest(unittest.TestCase):
    """改訂を抱えた ADR の状態欄が印を持つか (#545 / #1946)。"""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)
        self.addCleanup(self.tmp.cleanup)
        _git_init(self.dir)

    def place(self, status, *body, name="0003-agent-identity-separation.md"):
        text = "# ADR-0003: 見出し\n\n## 状態\n\n" + status + "\n\n## 決定\n\n"
        text += "\n\n".join(body) + "\n"
        (self.dir / name).write_text(text, encoding="utf-8")

    def run_script(self):
        return subprocess.run(
            ["/bin/bash", str(SCRIPT), str(self.dir)],
            capture_output=True, text=True, encoding="utf-8"
        )

    # --- (a) 改訂を抱えているのに印が無い ---

    def test_決定見出しに併記した改訂があるのに印が無ければ赤い(self):
        self.place("採用 (2026-08-26)",
                   "### 4. `required_approving_review_count` は 0 のままにする (2026-08-28 改訂)")
        r = self.run_script()
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        # どの ADR の・どの見出しが印を求めたかを名指しし、足す綴りまで出す。
        # 綴りを書き手に思い出させると、並んだ 2 本が別々の綴りで足して衝突する
        self.assertIn("0003-agent-identity-separation.md", r.stderr)
        self.assertIn("2026-08-28", r.stderr)
        self.assertIn(MARKER, r.stderr)

    def test_追記節として立てた改訂があるのに印が無ければ赤い(self):
        self.place("採用 (2026-08-26)",
                   "#### 改訂 (2026-10-06) — CODEOWNERS を畳む")
        r = self.run_script()
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        self.assertIn("2026-10-06", r.stderr)

    def test_追補も同じに扱う(self):
        self.place("採用 (2026-08-27)", "## 追補 — 手段は自前の補間にする (2026-08-29)")
        r = self.run_script()
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        self.assertIn("2026-08-29", r.stderr)

    def test_凍結した改訂の並びがあるのに印が無ければ赤い(self):
        # ADR-0020 は改訂の見出しを持たないまま状態欄で「決定 7 を追加」と名乗って
        # いる。見出しが無くても、状態欄の並びが改訂を抱えている証拠になる
        self.place("採用 (2026-08-28) / 改訂 (2026-08-29): 決定 7 を追加", "### 7. 数の道具")
        r = self.run_script()
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        self.assertIn("印が無い", r.stderr)

    def test_印の綴りが違えば赤い(self):
        # 一字一句固定である。言い換えを通すと、並んだ 2 本が別々の綴りで足して
        # 状態欄が衝突する
        self.place("採用 (2026-08-26) / 改訂あり",
                   "#### 改訂 (2026-10-06) — CODEOWNERS を畳む")
        r = self.run_script()
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        self.assertIn("印が無い", r.stderr)

    def test_印があれば見出しの日付が状態欄に無くても緑(self):
        # 2 回目以降の改訂は状態欄に触れない。見出しの日付を状態欄に求めると、
        # 共有の 1 行に書き足す形へ戻る (#1946)
        self.place("採用 (2026-08-26) / 改訂 (2026-08-28): 決定 4 / " + MARKER,
                   "### 4. …… (2026-08-28 改訂)",
                   "#### 改訂 (2026-10-06) — CODEOWNERS を畳む",
                   "#### 改訂 (2026-10-07) — 決定 5 の報告先")
        r = self.run_script()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

    def test_改訂の無いADRは印が無くても緑(self):
        self.place("採用 (2026-08-26)", "### 1. 決定")
        r = self.run_script()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

    def test_日付を持たない改訂の話は拾わない(self):
        # ADR-0006 決定 6 「ADR-0003 決定 1 の権限表は改訂しない」。改訂について
        # 語っているだけで改訂していない。素朴な grep はここで誤検出する
        self.place("採用 (2026-08-27)",
                   "### 6. ADR-0003 決定 1 の権限表は改訂しない",
                   "引き上げは本 ADR の改訂として、そのとき判断する (2026-08-29 に何かした訳ではない)")
        r = self.run_script()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

    # --- (b) 切り替えの日より後の改訂を状態欄に書き足している ---

    def test_切り替えの後の改訂を状態欄に足せば赤い(self):
        self.place("採用 (2026-08-26) / " + MARKER + " / 改訂 (2026-10-06): 決定 4",
                   "#### 改訂 (2026-10-06) — 決定 4")
        r = self.run_script()
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        self.assertIn("2026-10-06", r.stderr)
        # 直し方 (見出しに書く) まで出す
        self.assertIn("#### 改訂 (2026-10-06)", r.stderr)

    def test_切り替えの日までの改訂の並びは凍結として緑(self):
        # 境界: 切り替えの日 (2026-10-05) そのものは咎めない。M1 で凍結した並びの
        # 最後の日付まで消さずに残す
        self.place("採用 (2026-08-26) / 改訂 (2026-08-28): 決定 4 / "
                   "改訂 (2026-10-05): 決定 5 / " + MARKER,
                   "### 4. …… (2026-08-28 改訂)")
        r = self.run_script()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

    def test_状態欄が実在しないADRを指していれば赤い(self):
        self.place("採用 (2026-08-26) / 一部置換 (→ ADR-0031): 決定 4", "### 4. 決定")
        r = self.run_script()
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        self.assertIn("ADR-0031", r.stderr)

    def test_状態欄が指す先が在れば緑(self):
        self.place("採用 (2026-08-26) / 一部置換 (→ ADR-0004): 決定 1", "### 1. 決定")
        (self.dir / "0004-issue-classification-by-issue-type.md").write_text(
            "# ADR-0004\n\n## 状態\n\n採用 (2026-08-26)\n", encoding="utf-8")
        r = self.run_script()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

    # --- 見る木: git add -A したときに CI の木になるもの (#2072) ---
    # 作業ツリーに在るだけでは足りない。無視されたファイルは CI の木に無い

    def test_状態欄が指す先が無視されたファイルだけなら赤い(self):
        self.place("採用 (2026-08-26) / 一部置換 (→ ADR-0031): 決定 4", "### 4. 決定")
        (self.dir / ".gitignore").write_text("0031-*.md\n", encoding="utf-8")
        (self.dir / "0031-local-draft.md").write_text(
            "# ADR-0031\n\n## 状態\n\n提案\n", encoding="utf-8")
        r = self.run_script()
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        self.assertIn("ADR-0031", r.stderr)

    def test_状態欄が指す先が未追跡でも無視されていなければ緑(self):
        # git add -A で CI の木に入る
        self.place("採用 (2026-08-26) / 一部置換 (→ ADR-0031): 決定 4", "### 4. 決定")
        (self.dir / "0031-new.md").write_text(
            "# ADR-0031\n\n## 状態\n\n採用 (2026-08-26)\n", encoding="utf-8")
        r = self.run_script()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

    def test_改訂を抱えるのに状態節が無ければ赤い(self):
        (self.dir / "0003-agent-identity-separation.md").write_text(
            "# ADR-0003\n\n## 決定\n\n#### 改訂 (2026-08-30) — 畳む\n", encoding="utf-8")
        r = self.run_script()
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        self.assertIn("状態欄が読めない", r.stderr)


class AdrRevisionCountTest(unittest.TestCase):
    """本文の改訂・追補の見出しが 5 つを超えたら赤い (#2140 / #2146)。

    数えるのは**見出しの数**で、(a) が改訂と読む行と同じ定義 (「改訂」か「追補」と日付を
    両方持つ `##`〜`####`。日付は前でも後ろでもよい) である。挙げられた日付の種類の数に
    すると、同じ日に 3 つの決定を改訂した ADR が 3 つに畳まれて、読む重さの代理として
    小さすぎる。経緯を移した `history/` は番号付きの ADR として数えられず、その中の
    見出しも数えない。
    """

    NAME = "0003-agent-identity-separation.md"
    STATUS = "採用 (2026-08-26) / " + MARKER

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)
        self.addCleanup(self.tmp.cleanup)
        _git_init(self.dir)

    def place(self, *body, status=STATUS, name=NAME):
        text = "# ADR-0003: 見出し\n\n## 状態\n\n" + status + "\n\n## 決定\n\n"
        text += "\n\n".join(body) + "\n"
        path = self.dir / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")

    def run_script(self):
        return subprocess.run(
            ["/bin/bash", str(SCRIPT), str(self.dir)],
            capture_output=True, text=True, encoding="utf-8"
        )

    @staticmethod
    def revisions(n):
        """n 個の改訂の見出し。2 通りの綴りと「追補」を混ぜ、日付はすべて違う。"""
        forms = [
            "### {i}. 決定 {i} の手段 (2026-08-{d:02d} 改訂)",
            "#### 改訂 (2026-08-{d:02d}) — 決定 {i} を差し替える",
            "## 追補 — 決定 {i} に足す (2026-08-{d:02d})",
        ]
        return [forms[i % 3].format(i=i + 1, d=i + 1) for i in range(n)]

    # --- 境界: 5 つは通り、6 つは赤い ---

    def test_5つなら緑(self):
        self.place(*self.revisions(5))
        r = self.run_script()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("ok:", r.stdout)

    def test_6つなら赤い(self):
        self.place(*self.revisions(6))
        r = self.run_script()
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        # どの ADR が・いくつで・なぜ止まったかを名指しする
        self.assertIn(self.NAME, r.stderr)
        self.assertIn("6 個", r.stderr)
        self.assertIn("5 個を超えている", r.stderr)

    def test_6つを超えても赤い(self):
        self.place(*self.revisions(9))
        r = self.run_script()
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        self.assertIn("9 個", r.stderr)

    def test_改訂が無ければ緑(self):
        # 軽くした後の本文は 0 に戻る
        self.place("### 1. 決定", "現行の決定。")
        r = self.run_script()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

    # --- 何を 1 つと数えるか: (a) が改訂と読む行と同じ定義 ---

    def test_日付が見出しの前にある形も数える(self):
        # `### 4. …… (2026-08-28 改訂)` は日付が「改訂」の前。日付が後ろの形だけを
        # 数える狭い定義だと、ADR-0032 は 16 個が 7 個になる (#2145)
        self.place(*[f"### {i}. 決定 {i} (2026-08-{i + 10} 改訂)" for i in range(1, 7)])
        r = self.run_script()
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        self.assertIn("6 個", r.stderr)

    def test_追補も数える(self):
        self.place(*[f"## 追補 — 決定 {i} に足す (2026-09-{i + 10})" for i in range(1, 7)])
        r = self.run_script()
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        self.assertIn("6 個", r.stderr)

    def test_同じ日の改訂も1つずつ数える(self):
        # 日付の種類の数ではなく見出しの数。ADR-0003 は 6 つの見出しが 3 つの日付に
        # 収まっている (2026-08-28 が 3 つ)
        self.place(*[f"#### 改訂 (2026-10-06) — 決定 {i} の手段" for i in range(1, 7)])
        r = self.run_script()
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        self.assertIn("6 個", r.stderr)

    def test_1つの見出しの日付が複数あっても1つと数える(self):
        # 上の対照: 数えるのは見出しなので、日付が見出しごとに 2 つあっても 5 つのまま
        self.place(*[f"#### 改訂 (2026-09-{i + 10}) — 2026-09-{i + 20} に直した" for i in range(1, 6)])
        r = self.run_script()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

    def test_副題だけの小見出しは数えない(self):
        # ADR-0021 は軽くした後も、日付も「改訂」「追補」も含まない副題だけの `####` を
        # 14 個残している (決定 4 が長く、平らにすると読めない)。数えるのは日付入りだけ
        subtitles = [f"#### 副題 {i} — 決定の中の区切り" for i in range(1, 15)]
        self.place("### 4. 決定", *subtitles, *self.revisions(5))
        r = self.run_script()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

    def test_日付を持たない改訂の見出しは数えない(self):
        # ADR-0006 決定 6 「…は改訂しない」と同じ。日付が「改訂した」と「改訂について
        # 語っている」を分ける
        self.place(*[f"### {i}. 決定 {i} は改訂しない" for i in range(1, 8)])
        r = self.run_script()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

    def test_見出しでない行と深すぎる見出しは数えない(self):
        # 見出しは `##`〜`####` の行だけ (本文の散文・箇条書き・`#####` は見出しではない)
        prose = [f"- 改訂 (2026-09-{i + 10}) で直した。" for i in range(1, 4)]
        deep = [f"##### 改訂 (2026-09-{i + 20}) — 深い見出し" for i in range(1, 4)]
        self.place(*prose, *deep, *self.revisions(5))
        r = self.run_script()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

    # --- 案内: ADR を開かずに行動できる ---

    def test_案内に軽くし方と経緯の置き場が出る(self):
        self.place(*self.revisions(6))
        r = self.run_script()
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        # 数えた見出しを挙げる (どれを移すか分かる)
        self.assertIn("2026-08-02", r.stderr)
        # 経緯の置き場は、番号つきで ADR の置き場の下の history/
        self.assertIn(f"{self.dir}/history/0003.md", r.stderr)
        # 軽くし方: 本文に残すもの・移すもの・番号を変えないこと・状態欄の印を残すこと
        for phrase in ("番号と決定の番号は変えず", "現行の決定", "退けた案", "当初の決定",
                       "置き換わった決定", "状態欄の印"):
            self.assertIn(phrase, r.stderr)
        # 全文の置き場と理由
        self.assertIn("docs/decisions/AGENTS.md", r.stderr)
        self.assertIn("改訂が重なった ADR を軽くする", r.stderr)
        self.assertIn("#2140", r.stderr)

    def test_上限と状態欄の印は別々に言う(self):
        # 6 つ超えて、しかも印が無い。どちらも直すので、片方で隠さない
        self.place(*self.revisions(6), status="採用 (2026-08-26)")
        r = self.run_script()
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        self.assertIn("6 個", r.stderr)
        self.assertIn("印が無い", r.stderr)

    def test_状態欄が読めなくても上限の超過を隠さない(self):
        (self.dir / self.NAME).write_text(
            "# ADR-0003\n\n## 決定\n\n" + "\n\n".join(self.revisions(6)) + "\n", encoding="utf-8")
        r = self.run_script()
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        self.assertIn("状態欄が読めない", r.stderr)
        self.assertIn("6 個", r.stderr)

    def test_複数のADRのうち超えたものだけを名指しする(self):
        self.place(*self.revisions(6))
        (self.dir / "0004-issue-classification-by-issue-type.md").write_text(
            "# ADR-0004\n\n## 状態\n\n採用 (2026-08-26) / " + MARKER + "\n\n## 決定\n\n"
            + "\n\n".join(self.revisions(5)) + "\n", encoding="utf-8")
        r = self.run_script()
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        self.assertIn(self.NAME, r.stderr)
        self.assertNotIn("0004-issue-classification", r.stderr)

    # --- 軽くした後の形: 経緯は history/ にあり、番号付きの ADR として数えない ---

    def test_経緯ファイルの見出しは数えずADRの本数にも入らない(self):
        # ADR-0021 を軽くした後の姿: 本文に日付入りの見出しが無く、状態欄は凍結した
        # 並びと印を持ち、経緯は history/0003.md にある (見出し 20 個)
        status = ("採用 (2026-08-26) / 改訂 (2026-08-28): 決定 4 / "
                  "改訂 (2026-09-14): 決定 1 / " + MARKER)
        self.place("### 4. 決定", "改訂の経緯は [history/0003.md](history/0003.md) にある。",
                   status=status)
        history = "# ADR-0003 の経緯\n\n" + "\n\n".join(self.revisions(20)) + "\n"
        (self.dir / "history").mkdir()
        (self.dir / "history" / "0003.md").write_text(history, encoding="utf-8")
        r = self.run_script()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("1 本検査", r.stdout)

    def test_経緯ファイルは番号が同じでも連番の重複に数えない(self):
        # `history/<番号>.md` は ADR の `NNNN-*.md` と同じ番号を名乗る。番号付きの名前
        # (`history/0003-….md`) で置かれても、直下ではないので数えない
        self.place("### 1. 決定")
        (self.dir / "history").mkdir()
        for name in ("0003.md", "0003-agent-identity-separation.md"):
            (self.dir / "history" / name).write_text(
                "# ADR-0003 の経緯\n\n" + "\n\n".join(self.revisions(6)) + "\n", encoding="utf-8")
        r = self.run_script()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertNotIn("重複", r.stderr)
        self.assertIn("1 本検査", r.stdout)


class ParallelRevisionTest(unittest.TestCase):
    """完了条件 3 (#1946): 同じ ADR を並んで改訂する 2 本が、状態欄で衝突しない。

    #1668 を閉じた #1856 の ParallelMergeTest と同じ形で、同じ base から切った 2 本の
    うち先の 1 本が main に入った後、後の 1 本を `git merge-tree --write-tree` で
    合わせる。merge queue が後の 1 本を外すかどうかは、この合流が衝突するかで決まる。
    """

    BASE = (
        "# ADR-0021: 見出し\n\n## 状態\n\n{status}\n\n## 文脈\n\n文脈。\n\n## 決定\n\n"
        "### 1. 一つ目\n\n本文 1。\n\n### 2. 二つ目\n\n本文 2。\n\n"
        "### 3. 三つ目\n\n本文 3。\n\n### 4. 四つ目\n\n本文 4。\n\n## 影響\n\n影響。\n"
    )
    NAME = "0021-solid-space-and-frame-assembly.md"

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.git("init", "-q", "-b", "main")
        # 使い捨てのリポジトリは手元の署名設定を継ぐ (#344)
        self.git("config", "commit.gpgsign", "false")
        self.git("config", "user.name", "test")
        self.git("config", "user.email", "test@example.invalid")

    def git(self, *args, check=True):
        r = subprocess.run(["git", "-C", str(self.root), *args],
                           capture_output=True, text=True, encoding="utf-8")
        if check and r.returncode != 0:
            raise AssertionError(f"git {' '.join(args)} が失敗した: {r.stdout}{r.stderr}")
        return r

    def commit(self, text, message):
        (self.root / self.NAME).write_text(text, encoding="utf-8")
        self.git("add", self.NAME)
        self.git("commit", "-q", "-m", message)
        return self.git("rev-parse", "HEAD").stdout.strip()

    def revise(self, text, decision, heading):
        """決定 N の本文の直後に改訂の見出しを立てる。"""
        anchor = f"本文 {decision}。\n"
        return text.replace(anchor, f"{anchor}\n{heading}\n\n差し替えた。\n")

    def merge_second_after_first(self, first_text, second_text, base_text):
        base = self.commit(base_text, "base")
        self.git("checkout", "-q", "-b", "first", base)
        first = self.commit(first_text, "first")
        self.git("checkout", "-q", "-b", "second", base)
        second = self.commit(second_text, "second")
        # 先の 1 本が main に入る (squash と同じく、main は first の木になる)
        self.git("checkout", "-q", "main")
        self.git("merge", "-q", "--ff-only", first)
        return self.git("merge-tree", "--write-tree", "main", second, check=False)

    def assert_merged_cleanly_and_green(self, merged):
        self.assertEqual(merged.returncode, 0, "衝突した:\n" + merged.stdout)
        tree = merged.stdout.splitlines()[0]
        text = self.git("show", f"{tree}:{self.NAME}").stdout
        # 2 本の改訂がどちらも残り、合流後の木を make adrs が通す
        self.assertIn("決定 2 の手段", text)
        self.assertIn("決定 4 の手段", text)
        self.assertEqual(text.count(MARKER), 1, text)
        check_dir = self.root / "check"
        check_dir.mkdir()
        subprocess.run(["git", "init", "-q", "."], cwd=check_dir, check=True)
        subprocess.run(["git", "config", "commit.gpgsign", "false"], cwd=check_dir, check=True)
        (check_dir / self.NAME).write_text(text, encoding="utf-8")
        r = subprocess.run(["/bin/bash", str(SCRIPT), str(check_dir)],
                           capture_output=True, text=True, encoding="utf-8")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

    def test_印のあるADRの別々の決定を改訂する2本は衝突しない(self):
        # 2 回目以降の改訂: どちらも状態欄に触れず、本文に見出しを立てるだけ
        base = self.BASE.format(status="採用 (2026-08-28) / " + MARKER)
        first = self.revise(base, 2, "#### 改訂 (2026-10-06) — 決定 2 の手段")
        second = self.revise(base, 4, "#### 改訂 (2026-10-06) — 決定 4 の手段")
        self.assert_merged_cleanly_and_green(self.merge_second_after_first(first, second, base))

    def test_初めての改訂が2本並んでも同じ印を足すので衝突しない(self):
        # どちらも状態欄の同じ行を、一字一句同じ文字に書き換える
        base = self.BASE.format(status="採用 (2026-08-28)")
        marked = base.replace("採用 (2026-08-28)\n", "採用 (2026-08-28) / " + MARKER + "\n")
        first = self.revise(marked, 2, "#### 改訂 (2026-10-06) — 決定 2 の手段")
        second = self.revise(marked, 4, "#### 改訂 (2026-10-06) — 決定 4 の手段")
        self.assert_merged_cleanly_and_green(self.merge_second_after_first(first, second, base))

    def test_状態欄に改訂を書き足す形は衝突する(self):
        # 対照: #1946 までの形。上の 2 本が緑なのは合流の手順が甘いからではなく、
        # 状態欄の書き方が違うからであることを、同じ手順で赤くなる側で確かめる
        base = self.BASE.format(status="採用 (2026-08-28)")
        first = self.revise(
            base.replace("採用 (2026-08-28)\n", "採用 (2026-08-28) / 改訂 (2026-10-02): 決定 2\n"),
            2, "#### 改訂 (2026-10-02) — 決定 2 の手段")
        second = self.revise(
            base.replace("採用 (2026-08-28)\n", "採用 (2026-08-28) / 改訂 (2026-10-02): 決定 4\n"),
            4, "#### 改訂 (2026-10-02) — 決定 4 の手段")
        merged = self.merge_second_after_first(first, second, base)
        self.assertEqual(merged.returncode, 1, merged.stdout)
        self.assertIn(self.NAME, merged.stdout)

if __name__ == "__main__":
    unittest.main()
