#!/usr/bin/env bash
# Altare 自动抢机 —— 团队池模式
#
# 轮询多个区域 × 内存档位的组合，直到抢到一台或配额耗尽。
# 抢到后把随机密码写到 $PWFILE，并通过 Telegram 推送机器信息。
#
# 设计要点（都是踩过的坑）：
#   1. 所有 altr 调用都套 timeout —— 一个挂死的连接不该冻住整个轮询
#   2. 区分「配额查询失败」和「配额为 0」—— 被 429 时 altr 返回空列表，
#      直接拿它算剩余量会误判成“磁盘配额耗尽”而退出
#   3. 配额满 / 认证失效 走终态分支，不无限重试
#   4. 成功判定靠解析 JSON 字段，不看退出码，也不用 grep '"error"' 猜
#   5. 60s 间隔 + 随机抖动；配额每 N 轮才查一次，省一半 API 调用
#   6. 凭据全部来自 $ENV_FILE，脚本本身不含任何密钥
set -u

export PATH="${PATH:-/usr/local/bin:/usr/bin:/bin}"

# ---------------- 配置（全部可用环境变量覆盖） ----------------
ENV_FILE="${ENV_FILE:-/etc/altr.env}"

TEMPLATE="${TEMPLATE:-Ubuntu 24.04}"
CPU="${CPU:-100}"                 # 100 = 1 核
DISK="${DISK:-5120}"              # MB
MEM_CANDIDATES="${MEM_CANDIDATES:-4096 2048}"
LOCATIONS="${LOCATIONS:-sg-sgp kg-bsz th-bkk id-jkt mn-uln de-fra fi-hel se-kna us-lax us-iad au-bne in-mum}"

# 团队池免费额度上限，用于判断还剩多少可抢
QUOTA_MEM="${QUOTA_MEM:-6144}"
QUOTA_DISK="${QUOTA_DISK:-10240}"

DELAY="${DELAY:-60}"              # 每轮基础间隔（秒）
JITTER="${JITTER:-25}"            # 附加随机抖动
DELAY_429="${DELAY_429:-240}"     # 被限流后的冷却
DELAY_BUSY="${DELAY_BUSY:-120}"   # 平台繁忙时的退避
QUOTA_EVERY="${QUOTA_EVERY:-10}"  # 每 N 轮查一次配额

LOG="${LOG:-/var/log/altr-grab.log}"
PWFILE="${PWFILE:-/var/lib/altr-grab/password.txt}"
LOCKFILE="${LOCKFILE:-/var/lock/altr-grab.lock}"

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

# 输出 "<剩余内存MB> <剩余磁盘MB>"；查询失败输出 FAIL，调用方必须区分
remaining() {
  local raw
  raw=$(timeout 25 altr servers --json 2>/dev/null) || { echo "FAIL"; return 1; }
  printf '%s' "$raw" | QUOTA_MEM="$QUOTA_MEM" QUOTA_DISK="$QUOTA_DISK" python3 -c '
import os, sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    print("FAIL"); raise SystemExit
items = d if isinstance(d, list) else (d.get("items") or [])
if not items and isinstance(d, dict) and d.get("error"):
    # 被限流时 CLI 可能返回带 error 的对象而不是列表，不能当成 0 台
    print("FAIL"); raise SystemExit
mem  = sum(int(x.get("memoryMb") or 0) for x in items)
disk = sum(int(x.get("diskMb") or 0) for x in items)
print(int(os.environ["QUOTA_MEM"]) - mem, int(os.environ["QUOTA_DISK"]) - disk)
' 2>/dev/null || echo "FAIL"
}

# 轮转表：区域 × 内存档位
PAIRS=""
for loc in $LOCATIONS; do
  for mem in $MEM_CANDIDATES; do
    PAIRS="$PAIRS $loc:$mem"
  done
done
# shellcheck disable=SC2086
set -- $PAIRS
TOTAL=$#
IDX=0
ATTEMPTS=0
BUSY_STREAK=0
RMEM=""

log "=== 启动 | 模板=$TEMPLATE | ${TOTAL} 个组合 | 间隔 ${DELAY}+0~${JITTER}s ==="
notify "🔍 Altare 抢机已启动（团队池，每 ${DELAY} 秒一轮，抢到会通知）"

while :; do
  ATTEMPTS=$((ATTEMPTS + 1))
  IDX=$(( IDX % TOTAL + 1 ))
  eval "PAIR=\${$IDX}"
  loc=${PAIR%%:*}
  mem=${PAIR##*:}

  # 配额检查：只每 QUOTA_EVERY 轮查一次，查询失败时不做判断
  if [ $((ATTEMPTS % QUOTA_EVERY)) -eq 1 ]; then
    RD=$(remaining)
    if [ "$RD" = "FAIL" ]; then
      log "[$ATTEMPTS] 配额查询失败（可能被限流），继续抢，下轮再查"
    else
      read -r RMEM RDISK <<< "$RD"
      if [ "${RDISK:-0}" -lt "$DISK" ]; then
        log "磁盘配额不足（剩 ${RDISK}MB / 需 ${DISK}MB）→ 停止"
        notify "⚠️ Altare 抢机停止：磁盘配额只剩 ${RDISK}MB。"
        exit 2
      fi
    fi
  fi

  if [ -n "${RMEM:-}" ] && [ "$mem" -gt "$RMEM" ]; then
    log "[$ATTEMPTS] 跳过 $loc ${mem}MB（剩余内存 ${RMEM}MB 不够）"
    sleep $((DELAY + RANDOM % JITTER)); continue
  fi

  name="alt-$(date +%m%d-%H%M%S)"
  pw=$(openssl rand -base64 15 | tr -d '/+=' | head -c 14)

  out=$(timeout 60 altr server create "$name" --template "$TEMPLATE" --location "$loc" \
        --memory "$mem" --disk "$DISK" --cpu "$CPU" --password "$pw" --json 2>&1)
  rc=$?

  # 请求超时：跳过这个组合，别让一个挂死的连接冻住循环
  if [ "$rc" -eq 124 ]; then
    log "[$ATTEMPTS] $loc ${mem}MB → 请求超时(60s)，跳过"
    sleep $((DELAY + RANDOM % JITTER)); continue
  fi

  # 终态：配额满 / 认证失效
  case "$out" in
    *"the most on the"*|*"free plan"*|*"quota"*|*"limit reached"*)
      log "QUOTA FULL @ $loc: $(printf '%s' "$out" | head -c 200)"
      notify "⛔ Altare 配额已满，抢机已停止。先删一台或等 TTL 到期再启动。"
      exit 4 ;;
    *"not signed in"*|*"not logged in"*|*"401"*)
      log "AUTH FAIL: $(printf '%s' "$out" | head -c 200)"
      notify "⚠️ Altare 抢机停止：登录失效，需要重新 altr login。"
      exit 3 ;;
  esac

  # 成功判定：解析 JSON，而不是只看退出码
  ok=$(printf '%s' "$out" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    print("0"); raise SystemExit
if isinstance(d, dict) and not d.get("error") and (d.get("name") or d.get("id") or d.get("uuid")):
    print("1")
else:
    print("0")
' 2>/dev/null)

  if [ "$rc" -eq 0 ] && [ "$ok" = "1" ]; then
    printf '%s\n' "$pw" > "$PWFILE"; chmod 600 "$PWFILE"
    info=$(timeout 20 altr server info "$name" --json 2>/dev/null)
    addr=$(printf '%s' "$info" | python3 -c '
import sys, json
try: d = json.load(sys.stdin)
except Exception: print(""); raise SystemExit
print(d.get("ip") or d.get("address") or "")
' 2>/dev/null)
    log "SUCCESS $name $loc ${mem}MB addr=$addr"
    notify "🎉 Altare 抢到了！

名称：$name
区域：$loc
规格：${mem}MB 内存 / $((CPU / 100)) 核 / $((DISK / 1024))GB 磁盘
地址：${addr:-（控制台看，可能还在启动）}
密码：$pw

密码已存 $PWFILE"
    exit 0
  fi

  case "$out" in
    *"No allocations"*|*"No capacity"*)
      log "[$ATTEMPTS] $loc ${mem}MB → 无容量"
      BUSY_STREAK=0
      sleep $((DELAY + RANDOM % JITTER)) ;;
    *"panel is busy"*|*"Could not establish"*|*"busy"*)
      BUSY_STREAK=$((BUSY_STREAK + 1))
      log "[$ATTEMPTS] $loc ${mem}MB → 平台繁忙（连续 ${BUSY_STREAK}）"
      if [ $((BUSY_STREAK % 5)) -eq 0 ]; then
        sleep "$DELAY_BUSY"
      else
        sleep $((DELAY + RANDOM % JITTER))
      fi ;;
    *429*|*"rate"*|*"Rate"*)
      log "[$ATTEMPTS] → 被限流，冷却 ${DELAY_429}s"
      sleep "$DELAY_429" ;;
    *)
      log "[$ATTEMPTS] $loc ${mem}MB → $(printf '%s' "$out" | head -c 160)"
      sleep $((DELAY + RANDOM % JITTER)) ;;
  esac

  if [ $((ATTEMPTS % 100)) -eq 0 ]; then
    notify "⏳ Altare 已尝试 ${ATTEMPTS} 次，仍无容量（$loc）。继续抢。"
  fi
done
