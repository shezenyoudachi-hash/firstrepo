#!/bin/sh
# 実機インストール用の署名設定（Config/Local.xcconfig）を作成する。
# 事前に Xcode の「設定 → アカウント」で Apple ID を追加しておくこと。
set -eu

cd "$(dirname "$0")/.."
OUT=Config/Local.xcconfig

# Xcode に登録されているチーム ID を探す（Xcode のバージョンによってキー名が異なる）
TEAMS=$( { defaults read com.apple.dt.Xcode IDEProvisioningTeamByIdentifier 2>/dev/null || true
           defaults read com.apple.dt.Xcode IDEProvisioningTeams 2>/dev/null || true; } \
         | sed -n 's/.*teamID = "\{0,1\}\([A-Z0-9]\{10\}\)"\{0,1\};.*/\1/p' | sort -u)

COUNT=$(printf '%s\n' "$TEAMS" | grep -c . || true)
if [ "$COUNT" -eq 1 ]; then
  TEAM=$TEAMS
  echo "チーム ID: $TEAM"
else
  if [ "$COUNT" -gt 1 ]; then
    echo "複数のチームが見つかりました:"
    printf '  %s\n' $TEAMS
  else
    echo "Xcode に登録されたチームが見つかりませんでした。"
    echo "Xcode の「設定 → アカウント」で Apple ID を追加してから実行するか、チーム ID を直接入力してください。"
  fi
  printf "チーム ID（英数字10文字）: "
  read -r TEAM
fi

# バンドル ID は世界で一意である必要があるため、Mac のユーザー名とランダムな文字を使う
USER_PART=$(id -un | tr -cd 'A-Za-z0-9' | tr 'A-Z' 'a-z')
RANDOM_PART=$(LC_ALL=C tr -dc 'a-z0-9' < /dev/urandom | head -c 6)
PREFIX="com.${USER_PART:-user}.${RANDOM_PART}"

if [ -f "$OUT" ]; then
  echo "$OUT は既にあります。作り直す場合は削除してから実行してください。"
  cat "$OUT"
  exit 0
fi

cat > "$OUT" <<CONF
// scripts/setup-signing.sh で作成（Git には含めない）
DEVELOPMENT_TEAM = $TEAM
BUNDLE_ID_PREFIX = $PREFIX
CONF

echo "$OUT を作成しました:"
cat "$OUT"
echo
echo "Xcode を開き直して、iPhone を選んで ▶ を押してください。"
