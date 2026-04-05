#!/usr/bin/env bash
set -Eeuo pipefail
#set -x
# -E: 関数やサブシェルでエラーが起きた時トラップ発動
# -e: エラーが発生した時点でスクリプトを終了
# -u: 未定義の変数を使用した場合にエラーを発生
# -x: スクリプトの実行内容を表示(debugで利用)
# -o pipefail: パイプライン内のエラーを検出

source "$(dirname "$0")/99-util.sh"

usage() {
  cat >&2 <<EOF
$0
概要:
  - 引数(target_host)に対してワンタイムスクリプトをアップロードして、実行する
実行方法:
  - $0 <target_host>
実行例:
  - $0 web
EOF
  exit 2
}

start_timer "$@"
(($# == 1)) || (echo '引数は1つだけ必要です' >&2 && usage)
readonly TARGET_HOST="$1"
ssh -F "$SSH_CONFIG_FILE" "$TARGET_HOST" 'touch ~/.hushlogin' 2>&1 || {
  log_info "${TARGET_HOST}へのssh失敗($0 $*): "
  exit 0
}

# onetimeスクリプトをターゲットサーバーにアップロード
readonly local_app_path='./onetime-scripts/'
readonly remote_app_path='/home/isucon/onetime-scripts/'
rsync -az "${local_app_path}" "${TARGET_HOST}:${remote_app_path}"

# onetimeスクリプトを実行
workspace="${remote_app_path}/writeout-images"
ssh -F "$SSH_CONFIG_FILE" "$TARGET_HOST" "(cd ${workspace} && [ ! -f done ] && /home/isucon/.local/go/bin/go mod tidy && /home/isucon/.local/go/bin/go run main.go && touch done) || echo '画像書き出しは完了済み'"

workspace="${remote_app_path}/set-account-name-to-comments"
ssh -F "$SSH_CONFIG_FILE" "$TARGET_HOST" "(cd ${workspace} && [ ! -f done ] && ./set-account-name-to-comments.sh && touch done) || echo 'commentsテーブルにAccountNameを付与済み'"

end_timer "$@"
