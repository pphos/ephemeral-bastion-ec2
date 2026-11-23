# ephemeral-bastion-ec2

使い捨ての踏み台 EC2 を Terraform で管理します。踏み台は必要なときだけ起動し、使い終わったら Terminate します。利用者は手元の DB クライアントから SSH トンネルで、AWS 内の DB に接続します。

起動と終了は、Phase 1 では管理者が AWS CLI で行い、Phase 2 では Slack のスラッシュコマンド `/bastion start` と `/bastion stop` で行います。設計の判断と理由は [docs/design.md](docs/design.md) にまとめています。

## 構成

| ディレクトリ | 中身 |
|---|---|
| `terraform/bastion-ec2` | Phase 1。踏み台の EIP、Security Group、IAM ロール、Launch Template など |
| `terraform/bastion-ec2-slackops` | Phase 2。スラッシュコマンドを受ける Lambda、Step Functions、Slack への投稿に使う EventBridge の接続 |
| `terraform/examples/sample-db` | 任意。DB を持たない人が試すための RDS for PostgreSQL |
| `terraform/examples/bootstrap` | 任意。state を置く S3 バケット |
| `scripts/setup-ssm-parameters.sh` | 踏み台の SSH ホスト鍵と、利用者の公開鍵を SSM に置く |
| `scripts/setup-slack-secrets.sh` | Slack の Signing Secret と Bot トークンを登録する |

リージョンは `ap-northeast-1` に固定しています。リソース名の接頭辞は変数 `resource_prefix`（既定値は `ephemeral-bastion`）で変えられます。変えるときは、すべての構成とスクリプトで同じ値にしてください。スクリプトでは環境変数 `RESOURCE_PREFIX` で指定します。

## 準備

Terraform、Node.js、pnpm のバージョンは `mise.toml` で固定しています。リポジトリの直下で、次を実行します。

```bash
mise install
```

AWS の認証情報は環境変数かプロファイルで設定しておきます。以下のコマンドは、どれもその認証情報で実行します。

### Claude Code から AWS を操作する

Claude Code は、Agent Toolkit for AWS の `aws-core` プラグインに同梱の AWS MCP を通して AWS を操作します。同梱の AWS MCP は、`default` プロファイルの認証情報で動きます。

同梱の AWS MCP のエンドポイントは us-east-1 にあり、`default` プロファイルのリージョンを、リクエストの署名に使います。`default` のリージョンを `us-east-1` 以外にすると、リクエストが 401 で拒否されます。操作するリソースのリージョンは、呼び出しごとに指定するので、`default` のリージョンとは関係ありません。

`default` が IAM Identity Center（SSO）のプロファイルなら、トークンの期限が切れると AWS を操作できなくなります。`aws sso login` でログインし直してから、Claude Code の `/mcp` で AWS MCP を再接続してください。

### state の保存先

state は S3 バケット `tfstate-<アカウント ID>` に、構成ごとのキーで置きます。バケットは `terraform/examples/bootstrap` で作ります。

各構成では `backend.hcl.example` を `backend.hcl` にコピーし、`<アカウント ID>` を書き換えてから、次のように初期化します。`backend.hcl` は `.gitignore` に入っているので、アカウント ID はリポジトリに残りません。

```bash
terraform init -backend-config=backend.hcl
```

## Phase 1: bastion-ec2

### 1. 接続先の DB を用意する

手持ちの DB を使うなら、その DB のホスト名、ポート、Security Group の ID を控えます。DB がなければ、`terraform/examples/sample-db` で検証用の RDS を作れます。`terraform.tfvars.example` を `terraform.tfvars` にコピーして、VPC とプライベートサブネットの ID を書きます。

マスターパスワードは write-only の引数で渡すので、state には残りません。シェルの履歴にも残らないよう、画面に表示せずに環境変数へ読み込んでから apply します。

```bash
cd terraform/examples/sample-db
read -rs TF_VAR_db_password && export TF_VAR_db_password
terraform init -backend-config=backend.hcl
terraform apply
```

出力の `db_host`、`db_port`、`db_security_group_id` を、次の手順で `bastion-ec2` の変数に使います。

### 2. SSH の鍵を SSM に置く

利用者の公開鍵のファイルを渡して、スクリプトを実行します。SSH のホスト鍵がなければ生成して置き、利用者の公開鍵は上書きで置きます。利用者を足したり外したりするときも、同じスクリプトを実行し直します。Terraform を apply し直す必要はありません。

```bash
scripts/setup-ssm-parameters.sh alice.pub bob.pub
```

### 3. Terraform で作る

`terraform/bastion-ec2/terraform.tfvars.example` を `terraform.tfvars` にコピーして、値を書き換えます。`allowed_cidrs` には、SSH を許可する接続元の IP を書きます。個人の IP が入るので、`terraform.tfvars` は `.gitignore` に入れてあります。

```bash
cd terraform/bastion-ec2
terraform init -backend-config=backend.hcl
terraform plan
terraform apply
```

出力の `launch_template_id` は起動に、`eip_public_ip` は利用者の接続先に使います。

### 4. 起動と終了（管理者）

起動は Launch Template を指定して、`run-instances` を 1 回実行します。初期化が終わると、踏み台が自分で EIP を付けます。初期化に失敗した踏み台は、EIP を付けずに自分で Terminate します。

```bash
aws ec2 run-instances --region ap-northeast-1 --launch-template LaunchTemplateId=<launch_template_id>
```

終了は `Role=bastion` タグの踏み台を探して、Terminate します。

```bash
aws ec2 describe-instances --region ap-northeast-1 \
  --filters Name=tag:Role,Values=bastion Name=instance-state-name,Values=pending,running \
  --query 'Reservations[].Instances[].InstanceId' --output text
```

```bash
aws ec2 terminate-instances --region ap-northeast-1 --instance-ids <インスタンス ID>
```

失敗の原因は CloudWatch Logs のロググループ（出力の `log_group_name`）で調べられます。User Data の実行ログと sshd のログが、インスタンス ID ごとに残ります。

### 5. 利用者の接続

利用者はユーザー `tunnel` と自分の秘密鍵で、踏み台の EIP にポート `2222`（変数 `ssh_port`）で接続し、DB へのポートフォワードだけを使います。シェルには入れません。転送先は `bastion-ec2` の変数 `db_host` と同じ名前にしてください。sshd は転送先を文字列のまま比べるので、IP アドレスや別名では拒否されます。

ssh コマンドなら、次のようになります。DB クライアントの SSH トンネルの設定にも、同じ値を入れます。

```bash
ssh -N -L 15432:<db_host>:5432 -p 2222 -i <秘密鍵> tunnel@<eip_public_ip>
```

この例では DB クライアントから `localhost:15432` に接続します。`-L` の指定で、手元の 15432 番への接続が、SSH の接続の中を通って踏み台まで運ばれ、踏み台から DB の 5432 番に届きます。DB はプライベートサブネットにあり、踏み台からの接続だけを受け付けるので、手元から直接はつなげません。手元の番号は、空いていれば何番でも構いません。

### 6. DB に接続できるかを確かめる

踏み台の準備ができたあと、手元からトンネルを通って DB にログインできるかを確かめます。psql は、Homebrew の libpq に入っています。

```bash
brew install libpq
```

ターミナルを 2 つ使います。1 つ目のターミナルでトンネルを張ります。何も表示されずに止まったままになれば、トンネルが張れています。

```bash
ssh -N -L 15432:<db_host>:5432 -p 2222 -i <秘密鍵> tunnel@<eip_public_ip>
```

2 つ目のターミナルで、psql からログインします。パスワードを聞かれたら、DB のパスワード（`sample-db` なら、作ったときのマスターパスワード）を入力します。

```bash
$(brew --prefix libpq)/bin/psql -h localhost -p 15432 -U postgres -d postgres -c 'select version();'
```

`PostgreSQL 18.6 on ...` のような行が返れば、踏み台を通って DB にログインできています。確かめ終わったら、1 つ目のターミナルを `Ctrl+C` で止めます。

つながらないときは、エラーの文で原因を絞れます。

| エラー | 考えられる原因 |
|---|---|
| ssh で `Connection timed out` | 手元の IP が、`allowed_cidrs` に入っていない |
| ssh で `Connection refused` | 踏み台がまだ準備中か、すでに終了している |
| ssh で `Permission denied (publickey)` | 秘密鍵が、登録した公開鍵と対になっていない |
| psql がつながらず、1 つ目のターミナルに `open failed: administratively prohibited` | ssh の転送先が `db_host` の名前と一致せず、踏み台が転送を拒否した |
| psql で `password authentication failed` | DB のユーザー名かパスワードが違う |

## Phase 2: bastion-ec2-slackops

Phase 1 の `bastion-ec2` を作ってから進めます。`bastion-ec2-slackops` は、`bastion-ec2` の Launch Template、EIP、踏み台の IAM ロールを、名前とタグで引きます。

### 1. Slack アプリを作り、専用チャンネルを用意する

1. Slack の API サイト（api.slack.com/apps）で、ワークスペースに新しいアプリを作る
2. OAuth & Permissions の Bot Token Scopes に `commands` と `chat:write` を足し、ワークスペースにインストールする
3. 専用のパブリックチャンネルを作り、アプリを招待する
4. チャンネルの詳細の下にある、チャンネル ID（`C` から始まる値）を控える

Bot トークン（`xoxb-` から始まる値）と、Basic Information の Signing Secret は、手順 4 で登録します。メモに書き写さないでください。

### 2. Lambda をビルドする

Terraform はビルドをしません。apply の前に、Lambda を JavaScript の 1 ファイルにビルドしておきます。ビルド、テスト、Lint、フォーマットは Vite+ で行います。

```bash
cd terraform/bastion-ec2-slackops/lambda
pnpm install
pnpm run check
pnpm run typecheck
pnpm test
pnpm run build
```

`dist/index.mjs` ができます。Terraform はこれを zip にしてデプロイします。フォーマットと Lint の指摘は、`pnpm run fix` で直せるものは直せます。

### 3. Terraform で作る

`terraform.tfvars.example` を `terraform.tfvars` にコピーし、`slack_channel_id` に、手順 1 で控えたチャンネル ID を書きます。

```bash
cd terraform/bastion-ec2-slackops
terraform init -backend-config=backend.hcl
terraform plan
terraform apply
```

### 4. Slack の秘密情報を登録する

スクリプトを実行し、Signing Secret と Bot トークンを入力します。入力した値は画面に表示されず、シェルの履歴にも残りません。空のまま Enter を押した項目は変わらないので、片方だけを登録し直すこともできます。

```bash
scripts/setup-slack-secrets.sh
```

Bot トークンは、Terraform がダミーの値で作った EventBridge の接続に登録します。Terraform はこの値の変更を無視するので、apply し直しても、本物のトークンは上書きされません。

### 5. スラッシュコマンドを登録する

Slack アプリの Slash Commands で、コマンド `/bastion` を作ります。Request URL には `terraform output -raw function_url` の値を貼ります。使い方のヒントには `start | stop` と書いておくと、利用者が迷いません。

### 6. 試す

専用チャンネルで `/bastion start` を打ちます。チャンネルに「`/bastion start` を受け付けました」の投稿が出て、そのスレッドに「踏み台サーバーを起動しています」と、1〜2 分後に「準備ができました」が入ります。準備ができたら、Phase 1 の「DB に接続できるかを確かめる」の手順で、DB まで届くかを確かめます。使い終わったら `/bastion stop` を打ちます。

うまく動かないときは、次の場所を見ます。

- Lambda のログ: CloudWatch Logs の `/aws/lambda/<resource_prefix>-slack-command`
- 状態機械の実行の履歴: Step Functions のコンソールで、出力の `state_machine_arn` の状態機械を開く。失敗した実行には、止まった状態の名前とエラーの内容が残る

### Lambda のコードを変えたとき

ビルドしてから plan と apply をします。ビルドを忘れると、古いコードのまま plan されます。

```bash
cd terraform/bastion-ec2-slackops/lambda
pnpm run check
pnpm run typecheck
pnpm test
pnpm run build
cd ..
terraform plan
terraform apply
```

### Powertools のバージョンを上げるとき

Powertools for AWS Lambda は、AWS が公開している Lambda レイヤーで読み込みます。バージョンを上げるときは、`main.tf` の `powertools_layer_arn` のレイヤーの番号と、`lambda/package.json` の `@aws-lambda-powertools/*` のバージョンを一緒に上げます。

## 片付け

作った順の逆で destroy します。`bastion-ec2-slackops` は `bastion-ec2` のリソースを名前で引くので、先に消します。踏み台が起動していれば、先に終了しておきます。

```bash
cd terraform/bastion-ec2-slackops
terraform destroy
```

```bash
cd terraform/bastion-ec2
terraform destroy
```

Terraform の外で作った SSM パラメータは、destroy では消えません。要らなくなったら、`/<resource_prefix>/host-key`、`/<resource_prefix>/user-public-keys`、`/<resource_prefix>/slack-signing-secret` を消してください。
