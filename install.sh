#!/usr/bin/env bash
# 一键安装：脚本 → /opt/altr-grab，配置 → /etc/altr.env，服务 → systemd
set -euo pipefail

SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
DEST=/opt/altr-grab

[ "$(id -u)" -eq 0 ] || { echo "需要 root 运行：sudo ./install.sh" >&2; exit 1; }

echo "==> 检查依赖"
for c in python3 curl openssl flock timeout altr; do
  command -v "$c" >/dev/null 2>&1 || echo "    警告：找不到 $c，脚本可能跑不起来"
done

echo "==> 安装脚本到 $DEST"
install -d -m 755 "$DEST"
install -m 700 "$SRC/scripts/grab.sh"    "$DEST/grab.sh"
install -m 700 "$SRC/scripts/go-grab.sh" "$DEST/go-grab.sh"

echo "==> 安装配置文件"
if [ -e /etc/altr.env ]; then
  echo "    /etc/altr.env 已存在，跳过（保留你现有的配置）"
else
  install -m 600 "$SRC/config.example.env" /etc/altr.env
  echo "    已生成 /etc/altr.env，记得填 TG_TOKEN / TG_CHAT"
fi

echo "==> 安装 systemd 服务"
install -m 644 "$SRC/systemd/altr-grab.service" /etc/systemd/system/altr-grab.service
install -m 644 "$SRC/systemd/altr-go.service"   /etc/systemd/system/altr-go.service
systemctl daemon-reload

cat <<EOF

完成。下一步：

  sudo systemctl enable --now altr-grab     # 团队池
  sudo systemctl enable --now altr-go       # Go 池（可选）

  看状态：systemctl status altr-grab
  看日志：journalctl -u altr-grab -f
EOF
