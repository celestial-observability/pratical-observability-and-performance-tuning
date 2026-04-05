#!/usr/bin/env bash

# コメントテーブルにコメントしたユーザーのアカウント名をセット
query='UPDATE comments SET comments.user_account_name = (select users.account_name from users where users.id = comments.user_id);'
mysql -uisuconp -pisuconp -Disuconp -e "${query}"
