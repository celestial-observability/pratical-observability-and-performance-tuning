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
  - ベンチマークを実行
実行方法:
  - $0
実行例:
  - $0
EOF
  exit 2
}

start_timer "$@"
(($# == 0)) || (echo '引数は0個にしてください' >&2 && usage)
ssh -F "$SSH_CONFIG_FILE" bench "touch ~/.hushlogin" 2>&1 || {
  echo 'ssh失敗: bench'
  exit 0
}

#
# ベンチマーク
#
ssh -F "$SSH_CONFIG_FILE" bench 'private_isu/benchmarker/bin/benchmarker -u ./private_isu/benchmarker/userdata -t http://192.168.1.10 | tee result.json'

end_timer "$@"
