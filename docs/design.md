# 設計

使い捨ての踏み台 EC2 の要件と、設計の判断、その理由をまとめた文書です。デプロイの手順や使い方は [README.md](../README.md) を参照してください。

## 要件

- 利用者が必要なときだけ踏み台を起動し、使い終わったら削除する。セキュリティ上、Stop / Start は使わず、毎回新規に作って Terminate する
- 利用者は Windows PC の DB クライアントから、SSH トンネル経由で AWS 内の DB に接続する。接続はインターネット経由のみで、利用者には IAM 権限を付けない
- EC2 は Amazon Linux 2023 の最新 AMI（SSM パブリックパラメータで解決）、t3.micro 程度とする。初期化は User Data で行い、同時に起動するのは最大 1 台
- 固定の Elastic IP（EIP）を使い回し、Security Group で接続元 IP を固定する
- デプロイは Terraform で行う
- 将来は Slack から起動・終了できるようにする。現段階では対象外

判断に迷ったときの優先順位は、要件の充足、セキュリティ、シンプルさ、運用負荷の小ささ、拡張性の順です。過剰な仕組みは作らず、段階的に進めます。

## 全体構成

Terraform は、独立して apply する 3 つの構成に分けています。各構成は互いの state を参照せず、値は変数で受け取ります。手持ちの DB で試す人が、`bastion` だけを使えるようにするためです。

| 構成 | 位置づけ | 主なリソース |
|---|---|---|
| `terraform/bastion` | 本体 | EIP、踏み台の Security Group、IAM ロール、Launch Template、DB の Security Group への ingress ルール |
| `terraform/examples/sample-db` | 任意。DB を持たない人が試すための環境 | RDS for PostgreSQL、DB Subnet Group、DB の Security Group |
| `terraform/examples/bootstrap` | 任意。state 用のバケット | S3 バケット |

VPC とサブネットは既存のものを使い、Terraform では作りません。ID を変数で受け取ります。

## 設計の判断

### 起動の方法

踏み台は `RunInstances` 1 回で起動します。Step Functions は使いません。起動は Launch Template を指定した `RunInstances` で完結させます。Phase 1 は管理者が CLI で起動し、終了も `terminate-instances` で行います。

### EIP の関連付け

User Data の最終ステップで、EC2 自身が `aws ec2 associate-address --no-allow-reassociation` を実行します。ENI は使い回さず、Launch Template で毎回新規に作ります（EC2 と一緒に消える設定）。この方式で、次の 3 つが同時に満たせます。

- EIP が付いた時点で初期化が完了しているので、利用者は「つながったら準備完了」と判断できる
- EIP がすでに別のインスタンスに付いていれば関連付けが失敗するので、2 台目は自己 Terminate する。一瞬だけ 2 台目が存在することは許容する
- 初期化に失敗したときは、EIP を付けずに自己 Terminate する。Terminate すると関連付けは自動で外れ、同じ EIP を次の起動で使える

起動直後は、SSM からのホスト鍵の取得などで外向きの通信が必要です。そのため `associate_public_ip_address = true` で一時的なパブリック IP を付けます。この IP は EIP の関連付けで置き換わります。Security Group で接続元を絞っているので、一時 IP から外部の人が入ることはできません。

### 失敗時の動作（fail-closed）

初期化に失敗した踏み台は、必ず消えるようにします。

- `instance_initiated_shutdown_behavior = "terminate"` にして、OS から shutdown すれば Terminate になるようにする
- User Data は `set -Eeuo pipefail` と `trap 'shutdown -h now' ERR` で書き、失敗したら自己 Terminate させる
- EIP を付ける直前に、次の検査を行う。1 つでも失敗すれば EIP を付けずに終了する
  - `sshd -t`（sshd の設定の文法）
  - `id tunnel` と `ssh-keygen -l`（利用者のユーザーと公開鍵）
  - DB のポートへの TCP 接続（ログインはせず、つながるかだけを見る）

User Data の流れは、次のとおりです。

1. 固定のホスト鍵を SSM Parameter Store から取得して配置する
2. 利用者用のユーザー `tunnel` を作り、公開鍵を置く
3. sshd を設定する
4. 上の検査を行う
5. EIP を自分に関連付ける

### 利用者と管理者のログイン

利用者は専用ユーザー `tunnel` で入ります。シェルを使わせないのは、IMDS（インスタンスメタデータ）からインスタンスロールの一時クレデンシャルを取られるのを防ぐためです。そのロールでは、SSH のホスト秘密鍵を読み出せるうえ、EIP の関連付けもできます。「利用者に IAM 権限を付けない」という要件に反するので、シェルは使わせません。

- `tunnel` のログインシェルは `/sbin/nologin` にする
- sshd で `AllowUsers tunnel`、`PermitTTY no`、`ForceCommand /bin/false`、`AllowTcpForwarding local`、`PermitOpen <DB のホスト>:<ポート>` を設定する。許可するのはポートフォワードだけで、転送先は DB に限る
- `ec2-user` には、Launch Template の `key_name` を使わず公開鍵を置かない。さらに `AllowUsers` で SSH を拒否する。ユーザー自体の削除は、cloud-init との相性を考えて行わない

管理者は、AWS コンソールの SSM Session Manager で入ります。SSH では入りません。Instance Profile に `AmazonSSMManagedInstanceCore` を付け、Security Group の egress で HTTPS（443）を許可します。EIP が付いているので、VPC エンドポイントは要りません。

### SSH ホスト鍵

固定の ed25519 のホスト鍵を SecureString として SSM Parameter Store に置き、起動時に取得して配置します。`HostKey` はその 1 本だけです。ホスト鍵は Terraform の外で一度だけ生成して投入します。`tls_private_key` を使うと state に残るため避け、User Data への直書きも避けます。

利用者には、`<EIP> ssh-ed25519 AAAA...` の known_hosts 1 行を配ります。EIP もホスト鍵も固定なので、利用者の設定は一度作れば使い続けられます。

### Security Group

| 対象 | 向き | 許可する内容 |
|---|---|---|
| 踏み台 | ingress | TCP 22。接続元は変数 `allowed_cidrs` で渡す固定の CIDR |
| 踏み台 | egress | TCP 443（SSM と EC2 API）。DB のポートは DB の Security Group 宛て |
| DB | ingress | 踏み台の Security Group からの DB ポート |

DB 側は、IP ではなく踏み台の Security Group を指定します。踏み台は毎回 IP が変わるためです。このルールは `bastion` の Terraform で管理し、DB の Security Group 本体には触れません。Terraform で作る Security Group には、AWS が既定で付ける「全許可」の egress が付きません。必要な egress は、すべて明示します。

`allowed_cidrs` は既定値のない必須の変数にします。値は apply のときに `-var` か、`.gitignore` に入れた `terraform.tfvars` で渡し、個人の IP をリポジトリに残しません。

### Instance Profile の権限

| 権限 | 用途 |
|---|---|
| `ssm:GetParameter` | ホスト鍵の取得。対象はそのパラメータだけ |
| `kms:Decrypt` | ホスト鍵の復号。`aws/ssm` の既定キーなら不要 |
| `ec2:AssociateAddress` | EIP の関連付け。EIP・インスタンス・ENI の 3 リソースに `Role=bastion` タグの条件を付ける |
| `AmazonSSMManagedInstanceCore`（AWS 管理ポリシー） | 管理者の SSM 接続 |

`aws_eip` には `arn` 属性がないため（AWS プロバイダ 6.73.0 で確認）、EIP の ARN は `allocation_id` から組み立てます。

### 終了の方法

終了は管理者が CLI で行います。最大寿命の shutdown も、接続の有無を見るアイドル判定も入れません。Phase 1 は管理者が起動と終了を行うので、仕組みを足さずに済ませます。接続を開いたままにすると踏み台は残り続けますが、この切り忘れは考慮しません。必要になった時点で、User Data に足せます。

### state の保存先

state は S3 バケットに置き、ロックは S3 だけで行います（`use_lockfile`）。DynamoDB は使いません。バケットは `bootstrap` の Terraform で作ります。最初はローカル state で作り、そのあとバケットを保存先に設定して state を移します。これが一般的な手順です。

### sample-db（検証用の DB）

RDS for PostgreSQL、`db.t4g.micro`、シングル AZ、gp3 の 20 GB とします。ストレージは暗号化し、パブリックアクセスは無効にします。削除保護、最終スナップショット、自動バックアップは付けません。`terraform destroy` ですぐ消せることを最優先にするためです。

マスターパスワードは `password_wo`（write-only 引数）で渡します。値が state に残らず、Terraform 1.11 以降で使えます。`manage_master_user_password` は、ローテーションを止めると Secrets Manager を使う利点が薄いため、採用しませんでした。

### Terraform のファイル構成と命名

ファイル名は、HashiCorp のスタイルガイドに合わせます。

| ファイル | 中身 |
|---|---|
| `terraform.tf` | `required_version`、`required_providers` |
| `backend.tf` | S3 backend |
| `providers.tf` | AWS provider（`ap-northeast-1`） |
| `variables.tf` / `outputs.tf` | 変数と出力 |
| `main.tf` | リソース。見通しが悪くなったら、論理的なまとまりごとに分ける |
| `userdata.sh.tftpl` | User Data のテンプレート |
| `terraform.tfvars.example` | 変数の記入例 |

リソース名は `${var.name_prefix}-<役割>` とし、`name_prefix` の既定値は `ephemeral-bastion` です。

## 利用者の動線（Phase 1）

初回だけ、管理者が DB クライアントの SSH トンネル設定（ホスト、ユーザー `tunnel`、秘密鍵、転送先 DB）と known_hosts の 1 行を配ります。

| 手順 | 内容 |
|---|---|
| 起動の依頼 | 管理者に依頼し、管理者が CLI で起動する |
| 準備完了の確認 | 2〜3 分後に接続を試す。つながれば準備完了 |
| 利用 | DB クライアントで接続する |
| 終了 | 管理者が `terminate-instances` で削除する |

## 段階的な進め方

1. Phase 1：Terraform と User Data のみ。管理者が CLI で起動と終了を行う
2. Phase 2：Slack からの依頼を受けて、start / stop を行う Lambda。任意で、夜間に `Role=bastion` の取り残しを掃除する Lambda
3. Phase 3：Slack 連携。準備完了の通知は、`DescribeAddresses` で EIP の関連付け先を確認するだけで判定できる

## 見送った案

| 案 | 見送った理由 |
|---|---|
| Step Functions によるオーケストレーション | `RunInstances` 1 回で足りる |
| ENI を使い回し、EIP を ENI に固定する | シンプルだが、ENI を残したくない |
| 外部から `AssociateAddress` を呼ぶ | 起動が複数ステップになり、タグ検索による多重起動の判定に競合がある。初期化の完了前に EIP が付いてしまう |
| SSH ホスト証明書 | 署名鍵の管理が別に必要。Windows の DB クライアント内蔵 SSH が対応していないことが多い |
| 最大寿命とアイドル判定による自動終了 | 検証用であり、仕組みを増やさない。管理者が CLI で終了する |
| 一時パブリック IP をなくす VPC エンドポイント構成 | 構成が重くなる |
| `manage_master_user_password` | ローテーションを止めると、Secrets Manager を使う利点が薄い |
| `terraform_remote_state` で、`sample-db` の出力を `bastion` に渡す | 手持ちの DB で使う人が、`sample-db` なしで `bastion` を使えなくなる |

## 未確定の事項

- 利用者が使う DB クライアント（A5:SQL Mk-2、DBeaver、HeidiSQL など）の内蔵 SSH が、known_hosts をどう扱うか（保存先、初回のダイアログ）。配布手順はこれで決まる
- `ForceCommand /bin/false` を設定しても、DB クライアントのトンネルが動くか。実機で確かめる
- `ec2:AssociateAddress` のタグ条件が、意図どおり効くか。最初の apply のあとで確かめ、拒否されたら CloudTrail で理由を見る
- Terraform と AWS プロバイダのバージョンの固定方法
