#!/usr/bin/env bash
# Altare 自动抢机 —— Go 池模式
#
# Go 池不占团队池额度，规格固定（8 GB / 4 核 / 40 GB），最长 12h 自动删除。
# 用来做临时测试环境、跑一次性任务很合适。
#
# 注意：Go 机器实际是 Docker 容器，共享宿主内核和宿主出口 IP。
# 端口/防火墙/内核参数这类操作在 Go 池里不可靠，急用再上团队池。
set -u

export PATH="${PATH:-/usr/local/bin:/usr/bin:/bin}"

# ---------------- 配置 ----------------
ENV_FILE="${ENV_FILE:-/etc/altr.env}"

LOCATIONS="${LOCATIONS:-sg-sgp th-bkk kg-bsz id-jkt mn-uln de-fra fi-hel se-kna us-lax us-iad au-bne in-mum}"
TTL="${TTL:-12h}"
IMAGE="${IMAGE:-ubuntu}"
DELAY="${DELAY:-60}"
JITTER="${JITTER:-25}"

LOG="${LOG:-/var/log/altr-go.log}"
PWFILE="${PWFILE:-/var/lib/altr-grab/go-password.txt}"
LOCKFILE="${LOCKFILE:-/var/lock/altr-go.lock}"

# ---------------- 预检 ----------------
exec 9>"$LOCKFILE"
flock -n 9 || { echo "already running ($LOCKFILE)"; exit 1; }

if [ -r "$ENV_FILE" ]; then
  # shellcheck disable=SC1090
  . "$ENV_FILE"
else
  echo "缺少 $ENV_FILE（需要 TG_TOKEN / TG_CHAT 才能推送通知；没有也能跑，只是静默）" >&2
  TG_TOKEN=""
  TG_CHAT=""
fi

mkdir -p "$(dirname "$LOG")" "$(dirname "$PWFILE")"

log() { printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOG"; }

notify() {
  [ -n "${TG_TOKEN:-}" ] && [ -n "${TG_CHAT:-}" ] || return 0
  curl -s --max-time 15 "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
    -d "chat_id=${TG_CHAT}" -d "disable_web_page_preview=true" \
    --data-urlencode "text=$1" >/dev/null 2>&1 || true
}

set -- $LOCATIONS
TOTAL=$#
IDX=0
ATTEMPTS=0
loc=""

log "=== Go 抢机启动 | ${TOTAL} 个区域 | 间隔 ${DELAY}s | TTL ${TTL} ==="
notify "🔍 Altare Go 开始抢（Go 池，每 ${DELAY} 秒试一个区域）"

while :; do
  ATTEMPTS=$((ATTEMPTS + 1))
  IDX=$(( IDX % TOTAL + 1 ))
  eval "loc=\${$IDX}"

  pw=$(openssl rand -base64 12 | tr -d '/+=' | head -c 12)
  out=$(timeout 45 altr go -i "$IMAGE" -l "$loc" --ttl "$TTL" -d --password "$pw" --json 2>&1)
  rc=$?

  # 请求挂死时立即跳过该区域，否则整个轮询会被一个连接冻住
  if [ "$rc" -eq 124 ]; then
    log "[$ATTEMPTS] $loc → 请求超时(45s)，跳过"
    sleep $((DELAY + RANDOM % JITTER))
    continue
  fi

  # 配额满 / 认证失效：终态
  case "$out" in
    *"the most on the free plan"*)
      log "QUOTA FULL @ $loc: $(printf '%s' "$out" | head -c 200)"
      notify "⛔ Altare Go 配额已满，抢机已停止。先 altr go rm 或等 TTL 到期再启动。"
      exit 4 ;;
    *"not signed in"*|*"not logged in"*|*"401"*)
      log "AUTH FAIL: $(printf '%s' "$out" | head -c 200)"
      notify "⚠️ Altare Go 停止：登录失效，请重新 altr login。"
      exit 3 ;;
  esac

  # 成功判定：解析 JSON 顶层字段，不用 grep '"error"' 猜
  # （后者会把正文里带 error 字样的成功当成失败，于是继续抢、把配额塞满）
  ok=$(printf '%s' "$out" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    print("0"); raise SystemExit
if not isinstance(d, dict) or d.get("error"):
    print("0")
else:
    print("1" if (d.get("name") or d.get("id")) else "0")
' 2>/dev/null)

  if [ "$rc" -eq 0 ] && [ "$ok" = "1" ]; then
    printf '%s\n' "$pw" > "$PWFILE"
    chmod 600 "$PWFILE"
    log "SUCCESS @ $loc  raw=$(printf '%s' "$out" | tr -d '\n' | head -c 400)"

    sleep 8
    info=$(timeout 20 altr go ls 2>&1)
    printf '%s\n' "$info" >> "$LOG"

    notify "🎉 Altare Go 抢到了！

区域：$loc
时长：${TTL}（到期自动删）
密码：$pw （存在 $PWFILE）

机器清单：
$(printf '%s' "$info" | head -c 500)

进不去的话用：altr go exec <名字> \"命令\""
    exit 0
  fi

  case "$out" in
    *"busy"*|*"502"*|*"503"*)
      log "[$ATTEMPTS] $loc → 平台繁忙" ;;
    *429*|*"rate"*)
      log "[$ATTEMPTS] → 限流，冷却 120s"; sleep 120; continue ;;
    *"not signed in"*|*"not logged in"*|*"401"*)
      log "AUTH FAIL: $out"
      notify "⚠️ Altare Go 停止：登录失效。"
      exit 3 ;;
    *)
      log "[$ATTEMPTS] $loc → $(printf '%s' "$out" | head -c 160)" ;;
  esac

  if [ $((ATTEMPTS % 90)) -eq 0 ]; then
    notify "⏳ Altare Go 已试 ${ATTEMPTS} 次，仍无容量。继续。"
  fi
  sleep $((DELAY + RANDOM % JITTER))
done
