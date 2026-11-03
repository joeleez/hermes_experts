#!/usr/bin/env bash
# schedule.sh — 設定「每日定時重啟所有專家」（cron）
#
# 為什麼是後台的工作：重啟會讓所有 profile 一起中斷，只有操作者能決定時機。
#
# 用法：
#   ./scripts/schedule.sh           顯示目前設定
#   ./scripts/schedule.sh 04:30     每天 04:30 重啟
#   ./scripts/schedule.sh off       取消
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

MARK="# hermes-experts daily restart"
CMD="cd $ROOT && ./hh restart >> $PRIV/restart.log 2>&1"

current() { crontab -l 2>/dev/null | grep -F "$MARK" || true; }

case "${1:-}" in
  off)
    tmp="$(mktemp)"
    crontab -l 2>/dev/null | grep -vF "$MARK" | grep -vF "$CMD" > "$tmp" || true
    crontab "$tmp" 2>/dev/null || true
    rm -f "$tmp"
    ok "已取消定時重啟"
    ;;
  "")
    line="$(current)"
    if [ -n "$line" ]; then
      printf '目前設定：%s\n' "${line%% $MARK*}"
    else
      dim "未設定定時重啟（./hh schedule 04:30 可設定）"
    fi
    ;;
  *)
    TIME="$1"
    [[ "$TIME" =~ ^([0-9]{1,2}):([0-9]{2})$ ]] || { bad "時間格式要 HH:MM（例 04:30）"; exit 1; }
    H="${BASH_REMATCH[1]}"; M="${BASH_REMATCH[2]}"
    tmp="$(mktemp)"
    crontab -l 2>/dev/null | grep -vF "$MARK" | grep -vF "$CMD" > "$tmp" || true
    printf '%s %s * * * %s %s\n' "$M" "$H" "$CMD" "$MARK" >> "$tmp"
    if crontab "$tmp" 2>/dev/null; then
      ok "已設定每天 ${H}:${M} 重啟所有專家"
    else
      bad "crontab 寫入失敗（cron 服務可能沒跑）"
      rm -f "$tmp"; exit 1
    fi
    rm -f "$tmp"
    dim "  日誌：private/restart.log"
    ;;
esac
