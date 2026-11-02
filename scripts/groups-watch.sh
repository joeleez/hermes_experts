#!/bin/sh
# groups-watch.sh — roster 服務的進入點：每 60 秒更新一次「群 → 專家」對照
#
# 為什麼要常駐：飛書沒有「群內機器人清單」的 API，
# 只能逐個問 bot「你在哪些群」再反轉，所以要定期查。
set -u
INTERVAL="${GROUPS_REFRESH_SECONDS:-60}"
while :; do
  /opt/hermes/.venv/bin/python /scripts/gen-groups.py /src /out/groups.yaml || true
  sleep "$INTERVAL"
done
