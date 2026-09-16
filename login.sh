#!/usr/bin/env bash
# login.sh — TRAE SOLO 登录：生成登录链接 → 浏览器登录 → 粘贴回调链接 → 换 token 落盘。
set -euo pipefail

cd "$(dirname "$0")"
AUTH_DIR="./auths"
CLIENT_ID="en1oxy7wnw8j9n"
APP_VERSION="0.1.43"
API_HOST="https://api.trae.com.cn"

mkdir -p "$AUTH_DIR"

MACHINE_ID="$(openssl rand -hex 16 2>/dev/null || python3 -c 'import secrets;print(secrets.token_hex(16))')"

# device_id 必须是官方客户端 AHA 注册过的真实设备 ID。
# checkin_credits/claim 会校验设备：未注册的随机 ID 会收到 9074（文案为
# “当前参与用户太多，请稍后再试”），服务端不执行签到。
# 优先级：环境变量 TRAE_DEVICE_ID > 本机官方客户端日志 > 随机（仅兜底，签到大概率失败）。
DEVICE_ID="$(TRAE_DEVICE_ID="${TRAE_DEVICE_ID:-}" python3 - <<'PYEOF'
import glob, os, re, sys

env = os.environ.get("TRAE_DEVICE_ID", "").strip()
if env:
    print(env); sys.exit(0)

home = os.path.expanduser("~")
appdata = os.environ.get("APPDATA", "")
xcfg = os.environ.get("XDG_CONFIG_HOME", "")
roots = []
for name in ("Trae CN", "TRAE SOLO CN", "TRAE CN"):
    roots += [
        os.path.join(home, "Library", "Application Support", name),          # macOS
        os.path.join(appdata, name) if appdata else "",                       # Windows
        os.path.join(xcfg or os.path.join(home, ".config"), name),            # Linux
    ]

pat = re.compile(r"device_id[:\s]+(\d{10,})")
votes = {}
for root in roots:
    if not root:
        continue
    for f in glob.glob(os.path.join(root, "logs", "aha_log", "aha_electron_*.log")):
        try:
            txt = open(f, encoding="utf-8", errors="replace").read()
        except OSError:
            continue
        for m in pat.finditer(txt):
            votes[m.group(1)] = votes.get(m.group(1), 0) + 1

if votes:
    print(max(votes, key=votes.get))
else:
    import secrets
    sys.stderr.write(
        "[!] 未从官方客户端日志找到已注册设备 ID（请先安装并至少启动过一次 Trae CN），\n"
        "    已回退为随机 ID——签到接口很可能返回 9074。\n"
        "    可手动指定：TRAE_DEVICE_ID=<真实设备ID> ./login.sh\n")
    print(secrets.token_hex(16))
PYEOF
)"
echo "[*] 使用 device_id: $DEVICE_ID"

echo "============================================================"
echo "  TRAE SOLO 登录 - 纯签到版"
echo "============================================================"
echo ""
echo "步骤："
echo "  1. 在浏览器打开下面链接，用手机号/验证码登录"
echo "  2. 登录成功后浏览器会跳到打不开的 127.0.0.1 地址"
echo "  3. 复制浏览器地址栏的完整链接，粘贴到下面"
echo ""

LOGIN_URL="$(MACHINE_ID="$MACHINE_ID" DEVICE_ID="$DEVICE_ID" CLIENT_ID="$CLIENT_ID" APP_VERSION="$APP_VERSION" python3 - <<'PYEOF'
import os, secrets, urllib.parse

params = {
    "login_version": "1",
    "auth_from": "solo",
    "login_channel": "native_ide",
    "plugin_version": "2.3.62834",
    "auth_type": "local",
    "client_id": os.environ["CLIENT_ID"],
    "redirect": "0",
    "login_trace_id": secrets.token_hex(8),
    "auth_callback_url": "http://127.0.0.1:18080/authorize",
    "machine_id": os.environ["MACHINE_ID"],
    "device_id": os.environ["DEVICE_ID"],
    "x_device_id": os.environ["DEVICE_ID"],
    "x_machine_id": os.environ["MACHINE_ID"],
    "x_device_brand": "PC",
    "x_device_type": "PC",
    "x_os_version": "1.0",
    "x_app_version": os.environ["APP_VERSION"],
    "x_app_type": "stable",
}
print("https://www.trae.cn/authorization?" + urllib.parse.urlencode(params))
PYEOF
)"

# 跨平台读取剪贴板：macOS pbpaste / Windows PowerShell / Linux xclip/xsel/wl-paste
clip_read() {
    if command -v pbpaste >/dev/null 2>&1; then
        pbpaste 2>/dev/null
    elif command -v powershell >/dev/null 2>&1; then
        powershell -NoProfile -Command "Get-Clipboard -Raw" 2>/dev/null
    elif command -v xclip >/dev/null 2>&1; then
        xclip -selection clipboard -o 2>/dev/null
    elif command -v xsel >/dev/null 2>&1; then
        xsel --clipboard --output 2>/dev/null
    elif command -v wl-paste >/dev/null 2>&1; then
        wl-paste --no-newline 2>/dev/null
    fi
}

# 记录剪贴板基线，轮询时只接受「新出现」的回调 URL，
# 这样连续添加多账号时不会误用上一次残留的回调链接。
clip_baseline="$(clip_read)"

echo "请在浏览器打开："
echo ""
echo "  $LOGIN_URL"
echo ""
echo "登录后浏览器会跳到打不开的 127.0.0.1 页面，"
echo "复制浏览器地址栏的完整链接，脚本会自动检测剪贴板。"
echo ""

callback_url="${1:-}"
if [[ -z "$callback_url" ]]; then
    if [[ -z "$(clip_read 2>/dev/null)" ]] && ! command -v pbpaste >/dev/null 2>&1 \
       && ! command -v powershell >/dev/null 2>&1 \
       && ! command -v xclip >/dev/null 2>&1 \
       && ! command -v xsel >/dev/null 2>&1 \
       && ! command -v wl-paste >/dev/null 2>&1; then
        # 无任何剪贴板工具，回退到交互输入
        read -rp "请粘贴回调链接: " callback_url || true
    else
        echo "[*] 等待剪贴板出现回调链接..." >&2
        spin='/-|\\'
        i=0
        while true; do
            clip="$(clip_read)"
            clip="${clip//[[:space:]]/}"
            # 必须是回调 URL，且与基线不同（防止误用上次的链接）
            if { [[ "$clip" == *127.0.0.1* ]] || [[ "$clip" == *authorize*code=* ]]; } \
               && [[ "$clip" != "$clip_baseline" ]]; then
                callback_url="$clip"
                break
            fi
            printf "\r[%c] 等待回调链接（复制后自动继续）..." "${spin:$((i % 4)):1}" >&2
            i=$((i + 1))
            sleep 1
        done
        echo "" >&2
    fi
fi
if [[ -z "$callback_url" ]]; then
    echo "未获取到回调链接，已取消" >&2
    exit 1
fi

echo "[*] 已收到回调链接（长度 ${#callback_url}），开始换取 token..." >&2
RESULT=$(CLIENT_ID="$CLIENT_ID" API_HOST="$API_HOST" APP_VERSION="$APP_VERSION" \
MACHINE_ID="$MACHINE_ID" DEVICE_ID="$DEVICE_ID" CALLBACK_URL="$callback_url" python3 - <<'PYEOF'
import json, os, sys, time, urllib.parse, urllib.request, urllib.error

CLIENT_ID = os.environ["CLIENT_ID"]
API_HOST = os.environ["API_HOST"]
APP_VERSION = os.environ["APP_VERSION"]
MACHINE_ID = os.environ["MACHINE_ID"]
DEVICE_ID = os.environ["DEVICE_ID"]
CALLBACK = os.environ["CALLBACK_URL"]

def http_post_json(url, body, headers, timeout=60, retries=2):
    req = urllib.request.Request(url, method="POST")
    for k, v in headers.items():
        req.add_header(k, v)
    data = json.dumps(body).encode()
    for attempt in range(retries + 1):
        try:
            with urllib.request.urlopen(req, data, timeout=timeout) as resp:
                return json.loads(resp.read().decode() or "{}")
        except urllib.error.HTTPError as e:
            raw = e.read().decode(errors="replace")
            print(f"[!] HTTP {e.code}: {raw[:400]}", file=sys.stderr)
            sys.exit(1)
        except (urllib.error.URLError, TimeoutError, ConnectionError) as e:
            if attempt < retries:
                print(f"[*] 网络瞬时错误，重试 {attempt + 1}/{retries}: {e}", file=sys.stderr)
                time.sleep(1)
                continue
            print(f"[!] 请求失败: {e}", file=sys.stderr)
            sys.exit(1)

def parse_json_param(raw):
    if not raw:
        return None
    for val in (raw, urllib.parse.unquote(raw)):
        try:
            obj = json.loads(val)
            if isinstance(obj, dict):
                return obj
        except Exception:
            continue
    return None

qs = urllib.parse.parse_qs(urllib.parse.urlparse(CALLBACK).query)
refresh_token = (qs.get("refreshToken") or [""])[0]
user_info = parse_json_param((qs.get("userInfo") or [""])[0]) or {}
user_jwt = parse_json_param((qs.get("userJwt") or [""])[0]) or {}

uid = str(user_info.get("UserID") or "")
nickname = str(user_info.get("ScreenName") or "")

jwt_token = str(user_jwt.get("Token") or "")
jwt_refresh = str(user_jwt.get("RefreshToken") or "")
if not refresh_token:
    refresh_token = jwt_refresh

token, new_refresh, expires_at = "", refresh_token, 0
if refresh_token:
    body = {"ClientID": CLIENT_ID, "RefreshToken": refresh_token, "ClientSecret": "-", "UserID": ""}
    resp = http_post_json(API_HOST + "/cloudide/api/v3/trae/oauth/ExchangeToken", body,
                          {"Content-Type": "application/json", "User-Agent": f"Trae/{APP_VERSION}"})
    result = resp.get("Result") or {}
    token = result.get("Token") or ""
    if not token:
        print("[!] ExchangeToken 失败: " + json.dumps(resp, ensure_ascii=False)[:300], file=sys.stderr)
        sys.exit(1)
    new_refresh = result.get("RefreshToken") or refresh_token
    expires_at = int(result.get("TokenExpireAt") or 0)
    if expires_at > 10**12:
        expires_at //= 1000
    if expires_at <= time.time():
        expires_at = int(time.time()) + int(result.get("TokenExpireDuration") or 1209600)
    print("[*] ExchangeToken 成功", file=sys.stderr)
else:
    token = jwt_token
    expires_at = int(user_jwt.get("TokenExpireAt") or 0)
    if expires_at > 10**12:
        expires_at //= 1000
    if not token:
        print("[!] 回调链接缺少 refreshToken", file=sys.stderr)
        sys.exit(1)
    print("[*] 使用 userJwt 的 Token 兜底", file=sys.stderr)

try:
    ui = http_post_json(API_HOST + "/cloudide/api/v3/trae/GetUserInfo",
                        {"ReqSource": "IDE", "IDEVersion": APP_VERSION},
                        {"Content-Type": "application/json", "x-cloudide-token": token,
                         "User-Agent": f"Trae/{APP_VERSION}"})
    u = ui.get("Result") or ui
    if u.get("UserID"):
        uid = str(u.get("UserID") or uid)
        nickname = str(u.get("ScreenName") or nickname)
except Exception as e:
    print(f"[*] GetUserInfo 失败: {e}", file=sys.stderr)

if not uid:
    print("[!] 未能获取 uid", file=sys.stderr)
    sys.exit(1)

out = {
    "uid": uid, "nickname": nickname, "access_token": token,
    "refresh_token": new_refresh, "expires_at": expires_at,
    "api_host": API_HOST, "machine_id": MACHINE_ID, "device_id": DEVICE_ID,
}
print("JSON:" + json.dumps(out))
PYEOF
)

CRED=$(echo "$RESULT" | sed -n 's/^JSON://p')
if [[ -z "$CRED" ]]; then
    echo "$RESULT" >&2
    echo "解析/换 token 失败"
    exit 1
fi

ACCT_UID=$(echo "$CRED" | python3 -c "import json,sys; print(json.load(sys.stdin)['uid'])")
NICKNAME=$(echo "$CRED" | python3 -c "import json,sys; print(json.load(sys.stdin)['nickname'])")
TOKEN=$(echo "$CRED" | python3 -c "import json,sys; print(json.load(sys.stdin)['access_token'])")
REFRESH=$(echo "$CRED" | python3 -c "import json,sys; print(json.load(sys.stdin)['refresh_token'])")
EXPIRES_AT=$(echo "$CRED" | python3 -c "import json,sys; print(json.load(sys.stdin)['expires_at'])")

AUTH_FILE="$AUTH_DIR/trae-${ACCT_UID}.json"
if [[ -f "$AUTH_FILE" ]]; then
    echo "账号已存在（uid=${ACCT_UID}），将覆盖更新凭证"
    ACTION="覆盖"
else
    echo "新账号（uid=${ACCT_UID}，新增 auth 文件"
    ACTION="新增"
fi

MACHINE_ID="$MACHINE_ID" DEVICE_ID="$DEVICE_ID" TOKEN="$TOKEN" REFRESH="$REFRESH" \
EXPIRES_AT="$EXPIRES_AT" ACCT_UID="$ACCT_UID" NICKNAME="$NICKNAME" AUTH_FILE="$AUTH_FILE" \
ACTION="$ACTION" python3 - <<'PYEOF'
import json, os
auth = {
    "account": {"uid": os.environ["ACCT_UID"], "enterpriseId": "", "nickname": os.environ["NICKNAME"]},
    "auth": {
        "accessToken": os.environ["TOKEN"],
        "refreshToken": os.environ["REFRESH"],
        "expiresAt": int(os.environ["EXPIRES_AT"]),
        "domain": "trae.cn",
        "apiHost": "https://api.trae.com.cn",
        "machineId": os.environ["MACHINE_ID"],
        "deviceId": os.environ["DEVICE_ID"],
    },
}
with open(os.environ["AUTH_FILE"], "w") as f:
    json.dump(auth, f, indent=1, ensure_ascii=False)
print(f"已保存（{os.environ['ACTION']}）: {os.environ['AUTH_FILE']}")
PYEOF

# 自动签到 + 查积分
TOKEN="$TOKEN" DEVICE_ID="$DEVICE_ID" APP_VERSION="$APP_VERSION" python3 - <<'PYEOF'
import json, os, time, urllib.request
UG = "https://api.trae.cn"
HDRS = {
    "Content-Type": "application/json",
    "Authorization": "Cloud-IDE-JWT " + os.environ["TOKEN"],
    "X-User-Region": "CN",
    "x-device-id": os.environ["DEVICE_ID"],
    "x-device-brand": "PC",
    "x-device-type": "PC",
    "x-os-version": "1.0",
    "x-app-version": os.environ["APP_VERSION"],
}
def post(path, body=b"{}"):
    req = urllib.request.Request(UG + path, method="POST", data=body, headers=HDRS)
    with urllib.request.urlopen(req, timeout=15) as r:
        return json.loads(r.read().decode() or "{}")
try:
    st = post("/trae/api/v2/ug/checkin_credits/status")
    if st.get("checked_in"):
        print("签到: 今日已签到")
    elif not st.get("enable"):
        print("签到: 活动未启用")
    else:
        # body 必须带 req_source=1（官方客户端固定值）；空 body 服务端不执行任何操作
        r = post("/trae/api/v2/ug/checkin_credits/claim", b'{"req_source":1}')
        code = r.get("code")
        # 9074（设备校验失败/繁忙文案）短暂重试一次
        if code == 9074:
            time.sleep(2)
            r = post("/trae/api/v2/ug/checkin_credits/claim", b'{"req_source":1}')
            code = r.get("code")
        if code not in (0, None):
            print(f"签到: 失败 code={code} {r.get('message','')}")
        else:
            # code=0 也必须回查，空操作同样返回 code=0
            v = post("/trae/api/v2/ug/checkin_credits/status")
            print("签到: 成功" if v.get("checked_in") else "签到: 服务端已受理但状态未翻转，请稍后重试")
except Exception as e:
    print(f"签到: {e}")
try:
    ent = post("/trae/api/v2/pay/ide_user_ent_usage")
    packs = ent.get("user_entitlement_pack_list") or []
    total = sum(p.get("entitlement_base_info", {}).get("quota", {}).get("credits_limit", 0) for p in packs)
    print(f"当前积分: {total}")
except Exception as e:
    print(f"查积分: {e}")
PYEOF

echo ""
echo "============================================================"
echo "  登录完成！"
echo "  UID: $ACCT_UID"
echo "  Nickname: ${NICKNAME:-（未获取到）}"
echo "  有效期: $(date -d "@$EXPIRES_AT" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "$EXPIRES_AT")"
echo "============================================================"
