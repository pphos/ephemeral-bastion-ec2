#!/bin/bash
#
# 踏み台が起動時に読む SSM パラメータ（SecureString）を作る。
# ホスト鍵は、なければ生成して置き、利用者の公開鍵は、実行のたびに上書きする。
#
# 使い方: setup-ssm-parameters.sh <公開鍵ファイル>...
# リソース名の接頭辞は、環境変数 RESOURCE_PREFIX で変えられる。
# AWS の認証情報は、環境変数やプロファイルで、あらかじめ設定しておく。

set -Eeuo pipefail

readonly REGION="ap-northeast-1"
readonly PREFIX="${RESOURCE_PREFIX:-ephemeral-bastion}"
readonly HOST_KEY_PARAMETER="/$PREFIX/host-key"
readonly USER_KEYS_PARAMETER="/$PREFIX/user-public-keys"

# 秘密鍵を置く一時ディレクトリ。終了時に消す
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
# 公開鍵のファイルを検査して、1 つのファイルにまとめる。
# 公開鍵として読めないファイルがあれば、その時点で止まる。
# Globals:
#   WORKDIR
# Arguments:
#   公開鍵のファイル（1 つ以上）
#######################################
collect_public_keys() {
  local file

  for file in "$@"; do
    if [[ ! -f "$file" ]]; then
      err "ファイルがありません: $file"
      exit 1
    fi
    ssh-keygen -l -f "$file" > /dev/null
    cat "$file" >> "$WORKDIR/authorized_keys"
  done
}

#######################################
# ホスト鍵のパラメータがなければ、ed25519 の鍵を生成して置く。
# すでにあれば、鍵が変わらないよう、何もしない。
# Globals:
#   REGION
#   WORKDIR
#   HOST_KEY_PARAMETER
#######################################
ensure_host_key() {
  if aws ssm get-parameter --region "$REGION" \
    --name "$HOST_KEY_PARAMETER" > /dev/null 2>&1; then
    echo "ホスト鍵は、すでにあります。そのまま使います: $HOST_KEY_PARAMETER"
    return
  fi

  ssh-keygen -q -t ed25519 -N "" -C "" -f "$WORKDIR/host_key"
  aws ssm put-parameter --region "$REGION" \
    --name "$HOST_KEY_PARAMETER" \
    --type SecureString \
    --value "file://$WORKDIR/host_key" > /dev/null
  echo "ホスト鍵を作りました: $HOST_KEY_PARAMETER"
  ssh-keygen -l -f "$WORKDIR/host_key.pub"
}

#######################################
# 利用者の公開鍵のパラメータを、上書きで置く。
# Globals:
#   REGION
#   WORKDIR
#   USER_KEYS_PARAMETER
#######################################
put_user_public_keys() {
  aws ssm put-parameter --region "$REGION" \
    --name "$USER_KEYS_PARAMETER" \
    --type SecureString \
    --overwrite \
    --value "file://$WORKDIR/authorized_keys" > /dev/null
  echo "利用者の公開鍵を置きました: $USER_KEYS_PARAMETER"
  ssh-keygen -l -f "$WORKDIR/authorized_keys"
}

# ---------------------------------------------------------------------------
# メインの処理
# ---------------------------------------------------------------------------
trap cleanup EXIT

if [[ "$#" -lt 1 ]]; then
  err "使い方: $0 <公開鍵ファイル>..."
  exit 1
fi

collect_public_keys "$@"
ensure_host_key
put_user_public_keys
