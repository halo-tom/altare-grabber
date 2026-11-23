# altare-grabber

Altare 免费服务器的自动抢机脚本。盯着多个区域轮询，一有容量就下单，抢到后把机器信息和随机密码推送到 Telegram（可选）。

Altare 的免费额度经常被抢满，手动点基本抢不到；这个脚本就是替你 24 小时在那儿点。

> 非官方项目，与 Altare 无关。使用前请自行确认平台条款允许自动化操作，风险自负。

---

## 目录

- [它做什么](#它做什么)
- [两种模式](#两种模式)
- [开始之前：你需要准备什么](#开始之前你需要准备什么)
- [部署在哪台机器上](#部署在哪台机器上)
- [安装步骤](#安装步骤)
- [抢到之后怎么用](#抢到之后怎么用)
- [配置项](#配置项)
- [常见问题与排查](#常见问题与排查)
- [退出码含义](#退出码含义)
- [安全与隐私](#安全与隐私)

---

## 它做什么

```
┌─────────────────────────────────────────────┐
│  while 没抢到:                               │
│    1. 每隔 60 秒 + 随机抖动                   │
│    2. 换下一个 区域 × 内存档位 组合            │
│    3. 查一次剩余额度（每 10 轮才查，省调用）    │
│    4. 发一次创建请求（超时 60 秒自动放弃）      │
│    5. 成功 → 存密码、推送通知、退出            │
│       配额满/登录失效 → 通知、退出             │
│       无容量/繁忙/限流 → 等一会儿继续           │
└─────────────────────────────────────────────┘
```

脚本本身不保存任何账号密码——它调用你本机已登录的 `altr` CLI，凭据由 CLI 自己管理。

## 两种模式

| | 团队池 `grab.sh` | Go 池 `go-grab.sh` |
|---|---|---|
| 调用命令 | `altr server create` | `altr go` |
| 额度 | 与团队成员共享 | 独立，默认最多 3 台 |
| 规格 | 可自选（默认 4 GB / 1 核 / 5 GB） | 固定 8 GB / 4 核 / 40 GB |
| 生命周期 | 长期，需手动删 | TTL 到期自动删（默认 12h） |
| 本质 | 独立虚拟机 | Docker 容器，共享宿主与出口 IP |
| 适合 | 长期跑服务 | 临时测试、一次性任务 |

两者互不影响，可以同时跑。**Go 池的机器不适合改内核参数/防火墙，也不适合需要独立 IP 的场景。**

## 开始之前：你需要准备什么

按顺序确认这四样，缺一样都跑不起来：

### 1. 一台能跑 bash 的机器（见下一节的选型）

### 2. Altare CLI `altr`，并且已经登录

```bash
# 确认装好了
altr --version

# 确认还登录着（返回邮箱/团队名就是好的）
altr whoami

# 确认能列机器
altr servers --json
```

- 如果提示 `command not found`：先按 Altare 官方文档安装 CLI。
- 如果提示 `not signed in` / `401`：执行 `altr login` 重新登录。**脚本不会帮你登录，也不会存你的密码。**

### 3. 几个基础命令

```bash
command -v python3 curl openssl flock timeout
```

四个都有输出就没问题。缺的话：

| 系统 | 安装命令 |
|---|---|
| Debian / Ubuntu | `sudo apt install -y python3 curl openssl util-linux` |
| CentOS / Rocky | `sudo dnf install -y python3 curl openssl util-linux` |
| Alpine | `sudo apk add python3 curl openssl util-linux bash` |
| macOS | `xcode-select --install`，然后 `brew install flock`（macOS 默认没有 flock） |

### 4.（可选）Telegram bot，用来收通知

不配也能跑，只是抢到后得自己去 `altr servers` 看。

配的话需要两个值：

1. 找 [@BotFather](https://t.me/BotFather) 发 `/newbot`，拿到 **bot token**（形如 `1234567890:AA...`）
2. 找 [@userinfobot](https://t.me/userinfobot) 发任意消息，拿到你的 **chat id**（一串数字）
3. 在 Telegram 里先给你的 bot 发一条 `/start`，否则 bot 没法主动给你发消息

### 5. 你的额度上限（重要）

脚本靠「额度上限 − 现有机器占用」判断还剩多少能抢。默认写的是 **6 GB 内存 / 10 GB 磁盘**，这是示例值。

**去控制台或 `altr servers` 确认你账号的实际免费额度，然后把 `QUOTA_MEM` / `QUOTA_DISK` 改成你的真实值。** 填小了会提前误判「配额不足」退出，填大了会发出注定失败的请求。

## 部署在哪台机器上

脚本是个循环进程，**机器只要关机/休眠/断网就停止抢**。所以选型核心就一条：能不能 24 小时挂着。

| 部署位置 | 可行性 | 说明 |
|---|---|---|
| **Linux 云服务器 / VPS** | ✅ 最推荐 | 24h 在线，`systemd` 托管，关机也不会断 |
| **家里的 Linux 小主机 / NAS / 软路由** | ✅ 推荐 | 24h 开机的话完全够用；注意别让它休眠 |
| **macOS 台式机** | ⚠️ 可以 | 需要 `brew install flock`；合盖休眠会暂停，建议接电源并关闭休眠 |
| **Windows 主力机** | ⚠️ 需要 WSL2 | **不能原生运行**（脚本是 bash + flock + systemd）。装 WSL2 后在 Ubuntu 里跑；系统睡眠同样会暂停 |
| **树莓派** | ✅ 可行 | 功耗低，适合长期挂 |

Windows 用户如果只是想试一下，WSL2 里跑前台模式就够了：

```powershell
wsl --install -d Ubuntu
# 进入 Ubuntu 后按下面的步骤安装
```

> 注意：`systemd` 那套自启配置只在 Linux 上有效。macOS 用 `launchd`，Windows WSL2 需要额外开启 systemd（`/etc/wsl.conf` 里加 `[boot] systemd=true`），或者用 `tmux` / `screen` 挂着跑。

## 安装步骤

下面以 Ubuntu / Debian 为例，其他发行版替换包管理命令即可。

### 1. 检查依赖

```bash
altr servers --json      # 必须能返回 JSON，不能报错
python3 --version
curl --version | head -1
openssl version
```

### 2. 拿到代码

```bash
git clone https://github.com/z961089510-dev/altare-grabber.git
cd altare-grabber
```

（或者直接下载 ZIP 解压也行。）

### 3. 写配置

```bash
sudo cp config.example.env /etc/altr.env
sudo chmod 600 /etc/altr.env
sudo nano /etc/altr.env
```

最少改这几项：

```bash
TG_TOKEN="1234567890:AA..."   # 不想要通知就留空
TG_CHAT="123456789"
QUOTA_MEM=6144                 # 改成你自己账号的额度上限
QUOTA_DISK=10240
```

> 配置放在 `/etc/altr.env` 而不是项目目录里，是为了让脚本文件可以随便公开、随便更新，而你的 token 永远不进仓库（`.gitignore` 也挡了一道）。

### 4. 先在前台试跑（别急着实装服务）

```bash
chmod +x scripts/*.sh
sudo DELAY=10 bash scripts/grab.sh
```

`DELAY=10` 把间隔临时改成 10 秒，方便你几十秒内看到几轮日志。正常输出长这样：

```
2026-11-23 23:29:52 === 启动 | 模板=Ubuntu 24.04 | 24 个组合 | 间隔 10+0~25s ===
2026-11-23 23:29:52 [1] sg-sgp 4096MB → 无容量
2026-11-23 23:30:03 [2] sg-sgp 2048MB → 无容量
```

看到「无容量」就说明整条链路是通的，只是现在真的没坑位——这正是预期。按 `Ctrl+C` 停掉。

如果这一步就报错，先去[常见问题](#常见问题与排查)，别往下走。

### 5. 装成后台服务

```bash
sudo ./install.sh
```

它做四件事：

- 把脚本装到 `/opt/altr-grab/`
- 如果 `/etc/altr.env` 不存在，从模板生成一份（已存在则保留你的）
- 装两个 systemd 单元：`altr-grab.service`、`altr-go.service`
- `daemon-reload`

然后启动你需要的那个：

```bash
# 团队池（抢长期机器）
sudo systemctl enable --now altr-grab

# Go 池（抢临时机器，可选）
sudo systemctl enable --now altr-go
```

`enable` 保证重启后自动跑，`--now` 是立刻启动。

### 6. 确认真的在跑

```bash
systemctl status altr-grab --no-pager
journalctl -u altr-grab -n 20 --no-pager
```

状态应该是 `active (running)`。日志里出现「=== 启动 ===」就对了。

想停：

```bash
sudo systemctl stop altr-grab
sudo systemctl disable altr-grab     # 顺手取消开机自启
```

> **为什么服务停了不会自动重启？** 脚本在「配额满」「登录失效」这类情况下是正常退出的——重试一万次也没用，只会浪费请求。所以服务配的是 `Restart=on-abnormal`：只有被信号杀掉、真正卡死的进程才会重开。这种情况需要你处理后手动 `systemctl start`。

## 抢到之后怎么用

脚本会把随机密码写到 `PWFILE`（默认 `/var/lib/altr-grab/password.txt`，Go 池是 `go-password.txt`）：

```bash
sudo cat /var/lib/altr-grab/password.txt
```

然后：

```bash
altr servers              # 看机器名字和 IP
ssh root@<IP>             # 用上面那个密码登录（首次可能要等机器启动完成，1~3 分钟）
```

Go 池的机器是容器，可能得走：

```bash
altr go ls
altr go exec <名字> "命令"
```

**密码只在抢到那一刻写一次**，之后脚本就退出了。丢了密码只能重置或重建机器，所以建议抢到后立刻存进密码管理器。

## 配置项

全部可以用环境变量覆盖，写在 `/etc/altr.env`、`systemd` 的 `Environment=`，或者命令行前缀里。

| 变量 | 默认 | 说明 |
|---|---|---|
| `TG_TOKEN` | 空 | Telegram bot token，留空则整个通知静默 |
| `TG_CHAT` | 空 | 接收通知的 chat id |
| `LOCATIONS` | 12 个区域 | 轮询区域，空格分隔 |
| `MEM_CANDIDATES` | `4096 2048` | 团队池内存档位，从上到下试 |
| `TEMPLATE` | `Ubuntu 24.04` | 系统模板名，要和控制台里一致 |
| `CPU` | `100` | CPU 百分比，100 = 1 核 |
| `DISK` | `5120` | 磁盘 MB |
| `QUOTA_MEM` | `6144` | 你的内存额度上限，用于算剩余量 |
| `QUOTA_DISK` | `10240` | 你的磁盘额度上限 |
| `DELAY` | `60` | 每轮基础间隔（秒） |
| `JITTER` | `25` | 附加随机抖动（秒），避免固定节奏像爬虫 |
| `DELAY_429` | `240` | 被限流后的冷却时间 |
| `DELAY_BUSY` | `120` | 平台繁忙时的退避时间 |
| `QUOTA_EVERY` | `10` | 每 N 轮查一次额度 |
| `TTL` | `12h` | 仅 Go 池，机器存活时长 |
| `IMAGE` | `ubuntu` | 仅 Go 池，镜像名 |
| `LOG` | `/var/log/altr-*.log` | 日志路径 |
| `PWFILE` | `/var/lib/altr-grab/*.txt` | 抢到后密码写哪 |
| `ENV_FILE` | `/etc/altr.env` | 配置从哪读 |

## 常见问题与排查

### 启动就退出，日志写 `缺少 /etc/altr.env`

配置没建。`sudo cp config.example.env /etc/altr.env && sudo chmod 600 /etc/altr.env`。

如果看到「没有也能跑，只是静默」，说明脚本带了空配置继续跑——想收通知就补上 `TG_TOKEN`/`TG_CHAT`。

### 提示 `already running (/var/lock/altr-grab.lock)`

已经有一个实例在跑了。查一下：

```bash
systemctl status altr-grab
ps aux | grep -c '[g]rab.sh'
```

要重开就先 `sudo systemctl stop altr-grab`，等两秒再启动。锁文件不用手删。

### 一直刷「无容量」，几十轮都没抢到

这是最常见的正常状态——**免费坑位就是稀缺**，可能要等几小时甚至几天。可以做的：

- 把 `LOCATIONS` 加长，多加区域（`altr server locations` 可以列出所有可用区域）
- 把 `TEMPLATE` 换成更容易抢到的模板（`altr server templates` 列出可选值）
- 把 `MEM_CANDIDATES` 加上更小的档位，比如 `"2048 1024"`，小机器更容易抢到
- 保持耐心。脚本就是为了不用你盯着才写的

### 日志里 `AUTH FAIL` / `登录失效`，退出码 3

`altr` 的登录过期了。手动 `altr login` 重新登录，然后 `sudo systemctl start altr-grab`。

### 日志里 `QUOTA FULL`，退出码 4

额度已经满了。要么删掉一台旧的（`altr servers` 看名字，`altr server delete <名字>`），要么等 Go 池的 TTL 到期。

> 注意：Go 池的配额和团队池是分开算的，一个满了不代表另一个也满。

### 日志里 `429` / `被限流`，冷却 240 秒

请求太密了。把 `DELAY` 从 60 调到 90~120，`QUOTA_EVERY` 从 10 调到 20 再试。

### 服务起不来，`journalctl` 里是 `exec format error` 或权限错误

检查脚本有没有执行位：`sudo chmod 700 /opt/altr-grab/*.sh`。如果用了 `install.sh` 应该已经设好了。

### 服务反复重启（`StartLimitHit`）

说明进程是被杀掉而不是正常退出。看 `journalctl -u altr-grab -n 50` 找真实原因（多半是 OOM、磁盘满、或者 `altr` 卡死被 `timeout` 杀掉后服务想重开）。

`systemctl reset-failed altr-grab` 清掉失败计数再启动。

### 抢到了但没收到 Telegram 消息

按顺序查：

1. `/etc/altr.env` 里 `TG_TOKEN`/`TG_CHAT` 是否都非空
2. 你有没有先给 bot 发过一条 `/start`（没发过 bot 不能主动找你）
3. 手动测一下：`curl "https://api.telegram.org/bot<TOKEN>/getMe"`，返回 `"ok":true` 才是 token 对的

### 抢到了，但 SSH 连不上

机器刚创建还在启动，等 1~3 分钟。还不行就看 `altr servers` 里的状态，或者去控制台看 IP 有没有分配。

### 密码忘了

`sudo cat /var/lib/altr-grab/password.txt`。如果文件也被删了，只能重建机器。

### 想让脚本一直跑但机器会休眠

在 Linux 上配置别休眠：

```bash
sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target
```

或者在电源设置里把「自动挂起」关掉。笔记本合盖一般还是会断，建议用台式机/服务器。

### 改了配置怎么生效

```bash
sudo systemctl restart altr-grab
```

`EnvironmentFile` 是启动时读的，改完必须重启。

## 退出码含义

| 退出码 | 含义 | 该做什么 |
|---|---|---|
| 0 | 抢到了 | 看密码文件，登录机器 |
| 1 | 已有实例在跑 | 先停掉旧的 |
| 2 | 磁盘额度不够 | 删机器或调小 `DISK` |
| 3 | 登录失效 | `altr login` |
| 4 | 配额已满 | 删机器或等 TTL |
| 124 | 单次请求超时（内部处理，不退出） | 无需干预 |

## 安全与隐私

- **仓库内不含任何凭据。** 脚本从 `/etc/altr.env` 读取 token，配置文件在 `.gitignore` 里；抢到的密码写在 `/var/lib/altr-grab/`（600 权限），不在项目目录。
- **不碰你的 Altare 账号密码。** 登录态由 `altr` CLI 自己维护，脚本只是调用它。
- 如果你 fork 后想公开分享，提交前确认没有把 `/etc/altr.env` 拷进仓库、也没在 README 里贴自己的 chat id。
- 建议给 Telegram bot token 单独建一个 bot，方便随时去 @BotFather `/revoke` 换掉。

## License

MIT
