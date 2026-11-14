# ephemeral-bastion-ec2

使い捨ての踏み台 EC2 を Terraform で管理します。必要なときだけ起動し、使い終わったら Terminate します。構成と手順は [README.md](README.md) を参照してください。

## AWS の操作

- 実リソースを作る・変える・消す操作（`terraform apply` / `destroy`、`run-instances`、`terminate-instances` など）は、Human の明示的な了承を得てから行う。`describe`・`list`・`terraform plan` などの読み取りは了承不要
- apply の前に `terraform plan` で差分を確かめる。置き換え（replace）や削除を含むなら、実行前に Human に伝える
- Terraform を変えたら、`terraform fmt` と `terraform validate` を通してから完了とする。実行していない確認を済んだと言わない

## Terraform の設計

- 頼まれた範囲だけを作る。将来のためだけのリソース・変数・抽象化は足さない
- Terraform のリソース・引数・属性と、Terraform の設計や書き方の提案（state、backend、ファイル構成、バージョン指定など）は、記憶で答えず、Terraform MCP や HashiCorp の公式ドキュメントで確かめてから出す
- AWS の仕様（IAM アクション、リソースレベルの権限、サービスの制約）と、AWS のサービスを使った設計の提案は、記憶で答えず、AWS MCP のドキュメント検索や Skill で確かめてから出す
- リソース名は `${var.name_prefix}-<役割>` にそろえる。`name_prefix` の既定値は `ephemeral-bastion`
- secret は、Terraform の state・User Data・README・コミットに含めない
- 費用が増える変更や未確定の仕様は、推測で埋めずに Human に確認する

## 文書とコミット

- 構成やデプロイ手順を変えたら、同じ変更の中で README も直す
- 説明や判断の理由を述べる地の文は丁寧調。箇条書き・表・短い注記はだ・である調か体言止め
- 書き上げた文書とPRの本文は、仕上げに`yomiyasu` Skillで推敲する
  - 執筆は `natural-japanese`、推敲は `yomiyasu` と工程で使い分ける
  - 同じ工程で2つの Skill を重ねない
- 文書を新しく書く・大きく書き直すときは `natural-japanese` Skill、commit するときは `semantic-commit` Skill を使う
- 文書を変えたら、`yomiyasu`の`scripts/yomiyasu_lint.py`で表現と書式を確かめる
  - 指摘は見直しの候補である
  - 直すかどうかは、原文と文脈で判断する
- Skill の実体は `.agents/skills/`。`.claude/skills/` はそこへのシンボリックリンク
