# 設計

使い捨ての踏み台 EC2 の要件と、設計の判断、その理由をまとめた文書です。デプロイの手順や使い方は [README.md](../README.md) を参照してください。

## 要件

- 利用者が必要なときだけ踏み台を起動し、使い終わったら削除する。Stop / Start は使わず、毎回、新規に作って Terminate する。OS の更新の手間をなくし、踏み台の保守コストを下げるためである
- 利用者は、Windows または Mac の PC にある DB クライアントから、SSH トンネル経由で AWS 内の DB に接続する。接続はインターネット経由のみ。SSH で接続するだけなので、利用者には AWS の権限（IAM 権限）を付けない
- EC2 は Amazon Linux 2023（arm64 版）、t4g.micro 程度とする。AMI は、SSM パブリックパラメータ `al2023-ami-kernel-default-arm64` で、起動のたびに最新のものを解決する。初期化は User Data で行い、同時に起動するのは最大 1 台
- 固定の Elastic IP（EIP）を使い回し、Security Group で接続元 IP を固定する
- Slack の専用チャンネルで、スラッシュコマンド `/bastion start` と `/bastion stop` を打つと、起動と終了ができる。専用チャンネルはパブリックチャンネルで、ワークスペースの誰でも操作できる
- デプロイは Terraform で行う

判断に迷ったときの優先順位は、要件の充足、セキュリティ、シンプルさ、運用負荷の小ささ、拡張性の順です。過剰な仕組みは作らず、段階的に進めます。

## 全体構成

Terraform は、独立して apply する 4 つの構成に分けています。各構成は互いの state を参照しません。`bastion-ec2` は DB の値を変数で受け取ります。手持ちの DB で試す人が、`sample-db` なしでも `bastion-ec2` と `bastion-ec2-slackops` を使えるようにするためです。

| 構成 | 位置づけ | 主なリソース |
|---|---|---|
| `terraform/bastion-ec2` | 本体。踏み台の EC2 と、その土台 | EIP、踏み台の Security Group、IAM ロール、Launch Template、DB の Security Group への ingress ルール |
| `terraform/bastion-ec2-slackops` | 本体。Slack のスラッシュコマンドで踏み台を起動・終了する | スラッシュコマンドを受ける Lambda（Function URL）、Step Functions（Standard）、EventBridge の接続、IAM ロール |
| `terraform/examples/sample-db` | 任意。DB を持たない人が試すための環境 | RDS for PostgreSQL、DB Subnet Group、DB の Security Group |
| `terraform/examples/bootstrap` | 任意。state 用のバケット | S3 バケット |

`bastion-ec2-slackops` は、`bastion-ec2` が作った Launch Template、EIP、踏み台の IAM ロールを、data source で名前とタグから引きます。`bastion-ec2` のリソース名はどれも `${resource_prefix}-bastion` なので、`resource_prefix` を同じ値にそろえるだけで済みます。`bastion-ec2` に出力を追加する必要はなく、state を読む権限も要りません。`bastion-ec2` がなければ plan が失敗するので、作る順番も自然に守られます。

VPC とサブネットは既存のものを使い、Terraform では作らず、ID を変数で受け取ります。

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
  - `sshd -t`（sshd の設定の文法）と、`sshd -T`（効いている設定）
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
- sshd で `Port`（変数 `ssh_port` の値。標準の 22 は使わない）、`AllowUsers tunnel`、`PermitTTY no`、`ForceCommand /bin/false`、`AllowTcpForwarding local`、`AllowStreamLocalForwarding no`、`PermitOpen <DB のホスト>:<ポート>` を設定する。許可するのはポートフォワードだけで、転送先は DB に限る。Unix ソケットの転送は、TCP の設定とは別なので、個別に止める。`PermitOpen` は文字列をそのまま比べるため、利用者のトンネルの転送先は、DB のエンドポイントの名前と同じにする
- `ec2-user` には、Launch Template の `key_name` を使わず公開鍵を置かない。さらに `AllowUsers` で SSH を拒否する。ユーザー自体の削除は、cloud-init との相性を考えて行わない
- sshd の設定は、`/etc/ssh/sshd_config.d/00-bastion.conf` に置く。標準の `sshd_config` を書き換えると、暗号の方針（crypto policy）が外れて、古い `ssh-rsa` の署名が有効に戻る恐れがあるためである
- `Port` と `HostKey` は、標準の設定と足し合わされる。EIP を付ける前に `sshd -T` で、効いている設定が意図どおりで、ポートとホスト鍵が 1 つずつであることを確かめる
- `authorized_keys` は、root 所有の `/etc/ssh/authorized_keys/tunnel` に置く（`AuthorizedKeysFile`）。`tunnel` にホームディレクトリは作らない

管理者は、AWS コンソールの SSM Session Manager で入ります。SSH では入りません。Instance Profile に `AmazonSSMManagedInstanceCore` を付けます。EIP が付いているので、VPC エンドポイントは要りません。

### SSH ホスト鍵

固定の ed25519 のホスト鍵を SecureString として SSM Parameter Store に置き、起動時に取得して配置します。`HostKey` はその 1 本だけです。ホスト鍵は Terraform の外で一度だけ生成して投入します。`tls_private_key` を使うと state に残るため避け、User Data への直書きも避けます。

EIP もホスト鍵も固定なので、利用者の `known_hosts` に記録された鍵は、踏み台が新しくなっても、そのまま使えます。

### 利用者の公開鍵

利用者の公開鍵は、ホスト鍵と同じく SecureString として SSM Parameter Store に置き、起動時に取得して、`tunnel` の `authorized_keys` に書きます。型をそろえる利点は、取得の処理と権限の設定を、ホスト鍵と共通にできることです。利用者の追加と削除は、Terraform を apply し直さずに、パラメータの値を書き換えるだけで行えます。取得できなければ、User Data が失敗して、踏み台は自己 Terminate します。

ホスト鍵と公開鍵のパラメータは、どちらも Terraform の外で作ります。作る手間を減らすため、`scripts/setup-ssm-parameters.sh` を用意します。公開鍵のファイルを渡すと、ホスト鍵がなければ生成して置き、公開鍵のパラメータは上書きで更新できます。秘密鍵は一時ディレクトリにだけ作り、スクリプトの終了時に消えるようにしてあります。

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
| `logs:CreateLogStream`、`logs:PutLogEvents`、`logs:DescribeLogStreams` | ログの送信。対象は、踏み台用のロググループだけ。`DescribeLogStreams` は、CloudWatch エージェントが必要とする |
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
- ロググループも Terraform で作り、保持期間は 30 日とする
- User Data の実行ログは `/var/log/cloud-init-output.log` を、sshd のログは journald の `sshd` ユニットを集める（設定は AWS のドキュメントで確認済み）
- エージェントは、Amazon Linux 2023 のリポジトリのパッケージを `dnf install` で入れる
- User Data が失敗して shutdown するときは、ログを送り終えるために、少し待ってから終了する

### Slack からの操作

利用者は専用チャンネルでスラッシュコマンド `/bastion start` か `/bastion stop` を打ちます。自作の Slack アプリがコマンドを受け取り、次の流れで処理します。

1. Slack がアプリに登録した Lambda Function URL へ、コマンドの内容を送る
2. Lambda が Slack の署名と、専用チャンネルからのコマンドかを確かめ、Step Functions の実行を開始する
3. Step Functions が、EC2 の起動または終了と、準備完了か失敗かの確認を行い、結果を Slack に投稿する

コマンドは `/bastion` の 1 つだけにし、引数で start と stop を分けます。引数がないときや、知らない引数のときは、使い方を返します。スラッシュコマンドなら、ボタンのようにチャンネルへメッセージを置いておく必要がありません。

専用チャンネルはパブリックチャンネルにして、ワークスペースの誰でも操作できるようにします。隠す必要のある操作ではないためです。利用者に IAM 権限は付けず、AWS を操作するのは Lambda と Step Functions だけです。

Slack アプリのスコープは `commands` と `chat:write` の 2 つです。アプリは専用チャンネルに招待して、そこに投稿します。招待していないチャンネルにも投稿できる `chat:write.public` は付けません。

### Function URL の Lambda

スラッシュコマンドを受ける Lambda は、Function URL を `AuthType=NONE` で公開します。Slack は AWS の署名を付けられないためです。そのため、Lambda のコードで Slack の署名を確かめます。

公開される Lambda には EC2 を操作する権限を持たせません。持つ権限は次のとおりです。

| 権限 | 用途 |
|---|---|
| `states:StartExecution` | 状態機械の実行の開始。対象は、この状態機械だけ |
| `states:ListExecutions` | 動いている実行があるかの確認。対象は、この状態機械だけ |
| `ssm:GetParameter` | Signing Secret の取得。対象は、そのパラメータ 1 つだけ |

Signing Secret のパラメータは、AWS 管理キーの `aws/ssm` で暗号化します。このキーはアカウント内のすべての IAM プリンシパルに復号を許しているので、`kms:Decrypt` は付けません。

Lambda は届いたコマンドを次の順に処理します。

1. 本文が Base64 で届いたとき（イベントの `isBase64Encoded`）は、元に戻す
2. Slack の署名を確かめる。`X-Slack-Request-Timestamp` が 5 分以上ずれていれば拒否する。署名は届いた本文をそのまま使って計算する。先に本文を分解すると、署名と合わなくなるためである
3. 本文を `URLSearchParams` で分解し、使う項目がそろっているかを確かめる。スラッシュコマンドの本文は JSON ではなく `application/x-www-form-urlencoded` で届く
4. `channel_id` が、変数 `slack_channel_id` の値と一致するかを確かめる。一致しなければ、空の 200 を返して終える
5. `text` が start か stop でなければ、使い方を返して終える
6. `ListExecutions` で、動いている実行があるかを確かめる。あれば、実行を始めずに「前の処理が終わるまで待ってから、もう一度実行してください。」と返す
7. `StartExecution` で実行を始め、本文のない 200 を返す

実行を始められたときは、Lambda は何も表示しません。受け付けは、状態機械がチャンネルに投稿します。使い方や、受け付けられなかった理由は、`response_type` を `ephemeral` にして、打った人にだけ見せます。

二重の開始は 6 の確認で防ぎます。応答が 3 秒を超えると、Slack は利用者にエラーを表示するので、利用者が打ち直すことがあります。そのとき、1 回目の実行が `RunInstances` の前なら、2 回目の実行も「踏み台はない」と判断し、踏み台が 2 台できます。Standard の実行名が重複を防ぐのは名前と入力が同じ呼び出しだけで、打ち直したコマンドは別のリクエストになるため、実行名ではこれを防げません。

なお、`ListExecutions` は結果整合なので、数秒以内に続けて打つと、すり抜ける可能性は残ります。個人で使う踏み台なので、この可能性は受け入れます。start の実行中は stop も受け付けず、待つように返します。

実行名は調べるときに見分けやすいように、`<start か stop>-<user_id>-<タイムスタンプ>` の形にします。CloudWatch Logs で扱えるよう、英数字と `-`、`_` だけで作ります。

Lambda は TypeScript で書き、ランタイムは `nodejs24.x` を使います。`nodejs26.x` は、2026 年 11 月の時点でプレビュー版で、本番には使わないようドキュメントに書かれているためです。Node.js 24 ではコールバック形式のハンドラーが使えないので、`async` で書きます。

- コードは `terraform/bastion-ec2-slackops/lambda/` に置く。この Lambda は slackops でしか使わないためである
- ビルド、テスト、Lint、フォーマットは Vite+ にまとめ、設定は `vite.config.ts` に書く。`pnpm run check` で、フォーマットと Lint を確かめる
- `pnpm run build`（`vp pack`）で、tsdown が `dist/index.mjs` の 1 ファイルを作る。Terraform の `archive_file` がそれを zip にし、`aws_lambda_function` の `code_sha256` に zip のハッシュを渡す。Terraform はビルドをしないので、ビルドは Terraform の外で行う
- 本番の依存は持たない。コードは I/O を持たずにコマンドの扱いを決める `slack-command.ts` と、AWS を呼ぶ `index.ts` の 2 ファイルにする。テストは `slack-command.ts` に対して書く
- AWS SDK はランタイムに入っているものを使い、zip に含めない
- Powertools for AWS Lambda（TypeScript）のうち、Parameters と Logger を使う。Signing Secret は Parameters で読み、5 分キャッシュする。ログは Logger で JSON にする
- Powertools は、AWS が公開している Lambda レイヤーで読み込む。ビルドでは `@aws-lambda-powertools/*` を同梱の対象から外し、手元では `devDependencies` に入れる。レイヤーの版は番号を固定で書き、上げるときは `devDependencies` の版も一緒に上げる。レイヤーで Parameters と Logger が動くことは、実機で確かめた
- 手元の Node.js と pnpm の版は、`mise.toml` で Lambda のランタイムにそろえる

### Step Functions の状態機械

Step Functions は Standard にします。踏み台の初期化に 2〜3 分かかり、準備完了を待つ時間が加わるため、最大 5 分の Express では余裕がありません。実行履歴は 90 日間残り、失敗の調査に使えます。

状態機械は EC2 と Slack を直接呼びます。AWS SDK 統合で `RunInstances` と `TerminateInstances` などを呼び、HTTP Task で Slack の `chat.postMessage` を呼びます。処理用の Lambda は要りません。

踏み台があるかは、`Role=bastion` タグのインスタンスのうち、`terminated` 以外のものがあるかで判断します。`shutting-down` のものは「終了中」として扱います。

どちらのコマンドでも、最初に「`/bastion start` を受け付けました」のような親の投稿を、実行した人へのメンションを付けてチャンネルに出します。以降の投稿は、すべてそのスレッドに返信します。

`/bastion start` の流れは次のとおりです。

1. 踏み台を探す。動いているものがあれば「すでに起動しています」、終了中のものがあれば「少し待ってから」と返信して終える
2. `ClientToken` を付けて `RunInstances` を呼ぶ
3. サーバー ID を入れて「踏み台サーバーを起動しています」と返信する
4. 60 秒待ってから、15 秒おきに、インスタンスの状態と公開 IP を `DescribeInstances` で確かめる
5. 公開 IP が EIP の IP になれば、準備完了を投稿する。EIP は、初期化を終えた踏み台が自分で関連付けるため
6. 準備完了の前にインスタンスが終了したら、その旨を投稿する。理由ごとには分けない
7. 起動から 5 分を超えても準備完了にならなければ、`TerminateInstances` を呼び、その旨を投稿する

`/bastion stop` の流れは次のとおりです。

1. 踏み台を探す。なければ「起動中の踏み台サーバーはありません」、終了中なら「踏み台サーバーは終了中です」と返信して終える
2. サーバー ID を入れて「踏み台サーバーを終了しています」と返信し、`TerminateInstances` を呼ぶ
3. 15 秒おきに状態を確かめ、`terminated` になったら「終了しました。」と投稿する
4. 5 分を超えても `terminated` にならなければ、その旨を投稿する

Step Functions は `Retry` を書かなければ再試行しないので、各 Task に `Retry` を明示し、一時的なエラーだけを、最大 3 回、倍々の間隔で再試行します。踏み台の作り直しはしません。

Slack への投稿に失敗したら、その場で実行を失敗として止めます。サーバー ID を入れるため、「起動しています」は `RunInstances` のあとに投稿します。この投稿に失敗したときは、利用者に知らせないまま踏み台が動き続けないよう、作った踏み台を終了させてから止めます。`chat.postMessage` を呼ぶたびに、応答の `ok` を確かめます。

準備完了にならなかったときや、API のエラーで止まったときは、通知のあと、実行を失敗で終えます。スレッドにサーバー ID があるので、実行の履歴とあわせて調べられます。

状態機械は起動と終了で同じ形のところをまとめ、状態を少なく保ちます。踏み台を探す処理は 1 つにし、そのあとの判断で起動と終了に分けています。失敗したときは、理由を変数に入れてから、起動と終了で共通の「できませんでした」の投稿と、1 つの Fail 状態に進みます。すでに起動している、踏み台がない、のように何もせずに終わる場面も、振り分けで文言を変数に入れ、1 つの投稿にまとめます。

同時に 1 台までという制限は、EIP の関連付けと、起動中の踏み台の確認で守ります。実行ロールの権限は次のとおりです。

| 権限 | 用途と条件 |
|---|---|
| `ec2:RunInstances` | 踏み台の起動。`ec2:LaunchTemplate` と `ec2:IsLaunchTemplateResource=true` の条件で、`bastion-ec2` の Launch Template からの起動に限る |
| `ec2:CreateTags` | 起動時のタグ付け。`ec2:CreateAction=RunInstances` のときだけ |
| `iam:PassRole` | 踏み台のロールを渡す。対象は踏み台のロールだけで、`iam:PassedToService=ec2.amazonaws.com` の条件を付ける |
| `ssm:GetParameters` | Launch Template の `resolve:ssm` で AMI を解決する。対象は `/aws/service/ami-amazon-linux-latest/*` だけ |
| `ec2:DescribeInstances` | 踏み台の状態と、公開 IP の確認 |
| `ec2:TerminateInstances` | 踏み台の終了。`ec2:ResourceTag/Role=bastion` のものだけ |
| `states:InvokeHTTPEndpoint` | HTTP Task の呼び出し。自分の状態機械からの、Slack の URL への POST に限る |
| `events:RetrieveConnectionCredentials` | 接続からトークンを取り出す。対象は自分の接続だけ |
| `secretsmanager:GetSecretValue`、`secretsmanager:DescribeSecret` | 接続のシークレットの読み出し。対象は `events!connection/*` のシークレット |

`ec2:LaunchTemplate` と `ec2:IsLaunchTemplateResource` の条件は、Launch Template の `resolve:ssm` で AMI を解決する起動と組み合わせても、許可されることを実機で確かめました。

### Slack のトークン

HTTP Task は EventBridge の接続を通して Slack の Bot トークンを使います。トークンは、接続が Secrets Manager に暗号化して保管します。接続が作るシークレットは、自分で用意したものに差し替えられません。

HTTP Task の定義には `Authorization` ヘッダーを書けません。書くと実行時にエラーになります。そこで、接続を API Key 方式にし、キーの名前を `Authorization`、値を `Bearer <トークン>` にします。この形で Slack に投稿できることは、実機で確かめました。

Terraform の state には、リソースの引数に渡した値が、そのまま残ります。変数や環境変数で渡しても同じです。この接続には write-only の引数がないため、本物のトークンは Terraform に渡しません。次の手順にします。

1. Terraform が接続を仮の値（ダミー）で作る。state に残るのは、ダミーだけ
2. 人が AWS CLI の `update-connection` で、トークンを本物に更新する
3. 接続の `auth_parameters` 全体に、`lifecycle` の `ignore_changes` を付ける

AWS プロバイダのソースを確かめたところ、接続を読み込むときは、AWS の API が値を返さないので、トークンの値を state から引き継ぎます。そのため、本物に更新したあとも plan は空になります。

一方、接続を更新するときは、`auth_parameters` を毎回まるごと送ります。ほかの項目を変えて接続が更新されると、本物のトークンがダミーで上書きされます。これを避けるため、`description` などの任意の項目は設定しません。もし上書きされたら、トークンを登録し直します。

接続は Terraform が作るので、`terraform destroy` で一緒に消えます。`ignore_changes` を外すと、次の apply でトークンがダミーに戻り、Slack に投稿できなくなるので、この理由をコードのコメントに書きます。

### Slack の秘密情報の登録

Slack の秘密情報は 2 つあり、どちらも Terraform の外で登録します。

| 秘密情報 | 置き場所 |
|---|---|
| Signing Secret | SSM Parameter Store の SecureString（`/${resource_prefix}/slack-signing-secret`） |
| Bot トークン | EventBridge の接続（中身は Secrets Manager） |

登録には `scripts/setup-slack-secrets.sh` を用意します。書き方は Phase 1 の `scripts/setup-ssm-parameters.sh` にそろえます。

- 2 つの値を、画面に表示せずに入力させる（`read -s`）
- 値は権限 600 の一時ファイルを通して AWS CLI に渡す。コマンドの引数に値を入れないので、シェルの履歴や `ps` に残らない。一時ファイルは終了時に消す
- トークンに `Bearer ` を付ける処理と、パラメータ名と接続名の組み立ても、スクリプトで行う

Lambda が Signing Secret を読むのは、呼ばれたときです。そのため、登録は `terraform apply` のあとで構いません。

### 結果の知らせ方

コマンド 1 回につき、チャンネルに出すのは状態機械の親の投稿 1 件だけです。スラッシュコマンドはメッセージとして残らず、Lambda の応答にも投稿の ID（`ts`）がないので、どちらにもスレッドを付けられません。そこで、状態機械が「受け付けました」を親として投稿し、経過も結果も、そのスレッドに返信します（`thread_ts`）。打ったコマンドはチャンネルに残らないので、親の投稿に、実行した人へのメンションを入れます。

利用者は AWS に詳しくない前提なので、文言に AWS の言葉は使いません。インスタンス ID は「サーバー ID」と呼びます。投稿は太字の見出し、「•」で始まる項目、補足の文の順に書きます。

親の投稿は、`/bastion start` と `/bastion stop` のどちらでも同じ形です。

| 見出し | 項目 |
|---|---|
| `/bastion start` を受け付けました（stop も同じ形） | 実行した人（メンション） |

スレッドの返信は、次のとおりです。

| 場面 | 見出し | 項目と補足 |
|---|---|---|
| 起動を始めた | 踏み台サーバーを起動しています | サーバー ID。準備ができるまで 1〜2 分かかります。 |
| 準備完了 | 準備ができました | 接続できます。 |
| すでにある | 踏み台サーバーはすでに起動しています | サーバー ID |
| 前の踏み台が終了中 | 前の踏み台サーバーが終了するのを待っています | 少し待ってから、もう一度実行してください。 |
| 準備の前に終了した | 起動できませんでした | 理由（初期化に失敗し、自動で終了しました）。管理者に連絡してください。 |
| 5 分を超えた（起動） | 起動できませんでした | 理由（5 分以内に準備ができなかったため、終了しました）。管理者に連絡してください。 |
| エラー（起動） | 起動できませんでした | 理由（エラーが起きました）。管理者に連絡してください。 |
| 終了を始めた | 踏み台サーバーを終了しています | サーバー ID |
| 終了した | 終了しました | なし |
| ない | 起動中の踏み台サーバーはありません | なし |
| すでに終了中 | 踏み台サーバーは終了中です | サーバー ID |
| 5 分を超えた（終了） | 終了できませんでした | 理由（5 分以内に終了しませんでした）。管理者に連絡してください。 |
| エラー（終了） | 終了できませんでした | 理由（エラーが起きました）。管理者に連絡してください。 |

状態機械を動かさない場面では、Lambda が打った人にだけ見える応答を返します。スレッドは作りません。

| 場面 | 文言 |
|---|---|
| 引数がない・知らない引数 | 使い方の見出しと、`/bastion start` と `/bastion stop` の項目 |
| 前の処理が動いている | 前の起動または終了が終わっていません。終わってから、もう一度実行してください。 |
| Step Functions を呼べない | エラーのため、受け付けられませんでした。管理者に連絡してください。 |

### 終了の方法

Phase 1 では、管理者が CLI で終了します。Phase 2 では `/bastion stop` を打ちます。最大寿命の shutdown も、接続の有無を見るアイドル判定も入れません。接続を開いたままにすると踏み台は残り続けますが、この終了の打ち忘れは考慮しません。必要になった時点で、User Data に足せます。

### state の保存先

state は S3 バケットに置き、ロックは S3 だけで行います（`use_lockfile`）。DynamoDB は使いません。1 つのバケットを、構成ごとのキー（`ephemeral-bastion-ec2/<構成名>/terraform.tfstate`）で分けて使います。バケット名などの値は、`backend.hcl` に書いて、`terraform init -backend-config=backend.hcl` で渡します。アカウント ID を、リポジトリに残さないためです。バケットは `bootstrap` の Terraform で作ります。最初はローカル state で作り、そのあとバケットを保存先に設定して state を移します。これが一般的な手順です。

### sample-db（検証用の DB）

RDS for PostgreSQL 18.6（版を固定し、マイナーバージョンの自動更新は止める）、`db.t4g.micro`、シングル AZ、gp3 の 20 GB とします。ストレージは暗号化し、パブリックアクセスは無効にします。削除保護、最終スナップショット、自動バックアップは付けません。`terraform destroy` ですぐ消せることを最優先にするためです。

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
| `lambda/` | Lambda のコード、`package.json`、`tsconfig.json`（`bastion-ec2-slackops` のみ）。ビルドの出力 `dist/` は git に入れない |
| `terraform.tfvars.example` | 変数の記入例 |

リソース名は `${var.resource_prefix}-<役割>` とし、`resource_prefix` の既定値は `ephemeral-bastion` です。ただし、state 用のバケットは、ほかのプロジェクトと共有できるよう、接頭辞を付けず、`tfstate-<アカウント ID>` とします。リージョンは `ap-northeast-1` に固定し、変数にしません。

`bastion-ec2-slackops` の変数は `resource_prefix`（既定値は `ephemeral-bastion`。`bastion-ec2` と同じ値にする）と、`slack_channel_id`（専用チャンネルの ID。必須）の 2 つです。チャンネル ID は secret ではありませんが、`.gitignore` に入れた `terraform.tfvars` に書きます。Signing Secret のパラメータ名、Powertools のレイヤーの版、準備完了を待つ時間と確認の間隔は、変える予定がないので `locals` に書きます。

出力は次の 4 つで、どれも secret ではありません。

| 出力 | 使い道 |
|---|---|
| `function_url` | Slack アプリの設定で、スラッシュコマンドの Request URL に貼る |
| `connection_name` | `update-connection` で、Bot トークンを登録するときに指定する |
| `state_machine_arn` | 実行の履歴を調べるときに使う |
| `signing_secret_parameter_name` | Signing Secret を登録するときに指定する |

## 利用者の動線

初回だけ、管理者が DB クライアントの SSH トンネル設定（ホスト、ユーザー `tunnel`、秘密鍵、転送先 DB）を配ります。

| 手順 | Phase 1（CLI） | Phase 2（Slack） |
|---|---|---|
| 起動の依頼 | 管理者に依頼し、管理者が CLI で起動する | 専用チャンネルで `/bastion start` を打つ |
| 準備完了の確認 | 2〜3 分後に接続を試す。つながれば準備完了 | 「準備ができました」の投稿を待つ |
| 利用 | DB クライアントで接続する | 同左 |
| 終了 | 管理者が `terminate-instances` で削除する | 専用チャンネルで `/bastion stop` を打つ |

## 段階的な進め方

1. Phase 1（`bastion-ec2`）：Terraform と User Data。管理者が CLI で起動と終了を行う
2. Phase 2（`bastion-ec2-slackops`）：Slack のスラッシュコマンドで、起動と終了を行う

## 見送った案

| 案 | 見送った理由 |
|---|---|
| `bastion-ec2` の起動を、Step Functions で行う | `RunInstances` 1 回で足りる。Step Functions は、Slack 連携でだけ使う |
| ENI を使い回し、EIP を ENI に固定する | シンプルだが、ENI を残したくない |
| 外部から `AssociateAddress` を呼ぶ | 起動が複数ステップになり、タグ検索による多重起動の判定に競合がある。初期化の完了前に EIP が付いてしまう |
| SSH ホスト証明書 | 署名鍵の管理が別に必要。Windows の DB クライアント内蔵 SSH が対応していないことが多い（Mac のクライアントは未確認） |
| 最大寿命とアイドル判定による自動終了 | 仕組みを増やさない。終了は、管理者の CLI か、Slack の `/bastion stop` で行う |
| 一時パブリック IP をなくす VPC エンドポイント構成 | 構成が重くなる |
| `manage_master_user_password` | ローテーションを止めると、Secrets Manager を使う利点が薄い |
| `terraform_remote_state` で、`sample-db` の出力を `bastion-ec2` に渡す | 手持ちの DB で使う人が、`sample-db` なしで `bastion-ec2` を使えなくなる |
| Amazon Q Developer in chat applications（旧 AWS Chatbot）のカスタムアクション | ボタンは通知に付く形で、専用チャンネルへの常設が確認できなかった。通知が流れると、ボタンを押せなくなる恐れがある |
| Slack の通知を受ける Lambda と、EC2 を操作する Lambda の 2 つ | EC2 と Slack は、Step Functions の AWS SDK 統合と HTTP Task で直接呼べるため、処理側の Lambda は要らない |
| Lambda が自分自身を非同期で呼ぶ | 公開される Lambda に EC2 の権限を持たせることになる。再帰呼び出しの自動検出も、この形は対象にしていない |
| Lambda の中で準備完了を待つ | 待つ、分岐する、失敗を通知するという流れは、Step Functions で表すほうが素直 |
| EventBridge と CloudTrail のイベントによる準備完了の検出 | EIP の関連付けは EC2 の状態変化ではなく、CloudTrail 経由になり、EventBridge のルールも増える |
| Step Functions の Express | 最大 5 分の上限に近づく恐れがある。重複した開始を防ぐ仕組みもない |
| 許可する Slack ユーザー ID を変数で持つ | 人が増減するたびに、Terraform を直すことになる |
| Slack のトークンを、変数で渡して state に残す | 変数や環境変数で渡しても、state にトークンが残る。AGENTS.md の方針に反する |
| Slack のトークンを SSM に置き、通知用の Lambda で投稿する | Lambda が増える。HTTP Task で足りる |
| EventBridge の接続を、Terraform の外で作る | 手作業が増え、`terraform destroy` でも消えない |
| Workflow Builder のワークフローを、チャンネルのブックマークから起動する | 有料プランが前提で、無料プランでは試せない |
| ボタン付きのメッセージを、専用チャンネルにピン留めする | ボタンのメッセージを置く仕組みが要る。スラッシュコマンドなら、置いておくメッセージが要らない |
| プライベートチャンネルのメンバーだけが操作する | 隠す必要のある操作ではない |
| 打ったコマンドや Lambda の応答のスレッドに、経過を返信する | スラッシュコマンドはメッセージとして残らず、Lambda の応答にも投稿の ID がないので、スレッドを付けられない |
| Lambda の応答をチャンネルの全員に見せる（in_channel） | 打ったコマンドと応答が、親の投稿とは別にチャンネルに並び、ノイズになる |
| 最後の結果を、スレッドに加えてチャンネルにも表示する（reply_broadcast） | 1 回のコマンドで、チャンネルの投稿が増える |
| 準備完了の確認を、指数的に間隔を広げて行う | 60 秒待ったあと、15 秒おきに確かめれば足りる |
| コールバック型（タスクトークン）で準備完了を待つ | 踏み台から Step Functions を呼ぶ仕組みと権限が要る |
| 起動に失敗したら、踏み台を作り直して再試行する | 再試行は、API の一時的なエラーだけにする |
| 実行名だけで、二重の開始を防ぐ | 名前と入力が同じ呼び出ししか防げない。打ち直したコマンドは別のリクエストになる |
| DynamoDB のロックや Powertools の Idempotency で、二重の開始を完全に防ぐ | DynamoDB のテーブルが増える。個人で使う踏み台では、`ListExecutions` の確認で足りる |
| Lambda の同時実行数に上限を付ける | 今回は考慮しない |
| Lambda を Python で書く | ふだん書いている TypeScript にそろえる |
| Lambda のランタイムに `nodejs26.x` を使う | 2026 年 11 月の時点でプレビュー版。正式版になったら上げる |
| SAM CLI と Terraform を併用する | 得られるのは手元での実行だけで、ビルドの処理は自分で書く。Docker も要る。署名やチャンネルの確認は、単体テストで確かめられる |
| Terraform の中でビルドも実行する（`local-exec`） | plan のときにはビルドが実行されないなど、順番の扱いがややこしい |
| Powertools の Parser、Event Handler、Tracer、Metrics | 本文はフォーム形式で、署名の確認より後に分解する。受け付ける URL は 1 つで、振り分けが要らない。処理が短く、トレースやメトリクスまでは要らない |
| Powertools を zip に同梱する | AWS が公開しているレイヤーで足りる。zip には自分のコードだけを入れる |
| Powertools のレイヤーの版を、公開の SSM パラメータで最新に追従させる | 新しい版が出るたびに plan に差分が出て、手元の `devDependencies` の版ともずれる |
| `terraform_remote_state` で、`bastion-ec2` の出力を `bastion-ec2-slackops` に渡す | `bastion-ec2` に出力を追加する必要があり、state 全体を読む権限も要る |
| zod で、スラッシュコマンドの本文の項目を確かめる | 確かめるのは 3 つの項目があるかと、空でないかだけで、数行で書ける。zod を入れると、ビルドしたファイルが 10 KB 程度から数百 KB に増える |
| neverthrow で、想定される失敗を返す | Lambda の本番の依存は少ないほうがよい。失敗の扱いは、扱いの種類を表す型と、AWS を呼ぶ箇所の `try`/`catch` で足りる |
| 署名の確認、本文の分解、判断、AWS の呼び出しを、それぞれ別のファイルに分ける | 処理が短く、分けると読む場所が増えるだけになる |
| `bastion-ec2` の値を、`terraform.tfvars` に手で書く | `bastion-ec2` を作り直して ID が変わると、手で直すことになる |
| 秘密情報の登録を、README の AWS CLI のコマンドだけで行う | 値をコマンドに直接書くと、シェルの履歴に残る |

## 未確定の事項

- 利用者が使う DB クライアント（A5:SQL Mk-2、DBeaver、HeidiSQL など）の内蔵 SSH が、known_hosts をどう扱うか。Windows と Mac の両方で確かめる
- `ForceCommand /bin/false` を設定しても、DB クライアントのトンネルが動くか。`ssh -N -L` では動くことを確かめた。DB クライアントの内蔵 SSH では、実機で確かめる
- 専用チャンネル以外で空の 200 を返したとき、Slack に何が表示されるか。実機で確かめる
