# 設計

使い捨ての踏み台 EC2 の要件と、設計の判断、その理由をまとめた文書です。デプロイの手順や使い方は [README.md](../README.md) を参照してください。

## 要件

- 利用者が必要なときだけ踏み台を起動し、使い終わったら削除する。Stop / Start は使わず、毎回、新規に作って Terminate する。OS の更新の手間をなくし、踏み台の保守コストを下げるためである
- 利用者は、Windows または Mac の PC にある DB クライアントから、SSH トンネル経由で AWS 内の DB に接続する。接続はインターネット経由のみ。SSH で接続するだけなので、利用者には AWS の権限（IAM 権限）を付けない
- EC2 は Amazon Linux 2023（arm64 版）、t4g.micro 程度とする。AMI は、SSM パブリックパラメータ `al2023-ami-kernel-default-arm64` で、起動のたびに最新のものを解決する。初期化は User Data で行い、同時に起動するのは最大 1 台
- 固定の Elastic IP（EIP）を使い回し、Security Group で接続元 IP を固定する
- Slack の専用チャンネルにあるボタンで、起動と終了ができる。ボタンを押せるのは、そのチャンネルのメンバー
- デプロイは Terraform で行う

判断に迷ったときの優先順位は、要件の充足、セキュリティ、シンプルさ、運用負荷の小ささ、拡張性の順です。過剰な仕組みは作らず、段階的に進めます。

## 全体構成

Terraform は、独立して apply する 4 つの構成に分けています。各構成は互いの state を参照せず、値は変数で受け取ります。手持ちの DB で試す人が、`sample-db` なしでも `bastion-ec2` と `bastion-ec2-slackops` を使えるようにするためです。

| 構成 | 位置づけ | 主なリソース |
|---|---|---|
| `terraform/bastion-ec2` | 本体。踏み台の EC2 と、その土台 | EIP、踏み台の Security Group、IAM ロール、Launch Template、DB の Security Group への ingress ルール |
| `terraform/bastion-ec2-slackops` | 本体。Slack のボタンで踏み台を起動・終了する | Slack の通知を受ける Lambda（Function URL）、Step Functions（Standard）、EventBridge の接続、IAM ロール |
| `terraform/examples/sample-db` | 任意。DB を持たない人が試すための環境 | RDS for PostgreSQL、DB Subnet Group、DB の Security Group |
| `terraform/examples/bootstrap` | 任意。state 用のバケット | S3 バケット |

`bastion-ec2-slackops` は、`bastion-ec2` の Launch Template の ID や EIP の割り当て ID を、変数で受け取ります。VPC とサブネットは既存のものを使い、Terraform では作らず、ID を変数で受け取ります。

## 設計の判断

### 起動の方法

踏み台は、Launch Template を指定した `RunInstances` 1 回で起動します。Phase 1 では、起動も終了も、管理者が CLI で行う運用です。Phase 2 では、Step Functions が `RunInstances` と `TerminateInstances` を呼びます。

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

1. CloudWatch エージェントをインストールし、Parameter Store の設定で起動する
2. 固定のホスト鍵を SSM Parameter Store から取得して配置する
3. 利用者用のユーザー `tunnel` を作り、SSM Parameter Store から取得した公開鍵を `authorized_keys` に置く
4. sshd を設定する
5. 上の検査を行う
6. EIP を自分に関連付ける

### 利用者と管理者のログイン

利用者は専用ユーザー `tunnel` で入ります。利用者に必要なのは DB へのトンネルだけなので、シェルは使わせない方針です。シェルを使えると、IMDS（インスタンスメタデータ）から、インスタンスロールの一時クレデンシャルを取られるおそれがあります。そのロールで、SSM Parameter Store に置いた SSH のホスト秘密鍵を読み出せます。IMDS には、sudo が使えないユーザーも含めて、サーバー上の誰でもアクセスできるためです。

- `tunnel` のログインシェルは `/sbin/nologin` にする
- sshd で `Port`（変数 `ssh_port` の値。標準の 22 は使わない）、`AllowUsers tunnel`、`PermitTTY no`、`ForceCommand /bin/false`、`AllowTcpForwarding local`、`PermitOpen <DB のホスト>:<ポート>` を設定する。許可するのはポートフォワードだけで、転送先は DB に限る
- `ec2-user` には、Launch Template の `key_name` を使わず公開鍵を置かない。さらに `AllowUsers` で SSH を拒否する。ユーザー自体の削除は、cloud-init との相性を考えて行わない

管理者は、AWS コンソールの SSM Session Manager で入ります。SSH では入りません。Instance Profile に `AmazonSSMManagedInstanceCore` を付けます。EIP が付いているので、VPC エンドポイントは要りません。

### SSH ホスト鍵

固定の ed25519 のホスト鍵を SecureString として SSM Parameter Store に置き、起動時に取得して配置します。`HostKey` はその 1 本だけです。ホスト鍵は Terraform の外で一度だけ生成して投入します。`tls_private_key` を使うと state に残るため避け、User Data への直書きも避けます。

EIP もホスト鍵も固定なので、利用者の `known_hosts` に記録された鍵は、踏み台が新しくなっても、そのまま使えます。

### 利用者の公開鍵

利用者の公開鍵は、ホスト鍵と同じく SecureString として SSM Parameter Store に置き、起動時に取得して、`tunnel` の `authorized_keys` に書きます。型をそろえる利点は、取得の処理と権限の設定を、ホスト鍵と共通にできることです。利用者の追加と削除は、Terraform を apply し直さずに、パラメータの値を書き換えるだけで行えます。取得できなければ、User Data が失敗して、踏み台は自己 Terminate します。

### Security Group

| 対象 | 向き | 許可する内容 |
|---|---|---|
| 踏み台 | ingress | TCP の `ssh_port`（既定値は 2222）。接続元は変数 `allowed_cidrs` で渡す固定の CIDR |
| 踏み台 | egress | 全許可（0.0.0.0/0、全ポート） |
| DB | ingress | 踏み台の Security Group からの DB ポート |

DB 側は、IP ではなく踏み台の Security Group を指定します。踏み台は毎回 IP が変わるためです。このルールは `bastion-ec2` の Terraform で管理し、DB の Security Group 本体には触れません。Terraform で作る Security Group には、AWS が既定で付ける「全許可」の egress が付かないので、踏み台の egress は、全許可を明示して付けます。踏み台は、利用者にシェルを使わせず、短時間だけ動くため、出口は絞りません。

`allowed_cidrs` は既定値のない必須の変数にします。値は apply のときに `-var` か、`.gitignore` に入れた `terraform.tfvars` で渡し、個人の IP をリポジトリに残しません。

### Instance Profile の権限

| 権限 | 用途 |
|---|---|
| `ssm:GetParameter` | ホスト鍵、利用者の公開鍵、CloudWatch エージェントの設定の取得。対象は、その 3 つのパラメータだけ |
| `logs:CreateLogStream`、`logs:PutLogEvents` | ログの送信。対象は、踏み台用のロググループだけ |
| `ec2:AssociateAddress` | EIP の関連付け。EIP・インスタンス・ENI の 3 リソースに `Role=bastion` タグの条件を付ける |
| `AmazonSSMManagedInstanceCore`（AWS 管理ポリシー） | 管理者の SSM 接続 |

`aws_eip` には `arn` 属性がないため（AWS プロバイダ 6.73.0 で確認）、EIP の ARN は `allocation_id` から組み立てます。

### EC2 のログ

User Data が失敗した踏み台は、自分で消えるため、ローカルのログも一緒に消えます。あとから調べられるように、次の 2 つのログを、CloudWatch Logs に送ります。

- User Data の実行ログ（cloud-init の出力）：初期化のどこで失敗したかを見る
- sshd のログ：誰が、いつ、どこから接続したかを見る

Amazon Linux 2023 は、ログを systemd のジャーナルに記録するので、sshd のログは、ジャーナルから集めます。送る方法は、CloudWatch エージェントです。

- User Data の最初のほうで、エージェントをインストールし、Parameter Store の設定を取得して起動する
- 設定は、String のパラメータに置いて、Terraform で作る
- ロググループも Terraform で作り、保持期間を設定する
- User Data が失敗して shutdown するときは、ログを送り終えるために、少し待ってから終了する

### Slack からの操作

専用チャンネルに、「起動」「終了」のボタンを付けたメッセージを常設します。自作の Slack アプリがボタンの操作を受け取り、次の流れで処理します。

1. 利用者がボタンを押すと、Slack が、あらかじめ登録した Lambda Function URL へ通知を送る
2. Function URL を持つ Lambda が、Slack の署名と、決めたチャンネルからの通知かどうかを確かめ、Step Functions の実行を開始する
3. Step Functions が、EC2 の起動または終了、準備完了か失敗かの確認、Slack への通知を行う

利用者に IAM 権限は付けません。AWS を操作するのは、Lambda と Step Functions だけです。ボタンを押せるのは、専用チャンネルのメンバーです。許可する Slack ユーザー ID は持たず、プライベートチャンネルのメンバー管理に任せます。

### Function URL の Lambda

Slack の通知を受ける Lambda は、Function URL を `AuthType=NONE` で公開します。Slack は AWS の署名を付けられないためです。そのため、Lambda のコードで Slack の署名（Signing Secret）を確かめます。Function URL には、レート制限も WAF もありません。この Lambda には同時実行数の上限を付けて、流量を抑えます。

公開される Lambda には、EC2 を操作する権限を持たせません。持つのは、Step Functions の実行を開始する権限と、署名の確認に使う秘密を読む権限だけです。署名の確認に使う秘密は、SSM Parameter Store の SecureString に、Terraform の外で入れます。

### Step Functions の状態機械

Step Functions は Standard にします。踏み台の初期化に 2〜3 分かかり、準備完了を待つ時間が加わるため、最大 5 分の Express では余裕がありません。Standard は、実行名が同じ呼び出しを重複した開始として扱うので、Slack の再送で処理が二重に動くことを避けられます。実行履歴は 90 日間残り、失敗の調査に使えます。

状態機械は、EC2 と Slack を直接呼びます。AWS SDK 統合で `RunInstances` と `TerminateInstances` などを呼び、HTTP Task で Slack の API を呼びます。処理用の Lambda は要りません。

- 起動：起動中の踏み台がないか確かめる。なければ、`ClientToken` を付けて `RunInstances` を呼ぶ。EIP の関連付け先とインスタンスの状態を、数秒おきに確かめ、準備完了か失敗かを知らせる
- 終了：起動中の踏み台を探して、`TerminateInstances` を呼び、結果を知らせる
- すでに起動中のときに「起動」が押されたら、何もせず、「すでに起動しています」と知らせる
- 起動中の踏み台がないときに「終了」が押されたら、何もせず、「起動中の踏み台はありません」と知らせる

同時に 1 台までという制限は、実行名の仕組みではなく、これまでどおり、EIP の関連付けと起動中の確認で守ります。状態機械の実行ロールには、EC2 の起動・終了・参照と、接続の利用に必要な権限を、必要最小限で付けます。

### Slack のトークン

HTTP Task は、EventBridge の接続を通して Slack のトークンを使います。トークンは、接続が Secrets Manager に暗号化して保管します。接続が作るシークレットは、自分で用意したものに差し替えられません。

Terraform の state には、リソースの引数に渡した値が、そのまま残ります。変数や環境変数で渡しても同じです。この接続には write-only の引数がないため、本物のトークンは Terraform に渡しません。次の手順にします。

1. Terraform が、接続を仮の値（ダミー）で作る。state に残るのは、ダミーだけ
2. 人が、AWS CLI でトークンを本物に更新する
3. 接続のトークンの設定には、`lifecycle` の `ignore_changes` を付ける。Terraform は、この項目の差分を見ず、ほかの項目を更新したときも、本物のトークンを仮の値で上書きしない

接続は Terraform が作るので、`terraform destroy` で一緒に消えます。`ignore_changes` を外すと、次の apply でトークンが仮の値に戻り、Slack の通知が止まるので、この理由をコードのコメントに書きます。

### 結果の知らせ方

結果は、同じチャンネルに、新しいメッセージとして順に投稿します。「起動しています」「準備ができました」「失敗しました」の順です。ボタンのメッセージは書き換えません。メッセージの ID を保存して更新する仕組みを、持たずに済むためです。

### 終了の方法

Phase 1 では、管理者が CLI で終了します。Phase 2 では、「終了」ボタンを押します。最大寿命の shutdown も、接続の有無を見るアイドル判定も入れません。接続を開いたままにすると踏み台は残り続けますが、この終了の押し忘れは考慮しません。必要になった時点で、User Data に足せます。

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
| `userdata.sh.tftpl` | User Data のテンプレート（`bastion-ec2` のみ） |
| `terraform.tfvars.example` | 変数の記入例 |

リソース名は `${var.name_prefix}-<役割>` とし、`name_prefix` の既定値は `ephemeral-bastion` です。

## 利用者の動線

初回だけ、管理者が DB クライアントの SSH トンネル設定（ホスト、ユーザー `tunnel`、秘密鍵、転送先 DB）を配ります。

| 手順 | Phase 1（CLI） | Phase 2（Slack） |
|---|---|---|
| 起動の依頼 | 管理者に依頼し、管理者が CLI で起動する | 「起動」ボタンを押す |
| 準備完了の確認 | 2〜3 分後に接続を試す。つながれば準備完了 | 「準備ができました」の投稿を待つ |
| 利用 | DB クライアントで接続する | 同左 |
| 終了 | 管理者が `terminate-instances` で削除する | 「終了」ボタンを押す |

## 段階的な進め方

1. Phase 1（`bastion-ec2`）：Terraform と User Data。管理者が CLI で起動と終了を行う
2. Phase 2（`bastion-ec2-slackops`）：Slack のボタンで、起動と終了を行う

## 見送った案

| 案 | 見送った理由 |
|---|---|
| `bastion-ec2` の起動を、Step Functions で行う | `RunInstances` 1 回で足りる。Step Functions は、Slack 連携でだけ使う |
| ENI を使い回し、EIP を ENI に固定する | シンプルだが、ENI を残したくない |
| 外部から `AssociateAddress` を呼ぶ | 起動が複数ステップになり、タグ検索による多重起動の判定に競合がある。初期化の完了前に EIP が付いてしまう |
| SSH ホスト証明書 | 署名鍵の管理が別に必要。Windows の DB クライアント内蔵 SSH が対応していないことが多い（Mac のクライアントは未確認） |
| 最大寿命とアイドル判定による自動終了 | 仕組みを増やさない。終了は、管理者の CLI か、Slack の「終了」ボタンで行う |
| 一時パブリック IP をなくす VPC エンドポイント構成 | 構成が重くなる |
| `manage_master_user_password` | ローテーションを止めると、Secrets Manager を使う利点が薄い |
| `terraform_remote_state` で、`sample-db` の出力を `bastion-ec2` に渡す | 手持ちの DB で使う人が、`sample-db` なしで `bastion-ec2` を使えなくなる |
| Amazon Q Developer in chat applications（旧 AWS Chatbot）のカスタムアクション | ボタンは通知に付く形で、専用チャンネルへの常設が確認できなかった。通知が流れると、ボタンを押せなくなる恐れがある |
| Slack の通知を受ける Lambda と、EC2 を操作する Lambda の 2 つ | EC2 と Slack は、Step Functions の AWS SDK 統合と HTTP Task で直接呼べるため、処理側の Lambda は要らない |
| Lambda が自分自身を非同期で呼ぶ | 公開される Lambda に EC2 の権限を持たせることになる。再帰呼び出しの自動検出も、この形は対象にしていない |
| Lambda の中で準備完了を待つ | 待つ、分岐する、失敗を通知するという流れは、Step Functions で表すほうが素直 |
| EventBridge と CloudTrail のイベントによる準備完了の検出 | EIP の関連付けは EC2 の状態変化ではなく、CloudTrail 経由になり、EventBridge のルールも増える |
| Step Functions の Express | 最大 5 分の上限に近づく恐れがある。重複した開始を防ぐ仕組みもない |
| 許可する Slack ユーザー ID を変数で持つ | 人が増減するたびに、Terraform を直すことになる。チャンネルのメンバーで管理する |
| ボタンのメッセージを書き換えて、状態を表示する | メッセージの ID を保存して更新する仕組みが増える |
| Slack のトークンを、変数で渡して state に残す | 変数や環境変数で渡しても、state にトークンが残る。AGENTS.md の方針に反する |
| Slack のトークンを SSM に置き、通知用の Lambda で投稿する | Lambda が増える。HTTP Task で足りる |
| EventBridge の接続を、Terraform の外で作る | 手作業が増え、`terraform destroy` でも消えない |

## 未確定の事項

- 利用者が使う DB クライアント（A5:SQL Mk-2、DBeaver、HeidiSQL など）の内蔵 SSH が、known_hosts をどう扱うか。Windows と Mac の両方で確かめる
- `ForceCommand /bin/false` を設定しても、DB クライアントのトンネルが動くか。実機で確かめる
- `ec2:AssociateAddress` のタグ条件が、意図どおり効くか。最初の apply のあとで確かめ、拒否されたら CloudTrail で理由を見る
- Terraform と AWS プロバイダのバージョンの固定方法
- 利用者の公開鍵のパラメータを、Terraform で作るか、ホスト鍵と同じく Terraform の外で入れるか
- Amazon Linux 2023 での、CloudWatch エージェントのインストール方法（`dnf`）と、User Data のログの場所。実装のときに確かめる
- sshd のログに、ログインに使った公開鍵の指紋が残るか。残れば、利用者の区別に使える
- ロググループの保持期間- HTTP Task が、EventBridge の接続（API Key の方式）で、Slack のトークンを `Authorization: Bearer ...` の形で渡せるか
- `ignore_changes` を付けた接続で、トークンを CLI で更新したあとも plan が空になるか。ほかの項目を更新しても、本物のトークンを上書きしないか
- 状態機械の実行ロールに必要な権限。`RunInstances` に伴う権限の詳細は、実装のときに AWS のドキュメントで確かめる
- 準備完了を確かめる間隔と、失敗と見なす時間。初期化にかかる時間を見て決める
- Slack の通知を受ける Lambda の言語と、コードの置き場所
- ボタン付きのメッセージを、最初に 1 回、専用チャンネルへ置く方法。Slack アプリの作成手順とあわせて、README に書く
