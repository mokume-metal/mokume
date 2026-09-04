#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 mokume-metal
# SPDX-License-Identifier: MIT
"""scripts/repo-slug.sh の検査 (#818)。

「どのリポジトリか」を解く実装が 2 つあり、**片方が他方の劣化版**だった。
`render-status.sh` の `resolve_repo()` は `git@github.com:` と `https://github.com/` の
2 形しか落とさないので、次を解けなかった:

    ssh://git@github.com/owner/repo.git   → ssh://git@github.com/owner/repo
    git@github-work:owner/repo.git        → git@github-work:owner/repo

**害は「手元の実行の報告が黙って届かない」だった。** 劣化版は空を返さないので
「origin が無い」の逃がしに掛からず、続く `gh api repos/<ごみ>/…` が失敗して
`local-render` が付かない。描画 PR はそれが無いと merge できない。

だから固定するのは 3 つ:

1. **解ける形** — 上の 2 つを含む 4 形すべて (劣化版が誤答した 2 つが要点)
2. **解けない形** — 誤った宛先を「解けた」として返さない
3. **実装が 1 つであること** — `scripts/*.sh` で origin を自前で剥がしていないこと、
   リポジトリ名の literal が外に無いこと

実行は make hooks-test (CI もこれを呼ぶ)。
"""

import os
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRIPTS = REPO / "scripts"
LIB = SCRIPTS / "repo-slug.sh"

# 空の既定を意図して持つ場所。**空を pr_files へ渡して gh の {owner}/{repo}
# プレースホルダへ倒す設計**なので (#793)、literal を持たないことが正しい
EMPTY_BY_DESIGN = "check-drawing-evidence.sh"


def run(script, **env):
    child = {k: v for k, v in os.environ.items() if k != "GITHUB_REPOSITORY"}
    child.update(env)
    return subprocess.run(
        ["/bin/bash", "-c", f'. "{LIB}"\n{script}'],
        capture_output=True,
        text=True,
        env=child,
    )


class ThisRepoTest(unittest.TestCase):
    def test_the_environment_wins(self):
        proc = run('this_repo', GITHUB_REPOSITORY="other/name")
        self.assertEqual(proc.stdout, "other/name")

    def test_the_fallback_is_this_repository(self):
        """既定が効くのは手元だけ (CI は GITHUB_REPOSITORY を立てる)。"""
        proc = run('this_repo')
        self.assertEqual(proc.stdout, "mokume-metal/mokume")


class RepoOfDirTest(unittest.TestCase):
    """**実物の git リポジトリ相手に解かせる。** 文字列だけの検査では
    `git remote get-url` の振る舞い (alias の展開・insteadOf) を取り違える。"""

    def resolve(self, origin=None):
        with tempfile.TemporaryDirectory() as tmp:
            # **署名は切る** (#344)。ここは commit しないが、一時リポジトリを作る
            # ファイルには一律で要求される — 取りこぼして「ときどき赤い」に戻るほうが
            # 高くつく、という判断 (temp_repo_signing_test.py の冒頭)
            subprocess.run(
                ["git", "-c", "commit.gpgsign=false", "init", "-q", str(Path(tmp) / "r")],
                check=True,
            )
            root = Path(tmp) / "r"
            if origin is not None:
                subprocess.run(
                    ["git", "remote", "add", "origin", origin], cwd=root, check=True
                )
            proc = run(f'repo_of_dir "{root}"')
            return proc.returncode, proc.stdout.strip()

    def test_the_forms_that_resolve(self):
        for origin, expected in (
            # 劣化版でも解けた 2 形
            ("git@github.com:mokume-metal/mokume.git", "mokume-metal/mokume"),
            ("https://github.com/mokume-metal/mokume.git", "mokume-metal/mokume"),
            # **劣化版が誤答した 2 形** — ここが #818 の主眼
            ("ssh://git@github.com/mokume-metal/mokume.git", "mokume-metal/mokume"),
            ("git@github-work:mokume-metal/mokume.git", "mokume-metal/mokume"),
            # 末尾の .git を省いた形・スラッシュ付き
            ("https://github.com/mokume-metal/mokume", "mokume-metal/mokume"),
            ("https://github.com/mokume-metal/mokume/", "mokume-metal/mokume"),
        ):
            with self.subTest(origin=origin):
                status, slug = self.resolve(origin)
                self.assertEqual(status, 0, f"解けなかった ({origin})")
                self.assertEqual(slug, expected)

    def test_a_bare_alias_is_not_resolved(self):
        """**誤った宛先を「解けた」として返さない** (#818 で見つけた穴)。

        `user@` を伴わない `alias:owner/repo` は sed が落とせず、残った
        `alias:owner/repo` が `*/*` に当たって通ってしまっていた。
        """
        status, slug = self.resolve("gh:mokume-metal/mokume.git")
        self.assertNotEqual(status, 0, f"解けたことになっている ({slug})")

    def test_a_local_path_is_not_a_slug(self):
        """origin が手元の bare のときは「解けなかった」に倒す。

        **gh の宛先を訊いているのではない** — そちらは `gh repo view` の仕事で、
        `catch-up.sh` がそれを使う (問いが違うので寄せていない)。
        """
        with tempfile.TemporaryDirectory() as tmp:
            status, _ = self.resolve(tmp)
        self.assertNotEqual(status, 0)

    def test_more_than_two_segments_is_not_a_slug(self):
        status, slug = self.resolve("https://example.invalid/a/b/c.git")
        self.assertNotEqual(status, 0, f"3 段を解いてしまった ({slug})")

    def test_no_origin_is_not_a_slug(self):
        status, _ = self.resolve()
        self.assertNotEqual(status, 0)

    def test_outside_a_repository_is_not_a_slug(self):
        with tempfile.TemporaryDirectory() as tmp:
            proc = run(f'repo_of_dir "{tmp}"')
        self.assertNotEqual(proc.returncode, 0)

    def test_an_empty_argument_is_refused(self):
        self.assertNotEqual(run('repo_of_dir ""').returncode, 0)


class OneImplementationTest(unittest.TestCase):
    """**実装が 1 つであることを構造で見る。**

    一覧は数え上げない — `scripts/*.sh` を glob するので、次に自前で剥がした人が
    ここを直さなくても掛かる。
    """

    def scripts(self):
        found = sorted(SCRIPTS.glob("*.sh"))
        self.assertTrue(found, f"検査対象の *.sh が 1 つも無い ({SCRIPTS})")
        return found

    def offending(self, pattern, message, allow=()):
        found = []
        for path in self.scripts():
            if path.name in allow:
                continue
            for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
                if line.lstrip().startswith("#"):
                    continue
                if re.search(pattern, line):
                    found.append(f"  {path.name}:{number}: {line.strip()}")
        if found:
            self.fail(message + "\n" + "\n".join(found))

    def test_no_script_strips_the_origin_url_itself(self):
        self.offending(
            r"remote\.origin\.url|remote get-url",
            "origin を自前で剥がしている箇所がある (repo_of_dir を通すこと):",
            allow=(LIB.name,),
        )

    def test_the_repository_name_lives_in_one_place(self):
        self.offending(
            r"mokume-metal/mokume",
            "リポジトリ名の literal を持っている箇所がある (this_repo を通すこと):",
            allow=(LIB.name,),
        )

    def test_the_place_with_no_default_keeps_none(self):
        """空の既定は**設計**である (#793)。literal を足してはいけない。"""
        text = (SCRIPTS / EMPTY_BY_DESIGN).read_text(encoding="utf-8")
        self.assertIn("GITHUB_REPOSITORY:-}", text, f"{EMPTY_BY_DESIGN} の空既定が消えている")

    def test_the_library_is_not_empty(self):
        """畳んだ先が空になっていない (この検査自身が空回りしていたら赤くする)。"""
        text = LIB.read_text(encoding="utf-8")
        self.assertIn("mokume-metal/mokume", text)
        self.assertIn("repo_of_dir()", text)


if __name__ == "__main__":
    unittest.main()
