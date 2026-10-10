#!/usr/bin/env bash
# Claude Code 一键配置 —— 调研工具箱 + 自动保存 + 对话记录 + 调研档案馆
# 来源：https://github.com/NNNoxin/claude-config
#
# 用法（任选其一）：
#   云端：claude.ai/code 环境设置的 Setup script 里写一行
#         curl -fsSL https://raw.githubusercontent.com/NNNoxin/claude-config/main/setup.sh | bash
#         网络访问选 Full。
#   本机（macOS / Linux / Windows 的 WSL）：在终端运行同一行命令。
#
# 这个脚本只在环境第一次启动（或脚本/网络设置改动后）运行，结果会被缓存成快照；
# 后台进程不会被缓存，所以每个会话开头要执行一次 research-init（Skill 会自动提醒 Claude）。
#
# 安装内容：
#   agent-reach        Agent Reach CLI + Skill（~/.claude/skills/agent-reach）
#   yt-dlp / twitter / mcporter（Exa 全网搜索）
#   xiaohongshu-mcp    小红书 MCP，从源码编译，并预先下载它的内置浏览器
#   research-init      每个会话执行一次：导入 Cookie、启动小红书服务、跑 research-check
#   research-check     检查各网站是否可用，输出 Markdown 表格
#   xhs-cookies-import / xhs-mcp-start  小红书辅助命令
#   research-toolkit   Claude Skill（~/.claude/skills/research-toolkit），记录各网站怎么查
#
# Cookie 放在环境设置的 Environment variables 里（不要提交到仓库，也不要贴进聊天）：
#   XHS_COOKIES        小红书 Cookie：Cookie-Editor 导出的 JSON（压成一行）或 Header String
#   TWITTER_COOKIES    推特 Cookie：同上；或者分别填 TWITTER_AUTH_TOKEN 和 TWITTER_CT0

set -uo pipefail

AR_HOME="$HOME/.agent-reach"
AR_SRC="$AR_HOME/src/Agent-Reach"
AR_VENV="$HOME/.agent-reach-venv"
XHS_SRC="$AR_HOME/tools/xiaohongshu-mcp"
XHS_BIN="$AR_HOME/tools/bin/xiaohongshu-mcp"
SKILL_DIR="$HOME/.claude/skills/research-toolkit"

# 命令装到哪：云端（root）用 /usr/local/bin；本机没有写权限时用 ~/.local/bin
if [ -w /usr/local/bin ]; then BIN_DIR=/usr/local/bin; else BIN_DIR="$HOME/.local/bin"; fi
mkdir -p "$BIN_DIR"
export BIN_DIR PATH="$BIN_DIR:$PATH"
RC_FILES="$HOME/.bashrc"
[ -f "$HOME/.zshrc" ] && RC_FILES="$RC_FILES $HOME/.zshrc"
add_rc() {  # 往 shell 启动文件里追加一行（已存在就跳过）
  for rc in $RC_FILES; do grep -qF "$1" "$rc" 2>/dev/null || echo "$1" >> "$rc"; done
}

log() { echo "[cloud-setup] $*"; }

clone_or_update() {
  local url="$1" dir="$2"
  if [ -d "$dir/.git" ]; then
    git -C "$dir" pull --ff-only -q || true
  else
    mkdir -p "$(dirname "$dir")"
    git clone --depth 1 -q "$url" "$dir"
  fi
}

mkdir -p "$AR_HOME/logs" "$(dirname "$XHS_BIN")"

# Node 内置 fetch 默认不走 HTTPS_PROXY；mcporter（Exa 搜索）需要这个开关
add_rc 'export NODE_USE_ENV_PROXY=1'
add_rc '[ -f ~/.agent-reach/twitter.env ] && . ~/.agent-reach/twitter.env'
[ "$BIN_DIR" = /usr/local/bin ] || add_rc "export PATH=\"$BIN_DIR:\$PATH\""
export NODE_USE_ENV_PROXY=1

# ---------- Agent Reach 和小红书 MCP 并行安装 ----------
install_agent_reach() {
  log "installing Agent Reach"
  clone_or_update https://github.com/Panniantong/Agent-Reach.git "$AR_SRC" || return 1
  [ -x "$AR_VENV/bin/pip" ] || python3 -m venv "$AR_VENV"
  "$AR_VENV/bin/pip" install -q -U "$AR_SRC" "yt-dlp[default]" || return 1
  ln -sf "$AR_VENV/bin/agent-reach" "$BIN_DIR/agent-reach"
  ln -sf "$AR_VENV/bin/yt-dlp" "$BIN_DIR/yt-dlp"
  # 安装 mcporter + Exa、twitter-cli，并把 SKILL.md 写入 ~/.claude/skills/agent-reach
  agent-reach install --env=auto --system --channels=twitter,xiaohongshu >"$AR_HOME/logs/agent-reach-install.log" 2>&1 || true
  log "Agent Reach done"
}

install_xhs() {
  log "building xiaohongshu-mcp"
  clone_or_update https://github.com/xpzouying/xiaohongshu-mcp.git "$XHS_SRC" || return 1
  # 补丁：/search_result?... 有时会被重定向到 http://.../search_result/，云端代理只放行 HTTPS，
  # 页面会卡到超时。直接请求 /search_result/?... 可以避开这次重定向。
  python3 - "$XHS_SRC/xiaohongshu/search.go" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
open(p, "w").write(s.replace("https://www.xiaohongshu.com/search_result?%s", "https://www.xiaohongshu.com/search_result/?%s"))
PY
  # 补丁：页面状态一出现就读结果，这时 feeds 往往还是空数组，搜索返回 0 条。
  # 改成等 feeds 非空再读，最多等 15 秒（超时照常往下走，不让搜索失败）。
  python3 - "$XHS_SRC/xiaohongshu/search.go" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = "page.MustWait(`() => window.__INITIAL_STATE__ !== undefined`)"
new = ("page.MustWait(`() => { const f = window.__INITIAL_STATE__?.search?.feeds; "
       "const v = f ? (f.value !== undefined ? f.value : f._value) : null; "
       "window.__feedsWaitStart = window.__feedsWaitStart || Date.now(); "
       "return (v && v.length > 0) || Date.now() - window.__feedsWaitStart > 15000; }`)")
if old in s:
    open(p, "w").write(s.replace(old, new, 1))
PY
  (cd "$XHS_SRC" && go build -o "$XHS_BIN" .) || { log "xiaohongshu-mcp build failed"; return 1; }
  # 首次启动会下载约 150MB 的内置浏览器；在这里提前下载，让它进入环境快照
  if ! ls "$HOME/.cache/xiaohongshu-mcp/browser"/*/browser/chrome >/dev/null 2>&1; then
    log "pre-downloading xiaohongshu-mcp browser"
    (cd "$AR_HOME" && "$XHS_BIN" -headless=true -port :18061 >"$AR_HOME/logs/xhs-predownload.log" 2>&1 &
     pid=$!
     for _ in $(seq 1 120); do
       grep -q "启动 HTTP 服务器\|using browser binary" "$AR_HOME/logs/xhs-predownload.log" 2>/dev/null && break
       sleep 2
     done
     kill "$pid" 2>/dev/null || true)
  fi
  log "xiaohongshu-mcp done"
}

install_agent_reach &
pid_ar=$!
install_xhs &
pid_xhs=$!
wait "$pid_ar" || log "Agent Reach install failed"
wait "$pid_xhs" || log "xiaohongshu-mcp install failed"

# ---------- 辅助命令 ----------

# xhs-cookies-import：Cookie-Editor 的 JSON 或 Header String → xiaohongshu-mcp 的 cookies.json
cat > "$BIN_DIR/xhs-cookies-import" <<'EOF'
#!/usr/bin/env python3
import json, os, sys
raw = sys.stdin.read().strip()
out = []
if raw.startswith("["):
    for c in json.loads(raw):
        if not str(c.get("domain", "")).lstrip(".").endswith("xiaohongshu.com"):
            continue
        out.append({
            "name": c["name"], "value": c["value"],
            "domain": c.get("domain", ".xiaohongshu.com"), "path": c.get("path", "/"),
            "expires": c.get("expirationDate", c.get("expires", -1)) or -1,
            "httpOnly": bool(c.get("httpOnly")), "secure": bool(c.get("secure")),
            "session": bool(c.get("session")),
        })
else:
    for part in raw.split(";"):
        if "=" in part:
            k, v = part.split("=", 1)
            out.append({"name": k.strip(), "value": v.strip(), "domain": ".xiaohongshu.com",
                        "path": "/", "expires": -1, "httpOnly": False, "secure": True, "session": True})
if not out:
    sys.exit("no xiaohongshu.com cookies found")
path = os.path.expanduser("~/.agent-reach/xhs-cookies.json")
fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as f:
    json.dump(out, f)
print(f"saved {len(out)} xiaohongshu cookies")
EOF
chmod +x "$BIN_DIR/xhs-cookies-import"

# xhs-mcp-start：启动小红书 MCP 服务（http://localhost:18060/mcp），已在运行则跳过
cat > "$BIN_DIR/xhs-mcp-start" <<EOF
#!/usr/bin/env bash
if curl -s -o /dev/null -m 2 http://localhost:18060/mcp; then echo "xiaohongshu-mcp already running"; exit 0; fi
mkdir -p "$AR_HOME/logs"
cd "$AR_HOME"
COOKIES_PATH="$AR_HOME/xhs-cookies.json" XHS_PROXY="\${HTTPS_PROXY:-}" \\
  nohup "$XHS_BIN" -headless=true > "$AR_HOME/logs/xiaohongshu-mcp.log" 2>&1 &
for _ in \$(seq 1 90); do
  curl -s -o /dev/null -m 2 http://localhost:18060/mcp && { echo "xiaohongshu-mcp started"; exit 0; }
  sleep 2
done
echo "xiaohongshu-mcp did not come up; see $AR_HOME/logs/xiaohongshu-mcp.log"
exit 1
EOF
chmod +x "$BIN_DIR/xhs-mcp-start"

# research-init：每个会话执行一次
cat > "$BIN_DIR/research-init" <<'EOF'
#!/usr/bin/env bash
AR_HOME="$HOME/.agent-reach"
export NODE_USE_ENV_PROXY=1 NODE_NO_WARNINGS=1

if [ -n "${XHS_COOKIES:-}" ]; then
  printf '%s' "$XHS_COOKIES" | xhs-cookies-import || echo "XHS_COOKIES could not be parsed"
fi

# 推特：TWITTER_COOKIES（JSON 或 Header String）或 TWITTER_AUTH_TOKEN + TWITTER_CT0
if [ -n "${TWITTER_COOKIES:-}" ] || { [ -n "${TWITTER_AUTH_TOKEN:-}" ] && [ -n "${TWITTER_CT0:-}" ]; }; then
  python3 - <<'PY'
import json, os
raw = os.environ.get("TWITTER_COOKIES", "").strip()
vals = {"auth_token": os.environ.get("TWITTER_AUTH_TOKEN", ""), "ct0": os.environ.get("TWITTER_CT0", "")}
if raw.startswith("["):
    for c in json.loads(raw):
        if c.get("name") in vals:
            vals[c["name"]] = c["value"]
elif raw:
    for part in raw.split(";"):
        if "=" in part:
            k, v = part.split("=", 1)
            if k.strip() in vals:
                vals[k.strip()] = v.strip()
if vals["auth_token"] and vals["ct0"]:
    path = os.path.expanduser("~/.agent-reach/twitter.env")
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(f"export TWITTER_AUTH_TOKEN={vals['auth_token']}\nexport TWITTER_CT0={vals['ct0']}\n")
    print("saved twitter cookies")
else:
    print("twitter cookies incomplete: need auth_token and ct0")
PY
fi

[ -f "$AR_HOME/xhs-cookies.json" ] && xhs-mcp-start
research-check
EOF
chmod +x "$BIN_DIR/research-init"

# research-check：检查各网站是否可用，输出 Markdown 表格并写入 ~/.agent-reach/health-report.md
cat > "$BIN_DIR/research-check" <<'EOF'
#!/usr/bin/env python3
"""检查各调研渠道是否可用，输出 Markdown 表格。"""
import json, os, random, re, socket, subprocess, threading, time, urllib.request
from concurrent.futures import ThreadPoolExecutor

AR = os.path.expanduser("~/.agent-reach")
REPORT = os.path.join(AR, "health-report.md")
QUERY = "Claude Code"
# 小红书短时间内重复搜同一个词会被限流，检查时随机换常见词
XHS_WORDS = ["咖啡", "露营", "读书", "健身", "旅行", "做饭"]
# NODE_NO_WARNINGS：Node 的代理实验特性警告会混进输出，弄坏 JSON 解析
ENV = dict(os.environ, NODE_USE_ENV_PROXY="1", NODE_NO_WARNINGS="1")
# mcporter 不认 \uXXXX 转义，中文参数必须原样传
q = lambda v: json.dumps(v, ensure_ascii=False)
UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/133 Safari/537.36"

OK, WARN, FAIL, NO = "✅ 可用", "⚠️ 部分可用", "❌ 不可用", "🚫 不支持"


def run(cmd, timeout=120, env=ENV):
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, env=env)
        return p.returncode, p.stdout + p.stderr
    except subprocess.TimeoutExpired:
        return -1, "timeout"
    except FileNotFoundError as e:
        return -2, str(e)


def mcp(call, timeout=150, json_out=False):
    cmd = ["mcporter", "call", "--timeout", str(timeout * 1000)]
    if json_out:
        cmd += ["--output", "json"]
    return run(cmd + [call], timeout=timeout + 30)


def http_get(url, timeout=25):
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read().decode("utf-8", "replace")


# Exa 免费接口并发请求会被限流：串行调用，失败重试一次
EXA_LOCK = threading.Lock()


def exa_call(call, ok):
    out = ""
    for attempt in range(2):
        with EXA_LOCK:
            _, out = mcp(call, 90)
        if ok(out):
            break
        time.sleep(3)
    return out


def exa_search(query, objective):
    out = exa_call(f"exa.web_search_exa(query: {q(query)}, numResults: 5, objective: {q(objective)})",
                   lambda o: "URL:" in o)
    return re.findall(r"^URL:\s*(\S+)", out, re.M)


def exa_fetch(url):
    return exa_call(f"exa.web_fetch_exa(urls: [{q(url)}], maxCharacters: 2000)", lambda o: len(o) > 300)


def port_open(port):
    with socket.socket() as s:
        s.settimeout(2)
        return s.connect_ex(("127.0.0.1", port)) == 0


# ---------- 各项检查：返回 (状态, 说明) ----------

def check_exa():
    urls = exa_search(QUERY, "general web results")
    return (OK, f"搜索 “{QUERY}” 返回 {len(urls)} 条结果") if urls else (FAIL, "Exa 搜索没有返回结果")


def check_jina():
    text = http_get("https://r.jina.ai/https://example.com")
    if "URL Source:" in text and "Markdown Content:" in text:
        return (OK, "读取网页正文成功")
    return (FAIL, "Jina Reader 返回内容异常")


def check_xhs():
    if not os.path.exists(os.path.join(AR, "xhs-cookies.json")):
        return (WARN, "已安装，但未配置 Cookie（环境变量 XHS_COOKIES）")
    if not port_open(18060):
        run(["xhs-mcp-start"], timeout=200)
    if not port_open(18060):
        return (FAIL, "小红书 MCP 服务没有启动，见 ~/.agent-reach/logs/xiaohongshu-mcp.log")
    _, out = mcp("xiaohongshu.check_login_status()", 120)
    if "已登录" not in out:
        return (FAIL, "Cookie 已失效或未登录，请重新导出 Cookie")
    user = re.search(r"用户名:\s*(\S+)", out)
    feeds, empty = [], False
    words = random.sample(XHS_WORDS, 2)
    for word in words:  # 搜索页偶尔加载超时，换个词重试一次
        _, out = mcp(f"xiaohongshu.search_feeds(keyword: {q(word)})", 150, json_out=True)
        try:
            d = json.loads(out)
            txt = d["content"][0]["text"] if isinstance(d, dict) and "content" in d else d
            data = json.loads(txt) if isinstance(txt, str) else txt
            feeds = data.get("feeds", []) if isinstance(data, dict) else data
            empty = isinstance(data, dict) and "feeds" in data
        except Exception:
            feeds = []
        if feeds:
            break
    who = f"已登录（{user.group(1)}）" if user else "已登录"
    if feeds:
        return (OK, f"{who}，搜索 “{word}” 返回 {len(feeds)} 条笔记")
    if empty:
        return (WARN, f"{who}，但搜索返回 0 条（可能触发风控，过一阵再试；持续出现请检查小红书 MCP 补丁）")
    return (WARN, f"{who}，但搜索超时（小红书页面加载慢或触发风控，稍后重试）")


def check_twitter():
    env = dict(ENV)
    path = os.path.join(AR, "twitter.env")
    if os.path.exists(path):
        for line in open(path):
            m = re.match(r"export (\w+)=(.*)", line.strip())
            if m:
                env.setdefault(m.group(1), m.group(2))
    if not (env.get("TWITTER_AUTH_TOKEN") and env.get("TWITTER_CT0")):
        return (WARN, "已安装，但未配置 Cookie（环境变量 TWITTER_COOKIES）")
    _, out = run(["twitter", "-c", "search", QUERY, "-n", "3"], timeout=90, env=env)
    if re.search(r"ok:\s*true", out):
        return (OK, f"搜索 “{QUERY}” 成功")
    if "not_authenticated" in out or "403" in out:
        return (FAIL, "X 拒绝请求（403）：X 屏蔽了云服务器 IP（游客请求同样被拒），需在本地电脑使用")
    return (FAIL, "搜索失败：" + out.strip().splitlines()[-1][:80] if out.strip() else "搜索失败")


def via_exa(domain, query, objective):
    urls = []
    for _ in range(2):  # Exa 偶尔不返回目标网站的结果，再搜一次
        urls = [u for u in exa_search(query, objective) if domain in u]
        if urls:
            break
    if not urls:
        return (FAIL, f"搜索没有返回 {domain} 的结果")
    text = exa_fetch(urls[0])
    if len(text) > 300 and "blocked by network security" not in text:
        return (OK, f"直连被封，经 Exa 中转：搜到 {len(urls)} 条，正文可读")
    return (WARN, f"经 Exa 搜到 {len(urls)} 条，但正文读取失败")


def check_reddit():
    return via_exa("reddit.com", "reddit r/ClaudeAI Claude Code tips discussion", "Reddit threads only")


def check_linuxdo():
    return via_exa("linux.do", f"{QUERY} site:linux.do", "linux.do 论坛帖子")


def check_csdn():
    return via_exa("csdn.net", f"{QUERY} 教程 site:csdn.net", "CSDN 博客文章")


def check_github():
    code, _ = run(["git", "ls-remote", "https://github.com/anthropics/claude-code", "HEAD"], timeout=30)
    if code == 0:
        return (OK, "可克隆/读取仓库；代码和 Issue 搜索用 Claude 内置的 GitHub 工具")
    return (FAIL, "无法访问 github.com")


def check_youtube():
    _, out = run(["yt-dlp", "--flat-playlist", "--print", "title", f"ytsearch3:{QUERY}"], timeout=60)
    titles = [l for l in out.splitlines() if l.strip() and not l.startswith(("WARNING", "ERROR"))]
    if titles:
        return (OK, f"搜索返回 {len(titles)} 个视频（下载字幕可能需要 YouTube Cookie）")
    return (FAIL, "yt-dlp 搜索失败")


def check_v2ex():
    data = json.loads(http_get("https://www.v2ex.com/api/topics/hot.json"))
    return (OK, f"热门主题接口返回 {len(data)} 条") if data else (FAIL, "接口没有返回内容")


def check_discord():
    return (NO, "内容不公开；需要群管理员把机器人拉进群才能读")


CHECKS = [
    ("全网搜索（Exa）", check_exa),
    ("网页读取（Jina）", check_jina),
    ("小红书", check_xhs),
    ("X / 推特", check_twitter),
    ("Reddit", check_reddit),
    ("linux.do", check_linuxdo),
    ("CSDN", check_csdn),
    ("GitHub", check_github),
    ("YouTube", check_youtube),
    ("V2EX", check_v2ex),
    ("Discord", check_discord),
]


def safe(fn):
    try:
        return fn()
    except Exception as e:
        return (FAIL, f"检查出错：{type(e).__name__}: {str(e)[:80]}")


def main():
    with ThreadPoolExecutor(max_workers=len(CHECKS)) as pool:
        results = list(pool.map(lambda c: safe(c[1]), CHECKS))
    lines = [
        f"调研渠道检查（{time.strftime('%Y-%m-%d %H:%M:%S %Z')}）",
        "",
        "| 网站 | 状态 | 检查结果 |",
        "|---|---|---|",
    ]
    lines += [f"| {name} | {st} | {msg} |" for (name, _), (st, msg) in zip(CHECKS, results)]
    report = "\n".join(lines)
    os.makedirs(AR, exist_ok=True)
    with open(REPORT, "w") as f:
        f.write(report + "\n")
    print(report)


if __name__ == "__main__":
    main()
EOF
chmod +x "$BIN_DIR/research-check"

# ---------- research-toolkit Skill ----------
mkdir -p "$SKILL_DIR"
cat > "$SKILL_DIR/SKILL.md" <<'EOF'
---
name: research-toolkit
description: 本环境的调研工具箱（小红书、X/推特、Reddit、linux.do、CSDN、GitHub、YouTube、V2EX、全网搜索）。新会话里第一次做网络调研/舆论调研之前，或用户说“检查调研工具”“跑一下检查”“工具能不能用”时，先用它执行 research-init 并把结果表格给用户；之后按这里的路由选择每个网站的访问方式。
---

# 调研工具箱

## 会话开始：先初始化

每个新会话第一次调研前，执行一次（约 1–3 分钟）：

```bash
research-init
```

它会从环境变量导入 Cookie（XHS_COOKIES、TWITTER_COOKIES 或 TWITTER_AUTH_TOKEN/TWITTER_CT0）、
启动小红书 MCP 服务，并运行 `research-check`。把输出的 Markdown 表格原样给用户看。
只想重新检查时运行 `research-check`；上一次结果在 `~/.agent-reach/health-report.md`。

## 各网站怎么查

| 网站 | 方法 |
|---|---|
| 全网搜索 | `mcporter call 'exa.web_search_exa(query: "...", numResults: 10, objective: "...")'` |
| 读网页正文 | `curl -s https://r.jina.ai/<URL>`；被拦时用 `mcporter call 'exa.web_fetch_exa(urls: ["<URL>"], maxCharacters: 8000)'` |
| 小红书 | `mcporter call --timeout 150000 'xiaohongshu.search_feeds(keyword: "...")'`；详情 `xiaohongshu.get_feed_detail(feed_id: "...", xsec_token: "...")`（两个值取自搜索结果） |
| Reddit | 直连被封。用 Exa 搜索（objective 写 "Reddit threads only"），再用 `exa.web_fetch_exa` 读帖子 |
| linux.do | 直连被 Cloudflare 拦。用 Exa 搜索（query 带 `site:linux.do`），再用 `exa.web_fetch_exa` 读帖子 |
| CSDN | 用 Exa 搜索（query 带 `site:csdn.net`），再用 `exa.web_fetch_exa` 或 Jina 读正文 |
| GitHub | 用 Claude 内置的 GitHub MCP 工具搜索代码/Issue；`git clone` 读仓库 |
| YouTube | `yt-dlp --flat-playlist --print "%(title)s %(url)s" "ytsearch10:..."` |
| V2EX | `curl -s https://www.v2ex.com/api/topics/hot.json` 等公开接口 |
| X / 推特 | `twitter -c search "..." -n 20`（先 `. ~/.agent-reach/twitter.env`）。云服务器 IP 通常被 X 屏蔽，失败时如实告诉用户，不要编造推文 |
| Discord | 不支持 |

其他平台和命令细节见 agent-reach Skill。

## 记录进调研档案馆

每次调研都要用 `research-site` 记录目标问题、需求、每次搜索、所有来源、分析和结论，最后 `research-site publish`
并在回复里确认“✅ 调研网站已更新”。完整流程见 CLAUDE.md 的“调研档案馆”一节，命令说明见 `research-site --help`
和 `research-site` 脚本文件开头的说明。

## 规则

- mcporter 调 Exa 前确保 `export NODE_USE_ENV_PROXY=1`（research-init 和 ~/.bashrc 已设置）。
- 小红书 MCP 调用很慢，`--timeout` 设 120000 以上；服务挂了就运行 `xhs-mcp-start`。
- 小红书是用真账号在搜，频率太高有封号风险：每次搜索间隔至少 30 秒，一轮调研控制在 10 次搜索以内；
  连续返回 0 条或超时就停下来告诉用户，不要连续重试。
- 只做读取。不要调用发帖、评论、点赞类工具（publish_content、post_comment_to_feed、like_feed 等），除非用户明确要求。
- 不要把 Cookie 的值打印到输出里，也不要提交进仓库。
EOF

# ---------- 调研档案馆 ----------
# research-site：每次调研的目标、需求、搜索记录、来源和分析存进 research/data/*.json，
# 生成 research/ 下的 HTML 网站并推送。用法见文件开头的说明。
cat > "$BIN_DIR/research-site" <<'EOF'
#!/usr/bin/env python3
"""research-site：调研档案馆。把每次调研的目标、需求、搜索记录、来源和分析存成 JSON，生成 HTML 网站并推送到 GitHub。

数据和网页都在当前仓库的 research/ 目录：
  research/data/<id>.json   每次调研的数据（唯一的数据源，网页由它生成）
  research/index.html       首页：所有调研，可搜索、按平台筛选
  research/<id>.html        调研详情页
  research/<id>.md          同内容 Markdown，GitHub 上可以直接阅读
  research/README.md        Markdown 目录

常用命令（Claude 在调研时调用）：
  research-site new "标题" --question "目标问题" --req "需求1" --req "需求2"     → 打印调研 ID
  research-site add-query ID --platform 小红书 --query "关键词" --count 20
  research-site add-sources ID < sources.json    JSON 数组或每行一个 JSON；按 url 去重
      字段：platform, category, title, url, snippet, author, date, metrics, note, query
  research-site set ID analysis < analysis.md    可设字段：title question requirements analysis conclusions status
  research-site publish [-m 说明]                生成网站 + 提交 research/ + 推送，打印提交号
  research-site publish --auto                   Stop hook 用：research/ 有改动才发布，没改动静默退出
  research-site list
"""
import argparse, datetime as dt, fcntl, glob, hashlib, html, json, os, re, subprocess, sys
from collections import Counter, OrderedDict
from urllib.parse import urlparse

try:
    from zoneinfo import ZoneInfo
    TZ = ZoneInfo(os.environ.get("CHAT_EXPORT_TZ", "Asia/Shanghai"))
except Exception:
    TZ = dt.timezone(dt.timedelta(hours=8))

LOCK = os.path.expanduser("~/.agent-reach/logs/chat-export.lock")  # 和 chat-export 共用，避免同时操作 git
STATUS = {"active": "进行中", "done": "已完成", "paused": "暂停"}


def now():
    return dt.datetime.now(TZ).strftime("%Y-%m-%d %H:%M")


def git(repo, *args):
    return subprocess.run(["git", "-C", repo, *args], capture_output=True, text=True)


def repo_root():
    r = git(os.getcwd(), "rev-parse", "--show-toplevel")
    if r.returncode != 0:
        sys.exit("不在 git 仓库里")
    return r.stdout.strip()


def paths(repo):
    base = os.path.join(repo, "research")
    return base, os.path.join(base, "data")


def load(repo, rid):
    path = os.path.join(paths(repo)[1], rid + ".json")
    if not os.path.exists(path):
        sys.exit(f"找不到调研 {rid}")
    return path, json.load(open(path, encoding="utf-8"))


def save(path, d):
    d["updated_at"] = now()
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(d, f, ensure_ascii=False, indent=2)


def all_research(repo):
    out = []
    for p in sorted(glob.glob(os.path.join(paths(repo)[1], "*.json"))):
        try:
            out.append(json.load(open(p, encoding="utf-8")))
        except ValueError:
            pass
    return sorted(out, key=lambda d: d.get("created_at", ""), reverse=True)


def domain(url):
    try:
        return urlparse(url).netloc.replace("www.", "")
    except ValueError:
        return ""


# ---------- 命令 ----------
def cmd_new(a):
    repo = repo_root()
    created = now()
    rid = dt.datetime.now(TZ).strftime("%Y-%m-%d") + "-" + hashlib.sha1((a.title + created).encode()).hexdigest()[:6]
    d = OrderedDict(id=rid, title=a.title, question=a.question or "", requirements=a.req or [],
                    status="active", created_at=created, updated_at=created,
                    analysis="", conclusions=[], queries=[], sources=[])
    save(os.path.join(paths(repo)[1], rid + ".json"), d)
    print(rid)


def cmd_add_query(a):
    path, d = load(repo_root(), a.id)
    d["queries"].append({"time": now(), "platform": a.platform, "query": a.query, "count": a.count, "note": a.note or ""})
    save(path, d)
    print(f"已记录搜索：{a.platform} · {a.query}")


def cmd_add_sources(a):
    path, d = load(repo_root(), a.id)
    raw = sys.stdin.read().strip()
    items = json.loads(raw) if raw.startswith("[") else [json.loads(l) for l in raw.splitlines() if l.strip()]
    seen = {s.get("url") for s in d["sources"] if s.get("url")}
    added = 0
    for s in items:
        if not s.get("title") and not s.get("url"):
            continue
        if s.get("url") and s["url"] in seen:
            continue
        s.setdefault("platform", domain(s.get("url", "")) or "其他")
        s.setdefault("category", "未分类")
        s["added_at"] = now()
        d["sources"].append(s)
        seen.add(s.get("url"))
        added += 1
    save(path, d)
    print(f"新增来源 {added} 条，共 {len(d['sources'])} 条")


def cmd_set(a):
    path, d = load(repo_root(), a.id)
    val = a.value if a.value is not None else sys.stdin.read()
    if a.field in ("requirements", "conclusions"):
        val = json.loads(val) if val.strip().startswith("[") else [l.strip("-• ").strip() for l in val.splitlines() if l.strip()]
    elif a.field == "status" and val.strip() not in STATUS:
        sys.exit(f"status 只能是 {', '.join(STATUS)}")
    else:
        val = val.strip()
    d[a.field] = val
    save(path, d)
    print(f"已更新 {a.field}")


def cmd_list(a):
    for d in all_research(repo_root()):
        print(f"{d['id']}  [{STATUS.get(d.get('status'), d.get('status'))}]  {d['title']}  来源 {len(d['sources'])} 条")


def cmd_build(a):
    repo = repo_root()
    build(repo)
    print(os.path.join(paths(repo)[0], "index.html"))


def cmd_publish(a):
    repo = repo_root()
    base = paths(repo)[0]
    if a.auto and not os.path.isdir(base):
        return
    os.makedirs(os.path.dirname(LOCK), exist_ok=True)
    with open(LOCK, "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if a.auto and not git(repo, "status", "--porcelain", "--", "research").stdout.strip():
            return
        build(repo)
        git(repo, "add", "--", "research")
        if git(repo, "diff", "--cached", "--quiet", "--", "research").returncode == 0:
            print("调研网站没有变化")
            return
        changed = git(repo, "diff", "--cached", "--name-only", "--", "research").stdout.split()
        msg = a.message or "research: 更新调研网站"
        git(repo, "commit", "-q", "-m", msg, "--", "research")
        sha = git(repo, "rev-parse", "--short", "HEAD").stdout.strip()
        branch = git(repo, "rev-parse", "--abbrev-ref", "HEAD").stdout.strip()
        push = git(repo, "push", "-q", "origin", branch) if branch and branch != "HEAD" else None
        ok = push is not None and push.returncode == 0
        print(f"{'已推送' if ok else '已提交（推送失败）'} {sha}：{msg}")
        for f in changed:
            print("  " + f)


# ---------- 渲染 ----------
CSS = """
:root{--bg:#f7f6f3;--fg:#1d1d1b;--muted:#6b6a66;--card:#fff;--line:#e3e1db;--accent:#c96442;--chip:#efede8;--bar:#d9a48f}
@media (prefers-color-scheme:dark){:root{--bg:#1a1a19;--fg:#ecebe7;--muted:#a19f99;--card:#242423;--line:#3a3936;--accent:#e08a6a;--chip:#2f2e2c;--bar:#9a5a43}}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--fg);font:15px/1.65 -apple-system,BlinkMacSystemFont,"Segoe UI","PingFang SC","Microsoft YaHei",sans-serif}
a{color:var(--accent)}
.wrap{max-width:1100px;margin:0 auto;padding:24px 16px 80px}
header h1{font-size:24px;margin:0 0 4px}
.meta{color:var(--muted);font-size:13px}
.stats{display:flex;gap:12px;flex-wrap:wrap;margin:20px 0}
.stat{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:10px 16px;min-width:120px}
.stat b{display:block;font-size:22px}
.stat span{color:var(--muted);font-size:12px}
.card{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:16px 18px;margin:12px 0}
.card h2,.card h3{margin:0 0 6px;font-size:17px}
section{margin:28px 0}
.card+h2{margin-top:28px}
section>h2{font-size:15px;color:var(--accent);border-bottom:1px solid var(--line);padding-bottom:6px}
.chip{display:inline-block;background:var(--chip);border-radius:999px;padding:1px 10px;font-size:12px;margin:2px 4px 2px 0;color:var(--muted)}
button.chip{border:1px solid var(--line);cursor:pointer;font:inherit;font-size:12px}
button.chip.on{background:var(--accent);color:#fff;border-color:var(--accent)}
input.search{width:100%;padding:10px 12px;border:1px solid var(--line);border-radius:8px;background:var(--card);color:var(--fg);font:inherit}
table{border-collapse:collapse;width:100%;font-size:13px;display:block;overflow:auto}
th,td{border-bottom:1px solid var(--line);padding:6px 8px;text-align:left;vertical-align:top}
.src{border-left:3px solid var(--line);padding:8px 12px;margin:8px 0;background:var(--card);border-radius:0 8px 8px 0}
.src .t{font-weight:600}
.src .s{color:var(--muted);font-size:13px;margin-top:2px;white-space:pre-wrap}
.bars div{display:flex;align-items:center;gap:8px;font-size:13px;margin:3px 0}
.bars i{display:inline-block;height:10px;background:var(--bar);border-radius:3px}
.md{overflow-wrap:anywhere}
.md.plain{white-space:pre-wrap}
.md table{display:table}
.md td{min-width:4.5em}
ul.req{margin:0;padding-left:20px}
.hidden{display:none}
"""

MD_JS = """<script src="https://cdnjs.cloudflare.com/ajax/libs/marked/12.0.2/marked.min.js"></script>
<script src="https://cdnjs.cloudflare.com/ajax/libs/dompurify/3.1.6/purify.min.js"></script>
<script>
if (window.marked && window.DOMPurify) document.querySelectorAll('.md.plain').forEach(function (el) {
  el.innerHTML = DOMPurify.sanitize(marked.parse(el.textContent)); el.classList.remove('plain');
});
</script>"""

FILTER_JS = """<script>
(function () {
  var q = document.getElementById('q'), active = null;
  function apply() {
    var text = (q ? q.value : '').toLowerCase();
    document.querySelectorAll('[data-filter]').forEach(function (el) {
      var okText = !text || el.textContent.toLowerCase().indexOf(text) >= 0;
      var okPlat = !active || (el.getAttribute('data-platforms') || '').split('|').indexOf(active) >= 0;
      el.classList.toggle('hidden', !(okText && okPlat));
    });
  }
  if (q) q.addEventListener('input', apply);
  document.querySelectorAll('button.chip[data-p]').forEach(function (b) {
    b.addEventListener('click', function () {
      active = active === b.dataset.p ? null : b.dataset.p;
      document.querySelectorAll('button.chip[data-p]').forEach(function (x) { x.classList.toggle('on', x.dataset.p === active); });
      apply();
    });
  });
})();
</script>"""


def page(title, body, scripts=""):
    return (f'<!doctype html>\n<html lang="zh-CN"><head><meta charset="utf-8">'
            f'<meta name="viewport" content="width=device-width, initial-scale=1"><title>{html.escape(title)}</title>'
            f"<style>{CSS}</style></head><body><div class=\"wrap\">{body}</div>{scripts}</body></html>\n")


def e(x):
    return html.escape(str(x or ""))


def bars(counter):
    if not counter:
        return ""
    top = max(counter.values())
    return '<div class="bars">' + "".join(
        f'<div><span style="width:90px">{e(k)}</span><i style="width:{int(240 * v / top)}px"></i>{v}</div>'
        for k, v in counter.most_common()) + "</div>"


def render_detail(d):
    srcs = d.get("sources", [])
    plats = Counter(s.get("platform", "其他") for s in srcs)
    cats = Counter(s.get("category", "未分类") for s in srcs)
    head = (f'<p class="meta"><a href="index.html">← 全部调研</a></p><header><h1>{e(d["title"])}</h1>'
            f'<div class="meta">{e(STATUS.get(d.get("status"), d.get("status")))} · 创建 {e(d.get("created_at"))} · '
            f'更新 {e(d.get("updated_at"))} · ID {e(d["id"])}</div></header>')
    stats = (f'<div class="stats"><div class="stat"><b>{len(srcs)}</b><span>条来源</span></div>'
             f'<div class="stat"><b>{len(plats)}</b><span>个平台</span></div>'
             f'<div class="stat"><b>{len(d.get("queries", []))}</b><span>次搜索</span></div></div>')
    goal = (f'<section><h2>目标问题</h2><div class="card">{e(d.get("question")) or "（未填写）"}</div>'
            f'<h2>具体需求</h2><div class="card"><ul class="req">'
            + "".join(f"<li>{e(r)}</li>" for r in d.get("requirements", [])) + "</ul></div></section>")
    concl = ""
    if d.get("conclusions"):
        concl = '<section><h2>结论摘要</h2><div class="card"><ul class="req">' + "".join(
            f"<li>{e(c)}</li>" for c in d["conclusions"]) + "</ul></div></section>"
    analysis = (f'<section><h2>分析</h2><div class="card md plain">{e(d.get("analysis")) or "（尚未分析）"}</div></section>')
    dist = (f'<section><h2>来源分布</h2><div class="card" style="display:flex;gap:40px;flex-wrap:wrap">'
            f'<div><div class="meta">按平台</div>{bars(plats)}</div><div><div class="meta">按分类</div>{bars(cats)}</div></div></section>')
    chips = "".join(f'<button class="chip" data-p="{e(p)}">{e(p)} {n}</button>' for p, n in plats.most_common())
    by_cat = OrderedDict()
    for s in srcs:
        by_cat.setdefault(s.get("category", "未分类"), []).append(s)
    src_html = []
    for cat, items in by_cat.items():
        src_html.append(f'<h3 style="font-size:14px;margin:18px 0 6px">{e(cat)}（{len(items)}）</h3>')
        for s in items:
            meta = " · ".join(x for x in [s.get("platform"), domain(s.get("url", "")), s.get("author"),
                                          s.get("date"), s.get("metrics")] if x)
            title = (f'<a href="{e(s["url"])}" target="_blank" rel="noopener">{e(s.get("title") or s["url"])}</a>'
                     if s.get("url") else e(s.get("title")))
            src_html.append(
                f'<div class="src" data-filter data-platforms="{e(s.get("platform", "其他"))}">'
                f'<div class="t">{title}</div><div class="meta">{e(meta)}</div>'
                + (f'<div class="s">{e(s.get("snippet"))}</div>' if s.get("snippet") else "")
                + (f'<div class="s">📝 {e(s.get("note"))}</div>' if s.get("note") else "") + "</div>")
    sources = (f'<section><h2>全部来源</h2><input id="q" class="search" placeholder="在来源里搜索…">'
               f'<div style="margin:8px 0">{chips}</div>{"".join(src_html) or "<p class=meta>暂无</p>"}</section>')
    qrows = "".join(f"<tr><td>{e(q.get('time'))}</td><td>{e(q.get('platform'))}</td><td>{e(q.get('query'))}</td>"
                    f"<td>{e(q.get('count'))}</td><td>{e(q.get('note'))}</td></tr>" for q in d.get("queries", []))
    queries = (f'<section><h2>搜索记录</h2><table><tr><th>时间</th><th>平台</th><th>搜索词</th><th>结果数</th><th>备注</th></tr>'
               f"{qrows}</table></section>")
    return page(d["title"], head + stats + goal + concl + analysis + dist + sources + queries, MD_JS + FILTER_JS)


def render_index(items):
    total = sum(len(d.get("sources", [])) for d in items)
    plats = Counter(s.get("platform", "其他") for d in items for s in d.get("sources", []))
    cards = []
    for d in items:
        ps = Counter(s.get("platform", "其他") for s in d.get("sources", []))
        cards.append(
            f'<div class="card" data-filter data-platforms="{e("|".join(ps))}"><h2><a href="{e(d["id"])}.html">{e(d["title"])}</a></h2>'
            f'<div class="meta">{e(STATUS.get(d.get("status"), d.get("status")))} · {e(d.get("created_at"))} · '
            f'来源 {len(d.get("sources", []))} 条 · 搜索 {len(d.get("queries", []))} 次</div>'
            f'<p>{e(d.get("question"))}</p>' + "".join(f'<span class="chip">{e(p)} {n}</span>' for p, n in ps.most_common())
            + "</div>")
    chips = "".join(f'<button class="chip" data-p="{e(p)}">{e(p)} {n}</button>' for p, n in plats.most_common())
    body = (f'<header><h1>调研档案馆</h1><div class="meta">最后更新 {now()} · 每次调研后自动更新</div></header>'
            f'<div class="stats"><div class="stat"><b>{len(items)}</b><span>次调研</span></div>'
            f'<div class="stat"><b>{total}</b><span>条来源</span></div><div class="stat"><b>{len(plats)}</b><span>个平台</span></div></div>'
            f'<input id="q" class="search" placeholder="搜索调研标题、问题…"><div style="margin:8px 0">{chips}</div>'
            + ("".join(cards) or '<p class="meta">还没有调研记录</p>'))
    return page("调研档案馆", body, FILTER_JS)


def render_md(d):
    out = [f"# {d['title']}", "", f"{STATUS.get(d.get('status'), d.get('status'))} · 创建 {d.get('created_at')} · 更新 {d.get('updated_at')}", "",
           "## 目标问题", "", d.get("question") or "（未填写）", "", "## 具体需求", ""]
    out += [f"- {r}" for r in d.get("requirements", [])] + [""]
    if d.get("conclusions"):
        out += ["## 结论摘要", ""] + [f"- {c}" for c in d["conclusions"]] + [""]
    analysis = re.sub(r"(?m)^#{1,6}\s+(.+)$", r"**\1**", d.get("analysis") or "（尚未分析）")
    out += ["## 分析", "", analysis, "", "## 全部来源", ""]
    by_cat = OrderedDict()
    for s in d.get("sources", []):
        by_cat.setdefault(s.get("category", "未分类"), []).append(s)
    for cat, items in by_cat.items():
        out += [f"### {cat}（{len(items)}）", ""]
        for s in items:
            t = f"[{s.get('title') or s['url']}]({s['url']})" if s.get("url") else s.get("title", "")
            meta = " · ".join(x for x in [s.get("platform"), s.get("author"), s.get("date"), s.get("metrics")] if x)
            out.append(f"- {t}" + (f" — {meta}" if meta else ""))
            if s.get("snippet"):
                out.append(f"  > {s['snippet'][:300].replace(chr(10), ' ')}")
        out.append("")
    out += ["## 搜索记录", "", "| 时间 | 平台 | 搜索词 | 结果数 |", "|---|---|---|---|"]
    out += [f"| {q.get('time')} | {q.get('platform')} | {q.get('query')} | {q.get('count')} |" for q in d.get("queries", [])]
    return "\n".join(out) + "\n"


def build(repo):
    base, data = paths(repo)
    os.makedirs(data, exist_ok=True)
    items = all_research(repo)
    for d in items:
        open(os.path.join(base, d["id"] + ".html"), "w", encoding="utf-8").write(render_detail(d))
        open(os.path.join(base, d["id"] + ".md"), "w", encoding="utf-8").write(render_md(d))
    open(os.path.join(base, "index.html"), "w", encoding="utf-8").write(render_index(items))
    md = ["# 调研档案馆", "", "每次调研后自动更新。网页版：下载 `index.html` 用浏览器打开。", "",
          "| 日期 | 调研 | 来源数 | 状态 |", "|---|---|---|---|"]
    md += [f"| {d.get('created_at', '')[:10]} | [{d['title']}]({d['id']}.md) | {len(d.get('sources', []))} | "
           f"{STATUS.get(d.get('status'), d.get('status'))} |" for d in items]
    open(os.path.join(base, "README.md"), "w", encoding="utf-8").write("\n".join(md) + "\n")


def main():
    ap = argparse.ArgumentParser(description="调研档案馆")
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("new"); p.add_argument("title"); p.add_argument("--question"); p.add_argument("--req", action="append")
    p.set_defaults(fn=cmd_new)
    p = sub.add_parser("add-query"); p.add_argument("id"); p.add_argument("--platform", required=True)
    p.add_argument("--query", required=True); p.add_argument("--count", type=int); p.add_argument("--note")
    p.set_defaults(fn=cmd_add_query)
    p = sub.add_parser("add-sources"); p.add_argument("id"); p.set_defaults(fn=cmd_add_sources)
    p = sub.add_parser("set"); p.add_argument("id")
    p.add_argument("field", choices=["title", "question", "requirements", "analysis", "conclusions", "status"])
    p.add_argument("value", nargs="?"); p.set_defaults(fn=cmd_set)
    p = sub.add_parser("list"); p.set_defaults(fn=cmd_list)
    p = sub.add_parser("build"); p.set_defaults(fn=cmd_build)
    p = sub.add_parser("publish"); p.add_argument("-m", "--message"); p.add_argument("--auto", action="store_true")
    p.set_defaults(fn=cmd_publish)
    a = ap.parse_args()
    a.fn(a)


if __name__ == "__main__":
    main()
EOF
chmod +x "$BIN_DIR/research-site"

# ---------- 对话记录自动导出 ----------
# chat-export：每次 Claude 回复结束后（Stop hook）把对话转成 HTML + Markdown，提交并推送到 chat-logs/。
# 只在仓库根目录有 .chat-export-on 文件时运行。
cat > "$BIN_DIR/chat-export" <<'EOF'
#!/usr/bin/env python3
"""chat-export：把 Claude Code 对话记录（JSONL）转换成 HTML + Markdown，提交并推送到当前仓库。

作为 Stop hook 使用：每次 Claude 回复结束后，Claude Code 把 {"transcript_path", "session_id", "cwd"}
通过 stdin 传进来。也可以手动运行：chat-export --transcript <file.jsonl> [--no-push]

输出到 <仓库>/chat-logs/：
  <日期>_<会话ID前8位>.html   按时间段分组的网页
  <日期>_<会话ID前8位>.md     同内容的 Markdown，GitHub 上可以直接阅读
  index.html / README.md       会话列表

只在仓库根目录有 .chat-export-on 文件时运行（按仓库开启，避免把对话推到公开仓库）。
隐私：Cookie、Token 等会被替换成 [已隐藏]；工具调用只记录工具名和一句话说明，不记录命令和输出。
"""
import argparse, datetime as dt, fcntl, glob, html, json, os, re, subprocess, sys

TZ_NAME = os.environ.get("CHAT_EXPORT_TZ", "Asia/Shanghai")
OUT_DIR = "chat-logs"
LOG = os.path.expanduser("~/.agent-reach/logs/chat-export.log")

try:
    from zoneinfo import ZoneInfo
    TZ = ZoneInfo(TZ_NAME)
except Exception:
    TZ = dt.timezone(dt.timedelta(hours=8))

# ---------- 脱敏 ----------
SECRET_KEYS = ("auth_token|ct0|web_session|id_token|a1|webId|web_session_id|gid|cf_clearance|__cf_bm|"
               "twid|personalization_id|guest_id\\w*|acw_tc|websectiga|sec_poison_id|xsecappid|abRequestId|"
               "loadts|unread|customerClientId|token|password|passwd|secret|api_key|apikey")


def known_secrets():
    """读取本机保存的 Cookie 文件，把里面的值都当作需要隐藏的字符串。"""
    vals = set()
    home = os.path.expanduser("~/.agent-reach")
    for path in glob.glob(os.path.join(home, "*.json")) + glob.glob(os.path.join(home, "*.env")):
        try:
            text = open(path).read()
        except OSError:
            continue
        vals.update(re.findall(r'"value"\s*:\s*"([^"]{8,})"', text))
        vals.update(re.findall(r"=([^\s;]{8,})", text))
    for k, v in os.environ.items():
        if re.search(r"COOKIE|TOKEN|SECRET|KEY|CT0", k) and len(v) >= 8:
            vals.add(v)
            vals.update(x for x in re.findall(r"=([^\s;]{8,})", v))
    return sorted(vals, key=len, reverse=True)


def redact(text, secrets):
    for s in secrets:
        text = text.replace(s, "[已隐藏]")
    # Cookie-Editor JSON 里的 "value": "..."
    text = re.sub(r'("value"\s*:\s*)"(?:[^"\\]|\\.)*"', r'\1"[已隐藏]"', text)
    # name=value 形式的敏感字段
    text = re.sub(r"(?i)\b(%s)\s*=\s*[^\s;,\"']+" % SECRET_KEYS, r"\1=[已隐藏]", text)
    # 环境变量形式
    text = re.sub(r"\b((?:XHS|TWITTER)_[A-Z_]*)=\S.*", r"\1=[已隐藏]", text)
    return text


# ---------- 读取 JSONL ----------
REMINDER = re.compile(r"<system-reminder>.*?</system-reminder>", re.S)


def ts(rec):
    t = rec.get("timestamp")
    if not t:
        return None
    try:
        return dt.datetime.fromisoformat(t.replace("Z", "+00:00")).astimezone(TZ)
    except ValueError:
        return None


def user_text(content):
    if isinstance(content, str):
        parts, images = [content], 0
    else:
        parts = [c.get("text", "") for c in content if c.get("type") == "text"]
        images = sum(1 for c in content if c.get("type") == "image")
    text = REMINDER.sub("", "\n".join(parts)).strip()
    text = re.sub(r"\[Image: source: [^\]]*\]", "", text).strip()
    if text.startswith("<task-notification>") or text.startswith("<command-"):
        return None
    if images:
        text = (text + f"\n\n*（附图 {images} 张）*").strip()
    return text or None


def load(path):
    """返回消息列表：{"role": user/assistant/tools, "time": datetime, "text": str 或 tools: [...]}。"""
    msgs = []
    for line in open(path, encoding="utf-8"):
        try:
            rec = json.loads(line)
        except ValueError:
            continue
        if rec.get("isSidechain") or rec.get("isMeta"):
            continue
        msg = rec.get("message")
        if not isinstance(msg, dict):
            continue
        t = ts(rec)
        content = msg.get("content")
        if rec.get("type") == "user" and msg.get("role") == "user":
            if isinstance(content, list) and all(c.get("type") == "tool_result" for c in content):
                continue
            text = user_text(content)
            if text:
                msgs.append({"role": "user", "time": t, "text": text})
        elif rec.get("type") == "assistant" and isinstance(content, list):
            for c in content:
                if c.get("type") == "text" and c.get("text", "").strip():
                    msgs.append({"role": "assistant", "time": t, "text": c["text"].strip()})
                elif c.get("type") == "tool_use":
                    inp = c.get("input") or {}
                    desc = inp.get("description") or inp.get("query") or inp.get("skill") or ""
                    if not desc and inp.get("file_path"):
                        desc = os.path.basename(str(inp["file_path"]))
                    item = (c.get("name", "tool"), str(desc)[:120])
                    if msgs and msgs[-1]["role"] == "tools":
                        msgs[-1]["tools"].append(item)
                    else:
                        msgs.append({"role": "tools", "time": t, "tools": [item]})
    return msgs


# ---------- 渲染 ----------
def period(t):
    """时间段：按小时分组。"""
    return t.strftime("%Y-%m-%d %H:00") + "–" + (t + dt.timedelta(hours=1)).strftime("%H:00") if t else "未知时间"


def first_line(msgs):
    for m in msgs:
        if m["role"] == "user":
            line = m["text"].strip().splitlines()[0]
            return line[:60] + ("…" if len(line) > 60 else "")
    return "对话"


def demote(text):
    """消息正文里的标题改成粗体，避免和时间段标题混在一起。"""
    return re.sub(r"(?m)^#{1,6}\s+(.+)$", r"**\1**", text)


def render_md(msgs, title, session_id):
    out = [f"# {title}", "", f"会话 `{session_id}` · 时区 {TZ_NAME} · 自动生成，请勿手动编辑", ""]
    cur = None
    for m in msgs:
        p = period(m["time"])
        if p != cur:
            out += [f"## {p}", ""]
            cur = p
        hm = m["time"].strftime("%H:%M") if m["time"] else ""
        if m["role"] == "user":
            out += [f"### 🧑 用户 · {hm}", "", demote(m["text"]), ""]
        elif m["role"] == "assistant":
            out += [f"### 🤖 Claude · {hm}", "", demote(m["text"]), ""]
        else:
            names = "、".join(f"{n}（{d}）" if d else n for n, d in m["tools"])
            out += [f"<details><summary>🔧 工具调用 {len(m['tools'])} 次</summary>", "", names, "", "</details>", ""]
    return "\n".join(out)


HTML_TMPL = """<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>__TITLE__</title>
<style>
:root{--bg:#faf9f7;--fg:#1f1f1f;--muted:#6b6b6b;--card:#fff;--user:#eef4ff;--line:#e4e2dd;--accent:#c96442}
@media (prefers-color-scheme:dark){:root{--bg:#1b1b1a;--fg:#ececea;--muted:#a3a39e;--card:#252524;--user:#1f2a3d;--line:#3a3a38;--accent:#e08a6a}}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--fg);font:15px/1.65 -apple-system,BlinkMacSystemFont,"Segoe UI","PingFang SC","Microsoft YaHei",sans-serif}
.wrap{display:flex;max-width:1200px;margin:0 auto}
nav{position:sticky;top:0;align-self:flex-start;width:220px;height:100vh;overflow:auto;padding:24px 12px;border-right:1px solid var(--line);font-size:13px}
nav a{display:block;padding:4px 8px;color:var(--muted);text-decoration:none;border-radius:6px}
nav a:hover{background:var(--card);color:var(--fg)}
main{flex:1;min-width:0;padding:24px 16px 80px}
h1{font-size:22px;margin:0 0 4px}
.meta{color:var(--muted);font-size:13px;margin-bottom:24px}
main>h2{font-size:14px;color:var(--accent);border-bottom:1px solid var(--line);padding-bottom:6px;margin:32px 0 16px;position:sticky;top:0;background:var(--bg);z-index:1}
.body h1,.body h2,.body h3{font-size:16px;margin:12px 0 6px}
.msg{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:12px 16px;margin:12px 0}
.msg.user{background:var(--user)}
.who{font-size:12px;color:var(--muted);margin-bottom:4px}
.body{overflow-wrap:anywhere}
.body pre{background:var(--bg);border:1px solid var(--line);border-radius:6px;padding:10px;overflow:auto;font-size:13px}
.body code{font-size:13px}
.body table{border-collapse:collapse;display:block;overflow:auto}
.body th,.body td{border:1px solid var(--line);padding:4px 8px}
.plain{white-space:pre-wrap}
details.tools{color:var(--muted);font-size:12px;margin:4px 0 4px 8px}
@media (max-width:760px){nav{display:none}main{padding:16px}}
</style>
</head>
<body>
<div class="wrap">
<nav><strong>时间段</strong>__NAV__</nav>
<main>
<h1>__TITLE__</h1>
<div class="meta">会话 __SID__ · 时区 __TZ__ · 最后更新 __UPDATED__ · 自动生成</div>
__BODY__
</main>
</div>
<script src="https://cdnjs.cloudflare.com/ajax/libs/marked/12.0.2/marked.min.js"></script>
<script src="https://cdnjs.cloudflare.com/ajax/libs/dompurify/3.1.6/purify.min.js"></script>
<script>
if (window.marked && window.DOMPurify) {
  document.querySelectorAll('.body.plain').forEach(function (el) {
    el.innerHTML = DOMPurify.sanitize(marked.parse(el.textContent));
    el.classList.remove('plain');
  });
}
</script>
</body>
</html>
"""


def render_html(msgs, title, session_id):
    body, nav, cur, n = [], [], None, 0
    for m in msgs:
        p = period(m["time"])
        if p != cur:
            n += 1
            body.append(f'<h2 id="p{n}">{html.escape(p)}</h2>')
            nav.append(f'<a href="#p{n}">{html.escape(p)}</a>')
            cur = p
        hm = m["time"].strftime("%H:%M") if m["time"] else ""
        if m["role"] in ("user", "assistant"):
            who = "🧑 用户" if m["role"] == "user" else "🤖 Claude"
            body.append(f'<div class="msg {m["role"]}"><div class="who">{who} · {hm}</div>'
                        f'<div class="body plain">{html.escape(m["text"])}</div></div>')
        else:
            items = "".join(f"<li>{html.escape(nm)}{'：' + html.escape(d) if d else ''}</li>" for nm, d in m["tools"])
            body.append(f'<details class="tools"><summary>🔧 工具调用 {len(m["tools"])} 次</summary><ul>{items}</ul></details>')
    updated = dt.datetime.now(TZ).strftime("%Y-%m-%d %H:%M")
    return (HTML_TMPL.replace("__TITLE__", html.escape(title)).replace("__SID__", html.escape(session_id))
            .replace("__TZ__", TZ_NAME).replace("__UPDATED__", updated)
            .replace("__NAV__", "".join(nav)).replace("__BODY__", "\n".join(body)))


def write_index(out_dir):
    rows = []
    for path in sorted(glob.glob(os.path.join(out_dir, "*.html")), reverse=True):
        name = os.path.basename(path)
        if name == "index.html":
            continue
        m = re.search(r"<title>(.*?)</title>", open(path, encoding="utf-8").read())
        rows.append((name, html.unescape(m.group(1)) if m else name))
    lis = "".join(f'<li><a href="{html.escape(n)}">{html.escape(n[:10])} · {html.escape(t)}</a></li>' for n, t in rows)
    page = HTML_TMPL.replace("__TITLE__", "对话记录").replace("__SID__", "全部").replace("__TZ__", TZ_NAME) \
        .replace("__UPDATED__", dt.datetime.now(TZ).strftime("%Y-%m-%d %H:%M")).replace("__NAV__", "") \
        .replace("__BODY__", f"<ul>{lis}</ul>")
    open(os.path.join(out_dir, "index.html"), "w", encoding="utf-8").write(page)
    md = ["# 对话记录", "", "每次 Claude 回复后自动更新。网页版见同名 .html 文件。", ""]
    md += [f"- [{n[:10]} · {t}]({n[:-5]}.md)" for n, t in rows]
    open(os.path.join(out_dir, "README.md"), "w", encoding="utf-8").write("\n".join(md) + "\n")


# ---------- git ----------
def git(repo, *args, check=False):
    return subprocess.run(["git", "-C", repo, *args], capture_output=True, text=True, check=check)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--transcript")
    ap.add_argument("--session-id")
    ap.add_argument("--cwd")
    ap.add_argument("--no-push", action="store_true", help="只生成文件，不提交也不推送")
    ap.add_argument("--source", default="manual")
    a = ap.parse_args()

    hook = {}
    if not a.transcript and not sys.stdin.isatty():
        try:
            hook = json.loads(sys.stdin.read() or "{}")
        except ValueError:
            hook = {}
    transcript = a.transcript or hook.get("transcript_path")
    session_id = a.session_id or hook.get("session_id") or os.path.basename(transcript or "").replace(".jsonl", "")
    cwd = a.cwd or hook.get("cwd") or os.getcwd()
    if not transcript or not os.path.exists(transcript):
        return 0
    if os.environ.get("CHAT_EXPORT_DISABLE") == "1":
        return 0

    top = git(cwd, "rev-parse", "--show-toplevel")
    if top.returncode != 0:
        return 0
    repo = top.stdout.strip()
    if not os.path.exists(os.path.join(repo, ".chat-export-on")):
        return 0

    os.makedirs(os.path.dirname(LOG), exist_ok=True)
    lock = open(os.path.join(os.path.dirname(LOG), "chat-export.lock"), "w")
    fcntl.flock(lock, fcntl.LOCK_EX)

    msgs = load(transcript)
    if not msgs:
        return 0
    secrets = known_secrets()
    for m in msgs:
        if "text" in m:
            m["text"] = redact(m["text"], secrets)
    title = first_line(msgs)
    day = (msgs[0]["time"] or dt.datetime.now(TZ)).strftime("%Y-%m-%d")
    base = f"{day}_{session_id[:8]}"
    out_dir = os.path.join(repo, OUT_DIR)
    os.makedirs(out_dir, exist_ok=True)
    open(os.path.join(out_dir, base + ".html"), "w", encoding="utf-8").write(render_html(msgs, title, session_id))
    open(os.path.join(out_dir, base + ".md"), "w", encoding="utf-8").write(render_md(msgs, title, session_id))
    write_index(out_dir)

    with open(LOG, "a") as f:
        f.write(f"{dt.datetime.now(TZ).isoformat()} source={a.source} repo={repo} file={base} msgs={len(msgs)}\n")
    if a.no_push:
        print(os.path.join(out_dir, base + ".html"))
        return 0

    # 只提交 chat-logs/，不碰工作区里其他未完成的改动
    for _ in range(3):
        if git(repo, "add", "--", OUT_DIR).returncode == 0:
            break
        subprocess.run(["sleep", "1"])
    if git(repo, "diff", "--cached", "--quiet", "--", OUT_DIR).returncode == 0:
        return 0
    git(repo, "commit", "-q", "-m", f"chat-logs: 更新对话记录 {base}", "--", OUT_DIR)
    branch = git(repo, "rev-parse", "--abbrev-ref", "HEAD").stdout.strip()
    if branch and branch != "HEAD":
        git(repo, "push", "-q", "origin", branch)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as e:  # hook 失败不能打断对话
        try:
            with open(LOG, "a") as f:
                f.write(f"{dt.datetime.now().isoformat()} error: {e!r}\n")
        except OSError:
            pass
        sys.exit(0)
EOF
chmod +x "$BIN_DIR/chat-export"

# 注册为用户级 Stop hook（所有项目生效；只改 hooks.Stop，保留 settings.json 里其他设置）
python3 - <<'PY'
import json, os
path = os.path.expanduser("~/.claude/settings.json")
cfg = json.load(open(path)) if os.path.exists(path) else {}
stop = cfg.setdefault("hooks", {}).setdefault("Stop", [])
bin_dir = os.environ.get("BIN_DIR", "/usr/local/bin")
wanted = (f"{bin_dir}/chat-export --source user", f"{bin_dir}/research-site publish --auto >/dev/null 2>&1 || true")
# 去掉旧版本注册的同名 hook，再按当前路径注册
stop[:] = [e for e in stop if not any(("chat-export --source user" in h.get("command", "")
                                        or "research-site publish --auto" in h.get("command", ""))
                                       and h.get("command") not in wanted for h in e.get("hooks", []))]
for cmd in wanted:
    if not any(h.get("command") == cmd for e in stop for h in e.get("hooks", [])):
        stop.append({"matcher": "", "hooks": [{"type": "command", "command": cmd, "timeout": 60}]})
os.makedirs(os.path.dirname(path), exist_ok=True)
json.dump(cfg, open(path, "w"), indent=2, ensure_ascii=False)
PY

# ---------- 用户级 CLAUDE.md：所有项目共用的工作约定 ----------
# 只替换 BEGIN/END 标记之间的内容，文件里其他内容保持不变
python3 - <<'PY'
import os, re
path = os.path.expanduser("~/.claude/CLAUDE.md")
block = """<!-- BEGIN cloud-setup -->
## 自动保存（Git）

- 每完成一个完整步骤（一个功能、一次修复、一份 Markdown/HTML 文档、一次配置改动），立即 `git add` → `git commit` → `git push` 到当前分支，不用等用户要求。
- 一个步骤一个提交，提交信息写清楚这一步做了什么，方便以后按节点回退。
- 回退用 `git revert` 生成新的提交，不用 `git reset`、`git push --force` 或改写历史，保证每个节点都留在 GitHub 上。
- 推送前确认没有把 Cookie、Token、`.env` 等密钥加进提交。
- 推送完成后，在回复里告诉用户提交号和一句话说明。
- 不要自动创建或合并 PR，除非用户明确要求。
- 每次回复的最后，用一个简短的「本次自动更新」小节汇报：这一轮提交了哪些提交（提交号 + 一句话）、改了哪些文件；没有改动就写“无代码改动”。

## 对话记录

- 仓库根目录有 `.chat-export-on` 时，每次回复结束后 Stop hook 会运行 `chat-export`，把对话转成 `chat-logs/` 下的 HTML 和 Markdown 并自动提交推送（这个提交发生在回复之后，汇报里写“对话记录将在回复后自动更新”即可）。
- 用户在某个项目里说“开启对话记录”时：先确认仓库是私有的（公开仓库要提醒用户并等确认），再创建 `.chat-export-on`，提交并推送。

## 配置的源头

- 这些全局规则、Skill、hook 和命令都由 https://github.com/NNNoxin/claude-config 的 `setup.sh` 安装。用户要求修改这些配置时，改那个仓库的 `setup.sh` 并推送，不要只改本机文件（本机改动在新环境里会丢）。

## 调研

- 做网络调研前先用 research-toolkit Skill（新会话先运行 `research-init`）。

## 调研档案馆

- 每次调研（用户让搜索、调研、查评价、找资料）都要记录进调研档案馆 `research-site`，数据在当前仓库的 `research/`：
  1. 开始时 `research-site new "标题" --question "用户的目标问题" --req "需求1" --req "需求2"`；同一主题的追问沿用原来的 ID（用 `research-site list` 查）。
  2. 每次搜索后用 `research-site add-query` 记下平台、搜索词和结果数；所有搜到的结果都用 `research-site add-sources` 登记（平台、分类、标题、链接、作者、日期、互动数据、摘要、备注），不要只登记最后引用的那几条。分类按内容分，例如“正面评价 / 负面评价 / 教程 / 新闻 / 数据”。
  3. 分析写进 `research-site set ID analysis`（Markdown），要点写进 `conclusions`；调研结束时 `research-site set ID status done`。
  4. 最后运行 `research-site publish -m "research: <标题>"`，并在回复里写一行：「✅ 调研网站已更新：<提交号> · <标题> · 共 N 条来源 · research/<ID>.html」。
- 回复结束后 Stop hook 会运行 `research-site publish --auto`，把漏发布的 `research/` 改动补传上去，这只是兜底，不能代替第 4 步。
<!-- END cloud-setup -->"""
old = open(path).read() if os.path.exists(path) else ""
pat = re.compile(r"<!-- BEGIN cloud-setup -->.*?<!-- END cloud-setup -->", re.S)
new = pat.sub(lambda _: block, old) if pat.search(old) else (old.rstrip() + "\n\n" + block if old.strip() else block) + "\n"
os.makedirs(os.path.dirname(path), exist_ok=True)
open(path, "w").write(new)
PY

# 如果环境变量里已经有 Cookie，顺便导入（不影响快照的可用性）
[ -n "${XHS_COOKIES:-}" ] && { printf '%s' "$XHS_COOKIES" | xhs-cookies-import || true; }

log "done — run research-init in each new session"
exit 0
