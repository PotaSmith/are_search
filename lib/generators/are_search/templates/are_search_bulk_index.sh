#!/bin/sh
set -eu

# 変更箇所: Railsアプリケーションの絶対パスを指定する。
APP_DIR="/path/to/rails_application"

# 変更箇所: bulk結果を永続保存するディレクトリを指定する。
# Rails.root/tmp 配下ではなく、削除されない場所を指定する。
RESULT_DIR="/path/to/persistent/are_search/bulk/article_new_version"

# 変更箇所: 実行するRails環境を指定する。
RAILS_ENV_NAME="production"

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
RUBY_SCRIPT="$SCRIPT_DIR/are_search_bulk_index.rb"
BULK_MODE="${1:-index}"

case "$BULK_MODE" in
    index|recover)
        ;;
    *)
        echo "usage: $0 [index|recover]" >&2
        exit 1
        ;;
esac

if [ ! -f "$RUBY_SCRIPT" ]; then
    echo "Ruby実行ファイルがありません: $RUBY_SCRIPT" >&2
    exit 1
fi

mkdir -p "$RESULT_DIR"
cd "$APP_DIR"

export RAILS_ENV="$RAILS_ENV_NAME"
export ARE_SEARCH_BULK_RESULT_DIR="$RESULT_DIR"
export ARE_SEARCH_BULK_MODE="$BULK_MODE"

exec bundle exec rails runner "$RUBY_SCRIPT"
