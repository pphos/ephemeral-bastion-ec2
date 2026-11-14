---
name: semantic-commit
description: branch 上の完成した変更を、Human が独立して理解・revert・調査できる意味の単位で、安全に stage して commit するときに使う。履歴の書き換えや、未完成の変更の退避には使わない。
---

# semantic-commit

Issue の scope と branch 全体の差分を把握している親セッションが使います。人間が明示的に認めた Issue なしの作業でも、承認された範囲を同じ基準で扱います。目的は commit の数を増やすことではありません。「何を、なぜ変えた一手か」を Human が説明できる履歴を作ることです。

## commit する単位を決める

1. `git status`、unstaged の diff、staged の diff、branch にある既存の commit を確かめる
2. 今完成している変更理由を特定する
3. その変更を成り立たせる実装、対応する test、必要な docs を、同じ意味の単位として扱う
4. 別の変更理由、Issue の scope 外の差分、作業を始める前からあったユーザーの変更は除く

振る舞いの変更と、その振る舞いを守る test は分けません。file の種類、作業した順番、review の回数だけを理由に commit を分けません。小さな単一の変更なら1 commit でかまいません。

## commit message をそろえる

基本の形式は次のとおり。

```text
<type>: <日本語の変更概要>
```

今は、原則として次の type を使います。

| type       | 使うとき                                     |
| ---------- | -------------------------------------------- |
| `feat`     | 機能や、利用者向けの能力を足す               |
| `fix`      | 不具合を直す                                 |
| `refactor` | 振る舞いを変えずに、実装の構造をよくする     |
| `test`     | test の追加や修正が主目的                    |
| `docs`     | 文書の追加や修正が主目的                     |
| `chore`    | 上のどれにも当てはまらない、設定や運用の保守 |

type は commit の主目的で選びます。file の種類や作業の順番を理由に新しい type を作らず、必要のない type を場当たり的に足しません。この一覧は今の標準であり、repository で正当な必要が出てきたときの追加まで禁止するものではありません。

変更概要は日本語で書きます。技術用語や固有名詞を無理に日本語にする必要はありませんが、message 全体を英語の文にはしません。

```text
feat: 手入力の支出を予算残額に反映する
fix: 給与サイクルの境界の日を前のサイクルに数える不具合を直す
refactor: 予算枠の計算を domain に寄せる
test: 値引き配分の1円の残差の test を追加する
docs: ローカルでの起動手順を更新する
chore: Codex の作業ルールを更新する
```

1行目の後に空行を置き、必要なら本文で「なぜ変えたか」を短く書きます。末尾には、使っている harness が求める attribution（`Co-Authored-By` など）があれば付けます。

## 対象だけを commit する

対象の path だけを stage します。`git add .` を標準の手順にしません。同じ file に scope 外の hunk がある場合は、内容を確かめて必要な hunk だけを選びます。

stage したら `git diff --cached` と `git status` を確かめ、次を満たさなければ commit しません。

- staged の diff だけで、変更理由が成り立っている
- 必要な test や docs が欠けていない
- secret、環境 file（`.env` など）、ユーザーの変更、Issue の scope 外の差分が入っていない
- commit message が決まった形式と言語で書かれ、変更の内容だけでなく意図を表している

確かめられた対象だけを commit します。hook が変更を加えた場合は、staged の diff を確かめ直します。失敗した hook を無視して commit せず、原因を解消するか、blocker として返します。

## 扱わないこと

通常の処理では、既存の commit の amend、rebase、squash、force push をしません。review への対応であっても、review がきっかけだったことではなく、完成した変更理由から commit の境界を決めます。
