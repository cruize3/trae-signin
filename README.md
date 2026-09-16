# trae-signin — TRAE SOLO 纯签到工具

TRAE Work (SOLO CN) 的轻量签到工具。只做三件事：**登录 → 签到 → 查积分**，没有任何 OpenAI API 反代或对话功能。

基于 [traework2api](https://github.com/Sliverkiss/traework2api) 精简而来。

纯 Go 标准库，零第三方依赖。

## 功能

| 功能 | 说明 |
|------|------|
| **登录** | `login.sh` 生成登录链接 → 浏览器登录 → 自动检测剪贴板回调 → 换 token 落盘 |
| **签到** | 批量遍历 `auths/` 下所有账号，自动刷新过期 token，逐个签到 |
| **积分查询** | 签到同时查询每个账号的积分余额 |
| **定时签到** | 内置调度器，每天定时执行 |

## 快速开始

```bash
# 1. 安装依赖（需要 Go 1.21+ 和 Python 3）
# macOS: brew install go python3
# Ubuntu: apt install golang python3

# 2. 克隆仓库
git clone https://github.com/<your-username>/trae-signin.git
cd trae-signin
chmod +x login.sh signin.sh

# 3. 登录账号
./login.sh
# → 浏览器打开链接 → 手机号/验证码登录 → 复制回调链接 → 脚本自动检测剪贴板

# 4. 签到
./signin.sh
# → 自动刷新 token → 签到 → 显示积分
```

## 设备 ID 说明

签到接口按**设备**限制每天一次。`login.sh` 会自动从本机 Trae CN 客户端日志中提取已注册的 AHA 设备 ID。

- **多账号同设备**：同一台机器只能给首个账号签到，其余会显示 `SKIP 设备今日已用于其他账号`
- **多账号多设备**：在另一台装了 Trae CN 的设备上提取设备 ID，登录时指定：
  ```bash
  TRAE_DEVICE_ID=另一台设备的ID ./login.sh
  ```
- **手动提取设备 ID**：在目标设备上运行：

  **macOS：**
  ```bash
  python3 -c "
  import glob, re, os
  files = sorted(glob.glob(os.path.expanduser('~/Library/Application Support/Trae CN/logs/aha_log/aha_electron_*.log')), key=os.path.getmtime, reverse=True)
  votes = {}
  for f in files:
      for m in re.finditer(r'device_id[:\s]+(\d{10,})', open(f, encoding='utf-8', errors='replace').read()):
          votes[m.group(1)] = votes.get(m.group(1), 0) + 1
  print(max(votes, key=votes.get) if votes else 'NOT_FOUND')
  "
  ```

  **Windows (PowerShell)：**
  ```powershell
  python -c "
  import glob, re, os
  base = os.path.expandvars(r'%APPDATA%\Trae CN\logs\aha_log')
  files = sorted(glob.glob(base + r'\aha_electron_*.log'), key=os.path.getmtime, reverse=True)
  votes = {}
  for f in files:
      for m in re.finditer(r'device_id[:\s]+(\d{10,})', open(f, encoding='utf-8', errors='replace').read()):
          votes[m.group(1)] = votes.get(m.group(1), 0) + 1
  print(max(votes, key=votes.get) if votes else 'NOT_FOUND')
  "
  ```

## 定时签到

### 方式一：GitHub Actions（推荐）

最稳定的方案，不依赖本地环境，GitHub 服务器每天自动触发。

**配置步骤：**

1. Fork 或推送本仓库到你的 GitHub

2. 在仓库 Settings → Secrets and variables → Actions 中添加以下 Secrets：

   | Secret 名称 | 值 | 说明 |
   |---|---|---|
   | `TRAE_AUTH_1` | 账号1 的完整凭证 JSON | `auths/trae-*.json` 的文件内容 |
   | `TRAE_AUTH_2` | 账号2 的完整凭证 JSON | 同上，多个账号依次添加 |

3. 每天北京时间 09:12 自动执行，也可在 Actions 页面手动触发

> 凭证 JSON 格式（登录后从 `auths/trae-*.json` 复制）：
> ```json
> {"account":{"uid":"...","nickname":"..."},"auth":{"accessToken":"...","refreshToken":"...","expiresAt":1786858238,...}}
> ```

### 方式二：Crontab

```bash
# 每天 08:00 签到
crontab -e
# 添加：
0 8 * * * cd /path/to/trae-signin && bash signin.sh >> signin.log 2>&1
```

### 方式三：内置调度器

```bash
go build -o scheduler ./cmd/scheduler
./scheduler &
# → 每天 08:00 自动签到
```

## 目录结构

```
cmd/
├── signin/main.go      签到入口
└── scheduler/main.go   定时调度器

internal/
├── auth/auth.go        凭证文件解析与原子写回
└── upstream/upstream.go 上游 API 客户端（签到/积分/刷新 token）

login.sh                登录脚本
signin.sh               签到脚本
auths/                  （gitignored）凭证文件
```

## API 端点

本工具调用 TRAE 官方 API：

| 端点 | 用途 |
|------|------|
| `api.trae.com.cn/.../ExchangeToken` | 用 refreshToken 换 accessToken |
| `api.trae.cn/.../checkin_credits/status` | 查询签到状态 |
| `api.trae.cn/.../checkin_credits/claim` | 执行签到 |
| `api.trae.cn/.../ide_user_ent_usage` | 查询积分余额 |

## 安全说明

- 所有 token 仅保存在 `auths/` 目录（已 gitignored），不会上传到 Git
- 终端输出只显示 UID/昵称/积分，不打印 token

## 致谢

- [traework2api](https://github.com/Sliverkiss/traework2api) — 原项目，本工具的精简来源

## License

MIT
