#!/bin/bash
#
# bastion-ec2-slackops が使う Slack の Signing Secret と Bot トークンを登録する。
# 値はコマンドの引数に入れず、シェルの履歴や ps に残さない。空のまま Enter を押した項目は変えない。
#
# 使い方: setup-slack-secrets.sh
# リソース名の接頭辞は、環境変数 RESOURCE_PREFIX で変えられる。
# AWS の認証情報は、環境変数やプロファイルで、あらかじめ設定しておく。

set -Eeuo pipefail

readonly REGION="ap-northeast-1"
readonly PREFIX="${RESOURCE_PREFIX:-ephemeral-bastion}"
readonly SIGNING_SECRET_PARAMETER="/$PREFIX/slack-signing-secret"
readonly CONNECTION_NAME="$PREFIX-slack"

# 秘密情報を置く一時ディレクトリ。終了時に消す
WORKDIR="$(mktemp -d)"
readonly WORKDIR

#######################################
# エラーメッセージを、標準エラー出力に書く。
# Arguments:
#   メッセージ
#######################################
err() {
  echo "ERROR: $*" >&2
}

#######################################
# 一時ディレクトリを消す。EXIT トラップから呼ばれる。
# Globals:
#   WORKDIR
#######################################
cleanup() {
  rm -rf "$WORKDIR"
}

#######################################
# 画面に表示せずに、値を 1 行読む。
# Arguments:
#   プロンプト
# Outputs:
#   入力された値
#######################################
read_secret() {
  local value
  read -r -s -p "$1: " value
  echo >&2
  printf '%s' "$value"
}

#######################################
# Signing Secret を、SSM パラメータに上書きで置く。
# Globals:
#   REGION
#   WORKDIR
#   SIGNING_SECRET_PARAMETER
# Arguments:
#   Signing Secret
#######################################
put_signing_secret() {
  if [[ ! "$1" =~ ^[0-9a-f]+$ ]]; then
    err "Signing Secret は、英小文字と数字だけの値です。Slack アプリの Basic Information の値を確かめてください"
    exit 1
  fi

  umask 077
  printf '%s' "$1" > "$WORKDIR/signing_secret"
  aws ssm put-parameter --region "$REGION" \
    --name "$SIGNING_SECRET_PARAMETER" \
    --type SecureString \
    --overwrite \
    --value "file://$WORKDIR/signing_secret" > /dev/null
  echo "Signing Secret を置きました: $SIGNING_SECRET_PARAMETER"
}

#######################################
# 接続の API Key を、Bot トークンに更新する。
# HTTP Task は Authorization ヘッダーを書けないので、キーの名前を Authorization、
# 値を「Bearer <トークン>」にする。
# Globals:
#   REGION
#   WORKDIR
#   CONNECTION_NAME
# Arguments:
#   Bot トークン
#######################################
update_bot_token() {
  if [[ ! "$1" =~ ^xoxb-[A-Za-z0-9-]+$ ]]; then
    err "Bot トークンは xoxb- で始まる値です。Slack アプリの OAuth & Permissions の値を確かめてください"
    exit 1
  fi

  umask 077
  # 値は英数字と - だけなので、そのまま JSON に埋め込める
  printf '{"Name":"%s","AuthorizationType":"API_KEY","AuthParameters":{"ApiKeyAuthParameters":{"ApiKeyName":"Authorization","ApiKeyValue":"Bearer %s"}}}' \
    "$CONNECTION_NAME" "$1" > "$WORKDIR/update-connection.json"
  aws events update-connection --region "$REGION" \
    --cli-input-json "file://$WORKDIR/update-connection.json" > /dev/null
  echo "Bot トークンを登録しました: $CONNECTION_NAME"
}

# ---------------------------------------------------------------------------
# メインの処理
# ---------------------------------------------------------------------------
trap cleanup EXIT

if [[ "$#" -ne 0 ]]; then
  err "使い方: $0"
  exit 1
fi

signing_secret="$(read_secret "Signing Secret（変えないなら空のまま Enter）")"
bot_token="$(read_secret "Bot トークン xoxb-...（変えないなら空のまま Enter）")"

if [[ -n "$signing_secret" ]]; then
  put_signing_secret "$signing_secret"
else
  echo "Signing Secret は変えません"
fi

if [[ -n "$bot_token" ]]; then
  update_bot_token "$bot_token"
else
  echo "Bot トークンは変えません"
fi
