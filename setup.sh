#!/usr/bin/env bash
# Claude Code 一键配置 —— 调研工具箱 + 自动保存 + 对话记录 + 调研档案馆 + 自动跑实验（ARIS）
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
#   ARIS               自动科研 Skill（wanshuiyin/Auto-claude-code-research-in-sleep，仓库在 ~/aris_repo），
#                      装“实验与算力”“自动评审闭环”两组共 22 个到 ~/.claude/skills
#   aris-lab           实验项目工具：新建项目、跑实验并记录、生成看板、体检（aris-lab --help）
#   llm-chat MCP       ARIS 的审稿模型（任意 OpenAI 兼容 API），由 aris-lab reviewer 启动
#   aris-reviewer      ARIS 审稿子代理（~/.claude/agents/aris-reviewer.md）：另一个 Claude 模型 + 审稿提示，只读
#
# Cookie 放在环境设置的 Environment variables 里（不要提交到仓库，也不要贴进聊天）：
#   XHS_COOKIES        小红书 Cookie：Cookie-Editor 导出的 JSON（压成一行）或 Header String
#   TWITTER_COOKIES    推特 Cookie：同上；或者分别填 TWITTER_AUTH_TOKEN 和 TWITTER_CT0
#
# 审稿模型（可选；ARIS 用它审代码和结果，不填也能跑实验，只是没有外部审稿）：
#   LLM_PROVIDER       modelscope / deepseek / openrouter / gemini / openai / siliconflow / dashscope / moonshot / zhipu
#   LLM_API_KEY        对应平台的 API Key
#   LLM_MODEL          可选：换审稿模型（gemini / openai 等没有默认模型的必须填）；LLM_BASE_URL 可选：自定义地址

set -uo pipefail

AR_HOME="$HOME/.agent-reach"
AR_SRC="$AR_HOME/src/Agent-Reach"
AR_VENV="$HOME/.agent-reach-venv"
XHS_SRC="$AR_HOME/tools/xiaohongshu-mcp"
XHS_BIN="$AR_HOME/tools/bin/xiaohongshu-mcp"
SKILL_DIR="$HOME/.claude/skills/research-toolkit"
ARIS_DIR="$HOME/aris_repo"
ARIS_VENV="$HOME/.aris-venv"

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

install_aris() {
  log "installing ARIS"
  export GIT_LFS_SKIP_SMUDGE=1
  clone_or_update https://github.com/wanshuiyin/Auto-claude-code-research-in-sleep.git "$ARIS_DIR" || return 1
  [ -x "$ARIS_VENV/bin/pip" ] || python3 -m venv "$ARIS_VENV"
  # ARIS 自带的 llm-chat 审稿服务要用 httpx
  "$ARIS_VENV/bin/pip" install -q --disable-pip-version-check httpx pyyaml || return 1
  # 只装“实验与算力”“自动评审闭环”两组（依赖会自动带上），装到用户级 ~/.claude/skills，所有项目都能用
  (cd "$HOME" && bash "$ARIS_DIR/tools/install_aris.sh" "$HOME" --groups experiments,review-loop \
     --skip-new --no-doc --no-agent-profiles --quiet </dev/null) || return 1
  log "ARIS done"
}

install_agent_reach &
pid_ar=$!
install_xhs &
pid_xhs=$!
install_aris &
pid_aris=$!
wait "$pid_ar" || log "Agent Reach install failed"
wait "$pid_xhs" || log "xiaohongshu-mcp install failed"
wait "$pid_aris" || log "ARIS install failed"

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

# aris-lab：实验项目工具（新建项目、跑实验并记录、生成看板、体检；也负责启动审稿模型）
cat > "$BIN_DIR/aris-lab" <<'EOF'
#!/usr/bin/env python3
"""aris-lab：配合 ARIS 自动跑实验的小工具。

  aris-lab new 名字 [--title 标题] [--question 要回答的问题] [--key-metrics 指标1,指标2] [--no-commit]
        在 <当前仓库>/experiments/名字/ 新建实验项目（CLAUDE.md、目录结构、看板）并提交推送
  aris-lab run 编号 [--milestone M1] [--desc 说明] [--group 配置名] [--timeout 秒]
               [--no-commit] [--force] -- 命令 参数...
        跑一次实验：保存完整日志、记录指标、更新看板、提交并推送
  aris-lab status                     列出本项目的所有运行
  aris-lab report [--all]             重新生成看板（DASHBOARD.md / DASHBOARD.html / experiments/index.html）
  aris-lab publish [-m 说明] [--auto]  提交并推送 experiments/ 的改动（--auto 给 Stop hook 用，没改动就静默退出）
  aris-lab reviewer [--test]          查看审稿模型配置（环境变量 LLM_PROVIDER / LLM_API_KEY / LLM_BASE_URL / LLM_MODEL）
  aris-lab check                      体检：ARIS、审稿模型、算力、Python 环境，输出表格

实验脚本的约定：从环境变量 ARIS_RUN_ID、ARIS_RESULT_FILE 拿到运行编号和结果文件路径，
把 {"metrics": {...}, "config": {...}} 写进 ARIS_RESULT_FILE；
也可以在标准输出打印一行 `ARIS_RESULT {...JSON...}`（取最后一行）。
"""
import argparse, datetime as dt, fcntl, glob, html, json, math, os, re, shlex, shutil, signal
import socket, statistics, subprocess, sys, threading, time
from urllib import error as urlerror, request as urlrequest

try:
    from zoneinfo import ZoneInfo
    TZ = ZoneInfo(os.environ.get("CHAT_EXPORT_TZ", "Asia/Shanghai"))
except Exception:
    TZ = dt.timezone(dt.timedelta(hours=8))

HOME = os.path.expanduser("~")
LOCK = os.path.join(HOME, ".agent-reach", "logs", "chat-export.lock")  # 和 chat-export、research-site 共用，避免同时操作 git
REPORT_LOCK = os.path.join(HOME, ".aris", "report.lock")  # 生成看板时排队
REVIEWER_ENV = os.path.join(HOME, ".aris", "reviewer.env")
VENV_PY = os.path.join(HOME, ".aris-venv", "bin", "python")
MARK = ".aris-lab.json"
MAX_MB = 20
STATUS = {"running": "⏳ 运行中", "done": "✅ 完成", "failed": "❌ 失败", "timeout": "⏱ 超时",
          "killed": "⛔ 被中止", "lost": "❔ 中断"}
# 审稿模型预设：LLM_PROVIDER → (LLM_BASE_URL, 默认 LLM_MODEL)；默认模型为空的必须自己填 LLM_MODEL
PROVIDERS = {
    "modelscope": ("https://api-inference.modelscope.cn/v1", "deepseek-ai/DeepSeek-V4-Pro"),
    "deepseek": ("https://api.deepseek.com/v1", "deepseek-chat"),
    "openrouter": ("https://openrouter.ai/api/v1", "deepseek/deepseek-v4-pro"),
    "siliconflow": ("https://api.siliconflow.cn/v1", ""),
    "dashscope": ("https://dashscope.aliyuncs.com/compatible-mode/v1", ""),
    "moonshot": ("https://api.moonshot.cn/v1", ""),
    "zhipu": ("https://open.bigmodel.cn/api/paas/v4", ""),
    "gemini": ("https://generativelanguage.googleapis.com/v1beta/openai", ""),
    "openai": ("https://api.openai.com/v1", ""),
}


# ---------- 小工具 ----------
def now(fmt="%Y-%m-%d %H:%M:%S"):
    return dt.datetime.now(TZ).strftime(fmt)


def git(repo, *args, stdin=None, literal=False):
    env = dict(os.environ, GIT_LITERAL_PATHSPECS="1") if literal else None
    return subprocess.run(["git", "-C", repo, "-c", "core.quotePath=false", *args], capture_output=True,
                          text=True, input=stdin, env=env)


def git_root(path="."):
    r = git(os.path.abspath(path), "rev-parse", "--show-toplevel")
    return r.stdout.strip() if r.returncode == 0 else None


def find_project(start=None):
    d = os.path.abspath(start or os.getcwd())
    while True:
        if os.path.isfile(os.path.join(d, MARK)):
            return d
        parent = os.path.dirname(d)
        if parent == d:
            return None
        d = parent


def need_project(a):
    p = find_project(getattr(a, "project", None))
    if not p:
        sys.exit("不在实验项目里：先 cd experiments/<项目名>/，或者用 aris-lab new <项目名> 新建一个")
    return p


def load_json(path, default=None):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def atomic_write(path, text):
    """先写到同目录的临时文件再整体替换：别的进程读到的永远是完整的旧文件或新文件。"""
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    tmp = f"{path}.{os.getpid()}.{threading.get_ident()}.tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(text)
    os.replace(tmp, path)


def save_json(path, obj):
    atomic_write(path, json.dumps(obj, ensure_ascii=False, indent=1) + "\n")


def write_if_changed(path, text):
    old = None
    if os.path.exists(path):
        with open(path, encoding="utf-8", errors="replace") as f:  # 文件坏了也能读，随后会被重写
            old = f.read()
    if old != text:
        atomic_write(path, text)


def natkey(s):
    return [int(t) if t.isdigit() else t.lower() for t in re.split(r"(\d+)", str(s))]


def fmt_num(v):
    if isinstance(v, bool) or not isinstance(v, (int, float)):
        return str(v)
    if isinstance(v, float) and v.is_integer() and abs(v) < 1e15:
        v = int(v)
    if isinstance(v, int):
        return f"{v:,}" if abs(v) >= 10000 else str(v)
    if math.isnan(v) or math.isinf(v):
        return str(v)
    a = abs(v)
    if a >= 1000:
        return f"{v:,.1f}"
    if a >= 10:
        return f"{v:.3f}"
    if a >= 1e-3 or a == 0:
        return f"{v:.4f}"
    return f"{v:.2e}"


def fmt_dur(s):
    if s is None:
        return ""
    s = float(s)
    if s < 60:
        return f"{s:.0f} 秒"
    if s < 3600:
        return f"{s / 60:.1f} 分钟"
    return f"{s / 3600:.2f} 小时"


def pid_alive(pid):
    if not pid:
        return False
    try:
        os.kill(int(pid), 0)
        return True
    except (OSError, ValueError):
        return False


def boot_id():
    try:
        with open("/proc/sys/kernel/random/boot_id") as f:
            return f.read().strip()
    except OSError:
        return ""


def run_alive(r):
    """记录里 running 的运行是否还活着：True / False / None（在别的机器上启动，无法判断）。"""
    if r.get("boot_id") and boot_id() and r["boot_id"] != boot_id():
        return False  # 机器重启过或换了容器，进程不可能还在
    if r.get("host") and r["host"] != socket.gethostname():
        return None
    return pid_alive(r.get("pid"))


def hardware():
    gpus = []
    if shutil.which("nvidia-smi"):
        try:
            r = subprocess.run(["nvidia-smi", "--query-gpu=name,memory.total", "--format=csv,noheader"],
                               capture_output=True, text=True, timeout=20)
            gpus = [x.strip() for x in r.stdout.splitlines() if x.strip()]
        except (OSError, subprocess.SubprocessError):
            pass
    try:
        mem = os.sysconf("SC_PAGE_SIZE") * os.sysconf("SC_PHYS_PAGES") / 1024 ** 3
        mem_s = f"{mem:.0f} GB"
    except (ValueError, OSError, AttributeError):
        mem_s = "?"
    g = f"GPU {len(gpus)} 块（{gpus[0]}）" if gpus else "无 GPU"
    return f"CPU {os.cpu_count() or '?'} 核 / 内存 {mem_s} / {g}", gpus


# ---------- 提交前的检查：密钥、大文件 ----------
SECRET_RES = [re.compile(p) for p in (
    r"sk-[A-Za-z0-9_\-]{20,}", r"ghp_[A-Za-z0-9]{30,}", r"github_pat_[A-Za-z0-9_]{30,}",
    r"AKIA[0-9A-Z]{16}", r"AIza[0-9A-Za-z_\-]{35}",
    r"\bms-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b")]
SECRET_NAME = re.compile(r"KEY|TOKEN|SECRET|COOKIE|PASSW|AUTH|CT0|SESSION", re.I)


def _parts(v):
    yield v
    for piece in re.split(r"[;\s,]+", v):
        if "=" in piece:
            yield piece.split("=", 1)[1]


def secret_values():
    vals = set()
    for k, v in os.environ.items():
        if SECRET_NAME.search(k) and v:
            vals.update(_parts(v))
    for path in (REVIEWER_ENV, os.path.join(HOME, ".agent-reach", "twitter.env")):
        try:
            for line in open(path, encoding="utf-8"):
                m = re.match(r"\s*(?:export\s+)?\w+=(.*)", line.strip())
                if m:
                    vals.update(_parts(m.group(1).strip().strip("'\"")))
        except OSError:
            pass
    cookies = load_json(os.path.join(HOME, ".agent-reach", "xhs-cookies.json"), [])
    if isinstance(cookies, dict):
        cookies = cookies.get("cookies", [])
    for c in cookies if isinstance(cookies, list) else []:
        if isinstance(c, dict) and c.get("value"):
            vals.add(str(c["value"]))
    return {v for v in vals if len(v) >= 12 and not v.isdigit() and "/" not in v[:1]}


def staged_names(repo, paths):
    out = git(repo, "diff", "--cached", "--no-renames", "--name-only", "-z", "--", *paths).stdout
    return [n for n in out.split("\0") if n]


def guard_staged(repo, paths):
    """把含疑似密钥或超过 MAX_MB 的文件移出暂存区，返回警告列表。"""
    warns, bad = [], set()
    for n in staged_names(repo, paths):
        p = os.path.join(repo, n)
        if os.path.isfile(p) and os.path.getsize(p) > MAX_MB * 1024 * 1024:
            bad.add(n)
            warns.append(f"⚠️ 文件超过 {MAX_MB} MB，没有提交：{n}（大文件请加进 .gitignore）")
    secrets = secret_values()
    diff = git(repo, "diff", "--cached", "--no-renames", "-U0", "--no-color", "--", *paths).stdout
    cur = None
    for line in diff.splitlines():
        if line.startswith("+++ "):
            cur = line[6:] if line.startswith("+++ b/") else None
            continue
        if cur and cur not in bad and line.startswith("+") and (
                any(s in line for s in secrets) or any(r.search(line) for r in SECRET_RES)):
            bad.add(cur)
            warns.append(f"⚠️ 发现疑似密钥，没有提交：{cur}（删掉密钥后再提交）")
    if bad:
        git(repo, "restore", "--staged", "--", *sorted(bad), literal=True)
    return warns


def push(repo):
    branch = git(repo, "rev-parse", "--abbrev-ref", "HEAD").stdout.strip()
    if not branch or branch == "HEAD":
        return False
    for delay in (0, 2, 4, 8, 16):
        time.sleep(delay)
        if git(repo, "push", "-q", "-u", "origin", branch).returncode == 0:
            return True
    return False


def commit_paths(repo, paths, msg, do_push=True):
    """在锁里提交 paths 下的改动并推送。返回 (提交号或 None, 是否推送成功, 警告)。"""
    os.makedirs(os.path.dirname(LOCK), exist_ok=True)
    with open(LOCK, "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        git(repo, "add", "-A", "--", *paths)
        warns = guard_staged(repo, paths)
        names = staged_names(repo, paths)
        if not names:
            return None, False, warns
        # 只提交检查通过、已暂存的这些文件（不用目录 pathspec，免得把被拦下的文件从工作区带进提交）
        r = git(repo, "commit", "-q", "-m", msg, "--pathspec-from-file=-", "--pathspec-file-nul",
                stdin="\0".join(names), literal=True)
        if r.returncode != 0:
            return None, False, warns + [f"⚠️ 提交失败：{(r.stderr or r.stdout).strip()[:200]}"]
        sha = git(repo, "rev-parse", "--short", "HEAD").stdout.strip()
        return sha, (push(repo) if do_push else False), warns


# ---------- 项目模板 ----------
CLAUDE_MD = """# 实验项目：{{TITLE}}

> 由 `aris-lab new` 创建的 ARIS 实验项目。在这个文件夹里跑实验时按下面的约定做；整体流程见仓库的 `experiments/README.md`。

## Pipeline Status

```yaml
stage: idle            # idle | planning | implementation | training | analysis | review | done
idea: "{{TITLE}}"
contract: ""
baseline: ""
training_status: idle  # idle | running | complete | failed
language: zh           # ARIS 的产出用中文
active_tasks: []
next: "写实验计划：/experiment-plan，或照 experiments/README.md 手写 refine-logs/EXPERIMENT_PLAN.md"
last_updated: "{{NOW}}"
```

## 要回答的问题

{{QUESTION}}

## 算力（Compute）

- gpu: local
- 这台机器：{{HARDWARE}}
- 如果是 Claude Code 云端容器：没有 GPU，也不能 SSH 到别的服务器（网络只放行 HTTPS），只适合 CPU 小实验和调大模型 API 的实验；单次运行尽量控制在 2 小时内，更长的任务拆段并保存 checkpoint。
- 需要 GPU：在有 GPU 的机器上运行 Claude Code（`claude remote-control`），把这一节改成那台机器的 GPU 信息，见 `experiments/README.md`。

## 跑实验的规则

1. 正式实验一律用 `aris-lab run <编号> --milestone <M0/M1/…> --desc "<一句话>" [--group <配置名>] -- <命令>` 启动，不要直接 `python xxx.py`。编号用 R001、R002…，重跑换新编号（如 R001b）。
2. 超过几分钟的运行，用 Bash 工具的 `run_in_background: true` 启动，跑完会自动通知；期间用 `aris-lab status` 和 `tail logs/<编号>.log` 看进度。
3. 实验脚本：超参数都走 argparse；随机种子固定且可设置；把指标写进环境变量 `ARIS_RESULT_FILE` 指向的 JSON：`{"metrics": {...}, "config": {...}}`。
4. 评估必须用数据集自带的真实标签，不能拿别的模型的输出当标准答案（ARIS 的硬规则）。
5. 多个 seed 或网格批量跑：同一配置用同一个 `--group`，看板自动算均值 ± 标准差；批量时可以加 `--no-commit`，整批跑完再 `aris-lab publish -m "实验：<说明>"` 一次提交。并行数不要超过 CPU 核数。
6. 数据集、模型权重、checkpoint 不进 git（`.gitignore` 已写好）；`runs/`（运行记录）、`results/`（指标）、`logs/`（日志）和看板进 git。
7. ARIS 的产出都写在这个项目文件夹里：每条命令先 `cd` 到这里（或者给 aris-lab 加 `--project <路径>`）；ARIS skill 里有 `cd "$(git rev-parse --show-toplevel …)"` 的命令块时，用子 shell `( … )` 包起来跑。
8. 每批实验跑完，在回复里写一行：「🧪 实验看板已更新：<提交号> · {{NAME}} · 共 N 次运行 · experiments/{{NAME}}/DASHBOARD.md」。

## 审稿模型（Reviewer）

ARIS 需要审稿时（审代码、审结果、判断结论），按下面的顺序选审稿人：

1. **外部审稿模型（跨家族，算正式审稿）**：有 `mcp__llm-chat__review` 工具、并且 `LLM_API_KEY` 已配置时，按 ARIS `shared-references/reviewer-routing.md` 的「Optional HTTP API fallback」调用它（`executor_model` 填你自己的模型 id，`files` 传要审的原始文件路径），后续轮次用 `mcp__llm-chat__review_reply`。
2. **审稿子代理 aris-reviewer（同家族，只算临时审稿）**：没有外部审稿模型时，用 Agent 工具调 `aris-reviewer` 子代理（另一个 Claude 模型 + 专门的审稿提示，只读）。只告诉它要审哪些文件、审什么，**不要附上你自己的总结或解释**。把它的报告存到 `review-stage/`，结果里写明 `review_independence: same-family`、`acceptance_status: provisional`（“同家族临时审稿，未经跨模型复核”）。
3. **两者都没有**：这一步记为 `REVIEW_UNAVAILABLE`，继续往下跑，并在结果里写明「未经外部审稿」。

正式结论（论文里的 claim、投稿前的审计、/result-to-claim 的裁决）只认第 1 种；第 2 种用来尽早发现 bug。`aris-lab check` 可以查看审稿人是否就绪。
"""

README_MD = """# {{TITLE}}

{{QUESTION}}

- 📊 看板：[DASHBOARD.md](DASHBOARD.md)（网页版 `DASHBOARD.html`，由 `aris-lab` 自动生成）
- 🗺️ 实验计划：`refine-logs/EXPERIMENT_PLAN.md`（`/experiment-plan` 生成或手写）
- 📝 实验日志：[EXPERIMENT_LOG.md](EXPERIMENT_LOG.md)
- ⚙️ 本项目的约定：[CLAUDE.md](CLAUDE.md)
"""

LOG_MD = """# 实验日志（EXPERIMENT_LOG）

> 本项目所有实验的永久记录，成功和失败都要写；每个实验跑完立刻追加一条（ARIS 约定）。
> `refine-logs/EXPERIMENT_TRACKER.md` 是待办清单（TODO → RUNNING → DONE），这里是结论和复现方法，`DASHBOARD.md` 是 aris-lab 自动生成的数字汇总。
"""

GITIGNORE = """# aris-lab：数据、权重、checkpoint 不进 git
data/
datasets/
checkpoints/
ckpt/
outputs/
wandb/
*.pt
*.pth
*.ckpt
*.safetensors
.venv/
__pycache__/
*.pyc
.ipynb_checkpoints/
logs/*.prev
result.json
*.tmp
"""


EXP_GUIDE = """<!-- 这一段由 aris-lab 自动更新（改了会被覆盖）；自己的说明请写在这一段外面 -->
## 怎么用：对 Claude 说一句话

在 Claude Code 里打开这个仓库，说：

> 用 ARIS 跑实验：<你的想法，或者要验证的问题>

Claude 会按下面的步骤自动做完，并按自动保存规则把每一步提交到 GitHub：

| 步骤 | 做什么 | 产出 |
|---|---|---|
| 1. 建项目 | `aris-lab new <名字>`（会自动提交） | `experiments/<名字>/` |
| 2. 写计划 | `/experiment-plan`：把想法拆成要证明的结论（claim）和对应的实验 | `refine-logs/EXPERIMENT_PLAN.md` |
| 3. 写代码 | `/experiment-bridge`：按计划写实验代码 | `src/` |
| 4. 审代码 | 审稿模型检查代码有没有 bug（没配置审稿模型就跳过） | 审稿记录 |
| 5. 小测试 | 先跑最小的 sanity check，确认整条流程能跑通 | `runs/R001.json` |
| 6. 正式跑 | 基线 → 主实验 → 消融，多个随机种子 | `runs/`、`results/`、`logs/` |
| 7. 汇总 | 自动生成看板：每次运行的指标、同一配置的均值 ± 标准差、柱状图 | `DASHBOARD.md`、`DASHBOARD.html` |
| 8. 下结论 | `/analyze-results`、`/result-to-claim`：结果能支持哪些结论、还缺什么 | `ANALYSIS.md`、`EXPERIMENT_LOG.md` |
| 9. 改进（可选） | `/auto-review-loop`：审稿 → 补实验 → 再审，循环几轮 | `review-stage/` |

也可以只做其中一步，比如“把 R003 的配置再跑 5 个 seed”“看看这个项目的结果说明了什么”。

## 第一次用之前：两件事

### 1. 配置审稿模型（可选，建议配）

ARIS 的核心是“一个模型干活，另一个模型挑刺”：Claude 写代码、跑实验，审稿最好用**别家**的模型（盲点不同，挑错更准）。
在 claude.ai/code 的环境设置（新建对话页 → 输入框上方云朵图标 → 环境名右侧齿轮）→ **Environment variables** 里加两行：

```
LLM_PROVIDER=modelscope
LLM_API_KEY=你的 Key
```

| 用哪家 | LLM_PROVIDER 填 | Key 在哪拿 | 费用 |
|---|---|---|---|
| 魔搭 ModelScope（推荐先试） | `modelscope` | modelscope.cn 登录 → 访问令牌（以 `ms-` 开头） | 免费额度，每天约 2000 次；要先绑定阿里云账号 |
| DeepSeek 官方 | `deepseek` | platform.deepseek.com → API keys | 按量付费，很便宜，要先充值 |
| OpenRouter | `openrouter` | openrouter.ai → Keys | 按量付费，一个 Key 用多家模型 |
| OpenAI、Gemini、Kimi、智谱、通义、硅基流动 | `openai` / `gemini` / `moonshot` / `zhipu` / `dashscope` / `siliconflow` | 各平台控制台 | 还要加一行 `LLM_MODEL=模型名` |

保存后**新开一个对话**，说“检查实验环境”。Claude 会运行 `aris-lab check`，表格里“审稿模型”一行是 ✅ 就好了（“Codex 审稿”一行显示 ➖ 不用管，那是可选项）。
不配也能跑：这时 Claude 会用自带的审稿子代理 `aris-reviewer`（另一个 Claude 模型，带专门的审稿提示，只读不改）来审。它能看出不少问题，但和写代码的 Claude 是同一家的模型，盲点可能相似，所以只算**临时审稿**；正式结论（论文里的 claim、投稿前的审计）还是建议配上面的外部审稿模型再复核一次。

> Key 只放在环境变量里，不要贴进聊天，也不要写进代码。aris-lab 提交前会自动拦下含疑似密钥的文件。

### 2. 想好在哪跑（算力）

| 在哪跑 | 适合 | 怎么做 |
|---|---|---|
| Claude Code 云端（网页版默认就是） | CPU 小实验；调大模型 API 做评测（Agent / 大模型方向很多实验就是这种） | 什么都不用做。4 核 CPU、16 GB 内存、没有 GPU；单次运行尽量不超过 2 小时 |
| 你自己的 GPU 机器（实验室服务器、租的云 GPU、带显卡的电脑） | 训练、微调模型 | 在那台机器上：① 装好 Claude Code 并登录；② 运行 `curl -fsSL https://raw.githubusercontent.com/NNNoxin/claude-config/main/setup.sh \\| bash`；③ `git clone` 这个仓库，进入仓库目录运行 `claude remote-control`；④ 在 Claude 网页或手机 App 里就能看到这个会话，像现在一样聊天。再把实验项目 `CLAUDE.md` 的「算力」一节改成那台机器的 GPU 信息 |

云端容器的网络只放行 HTTPS，没法从云端 SSH 到 GPU 服务器，也连不上 Modal 这类 GPU 平台；要用 GPU，就让 Claude Code 直接跑在有 GPU 的机器上。

## 看结果

- 每个项目的 `DASHBOARD.md`：在 GitHub 网页上直接看。上面是“按配置汇总”：同一个配置名（`--group`）的多次运行合并成“均值 ± 标准差”一行；没有配置名的运行只出现在下面的“全部运行”表里。
- `DASHBOARD.html`：带柱状图的网页版，下载后用浏览器打开；这里的 `index.html` 是所有项目的总览。
- 看板上的数字是四舍五入过的；精确值看 `results/<编号>.json`。
- 每次运行：完整输出在 `logs/<编号>.log`，指标在 `results/<编号>.json`，命令、时间、代码版本在 `runs/<编号>.json`。

## 常用命令（Claude 会自己用，你也可以在终端里用）

`check` 和 `new` 在仓库里任何位置都能运行；其余命令要在项目文件夹里运行：先 `cd experiments/<名字>/`（或者加 `--project experiments/<名字>`）。`aris-lab run` 总是在项目文件夹里执行你的命令，所以命令里的路径（比如 `src/train.py`、`.venv/bin/python`）都写成相对项目文件夹的。

| 命令 | 作用 |
|---|---|
| `aris-lab check` | 体检：ARIS、审稿模型、算力 |
| `aris-lab new <名字> --title "标题" --question "要回答的问题" --key-metrics 指标1,指标2` | 新建实验项目并提交（关键指标排在看板最前面并画图；之后也可以改项目里的 `.aris-lab.json`） |
| `aris-lab run R001 --milestone M0 --desc "说明" --group 配置名 -- .venv/bin/python src/train.py --seed 0` | 跑一次实验：记录日志和指标、更新看板、提交推送 |
| `aris-lab status` | 本项目所有运行的状态 |
| `aris-lab report` | 重新生成看板（只改本地文件，不提交） |
| `aris-lab publish -m "说明"` | 提交并推送实验区的所有改动（`report` 之后、手动改了文件之后用） |

`aris-lab run` 的参数：

- **编号**（如 R001）：每次运行用一个新编号（R001、R002……）；同一配置重跑用 R001b。已经跑完的编号不能覆盖，除非加 `--force`。
- **`--milestone`**：阶段标签，比如 M0 小测试、M1 主实验、M2 消融；看板按它分节。
- **`--group`**：配置名。同一配置的不同随机种子用同一个名字，看板才会合并算均值 ± 标准差。
- **`--no-commit`**：批量跑时先不提交，整批跑完再 `aris-lab publish`。
- **`--timeout 秒数`**：超过这个时间自动停掉。

## 实验脚本的约定

- 超参数都用命令行参数（argparse），随机种子可以设置。
- 结果写进环境变量 `ARIS_RESULT_FILE` 指向的 JSON：`{"metrics": {"acc": 0.93}, "config": {"lr": 0.001}}`。这个环境变量只有用 `aris-lab run` 启动时才有，脚本里写成 `os.environ.get("ARIS_RESULT_FILE", "result.json")`，直接运行调试也不会出错（`result.json` 已在 `.gitignore` 里，不会被提交）。
- 可选：JSON 里加 `"group": "配置名"`，效果和 `--group` 一样。
- 依赖写进项目里的 `requirements.txt`（`aris-lab new` 已建好，每行一个），装在项目自己的环境里：`python3 -m venv .venv && .venv/bin/pip install -r requirements.txt`；运行时写 `-- .venv/bin/python src/train.py`（`.venv` 不进 git）。
- 评估用数据集自带的真实标签，不能拿别的模型的输出当标准答案。
- 数据集、模型权重、checkpoint 不进 git；结果、日志、看板进 git。
"""

EXP_HEADER = """# 🧪 实验区（ARIS 自动跑实验）

这里放用 [ARIS](https://github.com/wanshuiyin/Auto-claude-code-research-in-sleep) 自动跑的实验。每个子文件夹是一个实验项目，有自己的计划、代码、运行记录和看板。

## 实验项目

<!-- BEGIN aris-lab projects -->
<!-- END aris-lab projects -->

"""

GUIDE_BLOCK = "<!-- BEGIN aris-lab guide -->\n" + EXP_GUIDE + "<!-- END aris-lab guide -->"
EXP_README = EXP_HEADER + GUIDE_BLOCK + "\n"


REQUIREMENTS = """# 这个实验项目的 Python 依赖，每行一个，最好写死版本，例如：
# numpy==2.1.0
# scikit-learn==1.5.2
"""


def fill(tpl, **kw):
    for k, v in kw.items():
        tpl = tpl.replace("{{" + k + "}}", v)
    return tpl


def cmd_new(a):
    name = a.name.strip().strip("/")
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", name):
        sys.exit("项目名只能用英文字母、数字、点、横线、下划线，例如 demo-calibration")
    root = git_root() or os.getcwd()
    proj = os.path.join(root, "experiments", name)
    if os.path.exists(os.path.join(proj, MARK)):
        sys.exit(f"这个项目已经存在：{proj}")
    for sub in ("refine-logs", "src", "runs", "results", "logs"):
        os.makedirs(os.path.join(proj, sub), exist_ok=True)
    for sub in ("runs", "results", "logs"):
        open(os.path.join(proj, sub, ".gitkeep"), "a").close()
    hw, _ = hardware()
    title = a.title or name
    question = a.question or "（还没写：这个项目要回答什么问题？）"
    meta = {"name": name, "title": title, "question": question, "created": now("%Y-%m-%d %H:%M")}
    if a.key_metrics:
        meta["key_metrics"] = [k.strip() for k in a.key_metrics.split(",") if k.strip()]
    save_json(os.path.join(proj, MARK), meta)
    kw = dict(TITLE=title, NAME=name, QUESTION=question, HARDWARE=hw, NOW=now("%Y-%m-%d %H:%M"))
    for fn, tpl in (("CLAUDE.md", CLAUDE_MD), ("README.md", README_MD), ("EXPERIMENT_LOG.md", LOG_MD),
                    (".gitignore", GITIGNORE), ("requirements.txt", REQUIREMENTS)):
        path = os.path.join(proj, fn)
        if not os.path.exists(path):
            with open(path, "w", encoding="utf-8") as f:
                f.write(fill(tpl, **kw))
    build_reports(proj)
    rel = os.path.relpath(proj, root)
    print(f"已创建实验项目：{rel}/")
    repo = git_root(proj)
    if repo and not a.no_commit:
        sha, ok, warns = commit_paths(repo, [os.path.relpath(proj, repo), "experiments"], f"实验 {name}：新建实验项目")
        for w in warns:
            print(w)
        if sha:
            print(f"  {'已推送' if ok else '已提交（推送失败，稍后 aris-lab publish 重试）'} {sha}")
    print(f"  算力：{hw}")
    print("下一步：")
    print(f"  1. cd {rel}")
    print("  2. 写实验计划：/experiment-plan \"你的想法\"（或手写 refine-logs/EXPERIMENT_PLAN.md）")
    print("  3. 跑计划：/experiment-bridge；单次运行用 aris-lab run R001 --milestone M0 -- .venv/bin/python src/xxx.py（没建 .venv 就写 python3）")


# ---------- 跑实验 ----------
def kill_group(p):
    for sig, wait in ((signal.SIGTERM, 10), (signal.SIGKILL, 5)):
        try:
            os.killpg(p.pid, sig)
        except OSError:
            return
        try:
            p.wait(timeout=wait)
            return
        except subprocess.TimeoutExpired:
            continue


def say(*args, **kw):
    """输出被提前关掉（比如接了 | head）时不报错，保证运行记录和提交照常完成。"""
    try:
        print(*args, **kw)
    except (BrokenPipeError, OSError):
        pass


def cmd_run(a):
    proj = need_project(a)
    meta = load_json(os.path.join(proj, MARK), {})
    cmd = list(a.cmd)
    if not cmd:
        sys.exit("缺少要运行的命令，例如：aris-lab run R001 --milestone M0 -- python src/train.py --seed 0")
    rid = a.run_id
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", rid):
        sys.exit("编号只能用英文字母、数字和 . _ -，例如 R001")
    rec_path = os.path.join(proj, "runs", f"{rid}.json")
    old = load_json(rec_path)
    if old:
        alive = run_alive(old) if old.get("status") == "running" else False
        if alive and not a.force:
            sys.exit(f"{rid} 正在运行（pid {old.get('pid')}），换一个编号或等它结束")
        if alive is None and not a.force:
            sys.exit(f"{rid} 记录显示正在 {old.get('host')} 上运行，这里无法确认；确定它已经停了就加 --force")
        if old.get("status") == "done" and not a.force:
            sys.exit(f"{rid} 已经跑完了；重跑请换编号（如 {rid}b），确实要覆盖就加 --force")
    log_rel, res_rel = f"logs/{rid}.log", f"results/{rid}.json"
    log_path, res_path = os.path.join(proj, log_rel), os.path.join(proj, res_rel)
    if os.path.exists(log_path):
        os.replace(log_path, log_path + ".prev")
    if os.path.exists(res_path):
        os.remove(res_path)

    repo = git_root(proj)
    name = meta.get("name") or os.path.basename(proj)
    code_paths = []  # 项目里除运行记录、结果、日志、看板以外的文件（也就是代码和文档）
    if repo:
        rel = os.path.relpath(proj, repo)
        code_paths = [rel] + [f":(exclude){rel}/{d}" for d in ("runs", "results", "logs", "DASHBOARD.md", "DASHBOARD.html")]
    if repo and not a.no_commit:  # 运行前先给代码拍快照，保证记录里的提交号就是跑出这个结果的代码
        sha, ok, warns = commit_paths(repo, code_paths, f"实验代码快照：{name} {rid} 运行前")
        for w in warns:
            say(w, file=sys.stderr)
    head = git(repo, "rev-parse", "--short", "HEAD").stdout.strip() if repo else ""
    dirty = bool(git(repo, "status", "--porcelain", "--", *code_paths).stdout.strip()) if repo else False
    hw, _ = hardware()
    rec = {"run_id": rid, "milestone": a.milestone or "", "desc": a.desc or "", "group": a.group or "",
           "command": shlex.join(cmd), "workdir": ".",
           "status": "running", "exit_code": None, "started": now(), "finished": None, "duration_s": None,
           "host": socket.gethostname(), "hardware": hw, "git_commit": head, "code_dirty": dirty,
           "log": log_rel, "result_file": res_rel, "metrics": {}, "config": {}, "note": ""}
    env = dict(os.environ, ARIS_RUN_ID=rid, ARIS_RESULT_FILE=res_path, ARIS_PROJECT_DIR=proj, PYTHONUNBUFFERED="1")
    state = {"status": None}
    t0 = time.time()
    code, last = None, None
    with open(log_path, "w", encoding="utf-8", errors="replace") as log:
        log.write(f"# aris-lab run {rid} · {rec['started']} · {rec['command']}\n")
        log.flush()
        try:
            p = subprocess.Popen(cmd, cwd=proj, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=env,
                                 start_new_session=True, text=True, errors="replace", bufsize=1)
        except OSError as e:
            log.write(f"无法启动命令：{e}\n")
            p = None
            code, state["status"] = 127, "failed"
            rec["note"] = f"无法启动命令：{e}"
        if p:
            rec.update(pid=os.getpid(), child_pid=p.pid, boot_id=boot_id())  # 用 aris-lab 自己的进程判断是否还在跑
            save_json(rec_path, rec)
            try_build_reports(proj)

            def stop(signum, frame):
                state["status"] = "killed"
                threading.Thread(target=kill_group, args=(p,), daemon=True).start()
            signal.signal(signal.SIGTERM, stop)
            signal.signal(signal.SIGINT, stop)
            timer = None
            if a.timeout:
                def on_timeout():
                    state["status"] = "timeout"
                    kill_group(p)
                timer = threading.Timer(a.timeout, on_timeout)
                timer.daemon = True
                timer.start()
            echo = True
            for line in p.stdout:
                log.write(line)
                log.flush()
                if echo:
                    try:
                        sys.stdout.write(line)
                        sys.stdout.flush()
                    except (BrokenPipeError, OSError):
                        echo = False
                if line.startswith("ARIS_RESULT "):
                    last = line[len("ARIS_RESULT "):].strip()
            code = p.wait()
            if timer:
                timer.cancel()
        log.write(f"# 结束 · {now()} · 退出码 {code}\n")

    status = state["status"] or ("done" if code == 0 else "failed")
    result = load_json(res_path)
    if result is None and last:
        try:
            result = json.loads(last)
            save_json(res_path, result)
        except ValueError:
            rec["note"] = "ARIS_RESULT 行不是合法 JSON"
    if isinstance(result, dict):
        metrics = result.get("metrics")
        if not isinstance(metrics, dict):
            metrics = {k: v for k, v in result.items() if isinstance(v, (int, float)) and not isinstance(v, bool)}
        rec["metrics"] = metrics
        rec["config"] = result.get("config") if isinstance(result.get("config"), dict) else {}
        if not rec["group"] and result.get("group"):
            rec["group"] = str(result["group"])
    if status == "done" and not rec["metrics"]:
        rec["note"] = rec["note"] or "脚本没有写出指标（ARIS_RESULT_FILE 或 ARIS_RESULT 行）"
    rec.update(status=status, exit_code=code, finished=now(), duration_s=round(time.time() - t0, 1))
    for k in ("pid", "child_pid", "boot_id"):
        rec.pop(k, None)
    save_json(rec_path, rec)
    try_build_reports(proj)

    shown = metric_keys([rec], key_metrics(meta))[:4]
    key = ", ".join(f"{k}={fmt_num(rec['metrics'][k])}" for k in shown)
    say(f"\n[aris-lab] {rid} {STATUS[status]} · 用时 {fmt_dur(rec['duration_s'])}" + (f" · {key}" if key else ""))
    if repo and not a.no_commit:
        rel = os.path.relpath(proj, repo)
        msg = f"实验 {name}/{rid}：{STATUS[status].split()[-1]}" + (f"（{key}）" if key else "")
        sha, ok, warns = commit_paths(repo, [rel, os.path.relpath(os.path.join(repo, "experiments"), repo)], msg)
        for w in warns:
            say(w)
        if sha:
            say(f"[aris-lab] {'已推送' if ok else '已提交（推送失败，稍后 aris-lab publish 重试）'} {sha}：{msg}")
    if status == "timeout":
        sys.exit(124)
    if status == "killed":
        sys.exit(130)
    sys.exit(0 if status == "done" else (code if isinstance(code, int) and code > 0 else 1))


# ---------- 看板 ----------
def load_runs(proj):
    """读取全部运行记录。只在内存里把“进程已不在”的运行显示成中断，不写回文件，
    免得和正在收尾的 aris-lab run 抢着写同一个记录。"""
    runs = []
    for path in glob.glob(os.path.join(proj, "runs", "*.json")):
        r = load_json(path)
        if not isinstance(r, dict) or "run_id" not in r:
            continue
        if r.get("status") == "running":
            alive = run_alive(r)
            if alive is False:
                r["status"] = "lost"
                r["note"] = r.get("note") or "进程已不在（容器重启或被杀掉），没有正常结束"
            elif alive is None:
                r["note"] = r.get("note") or f"在 {r.get('host')} 上启动，这台机器看不到它的状态"
        runs.append(r)
    runs.sort(key=lambda r: natkey(r["run_id"]))
    return runs


def metric_keys(runs, first=()):
    """这些运行报告过的数值指标；first（项目的 key_metrics）里出现过的排在最前面。"""
    keys = []
    for r in runs:
        for k, v in (r.get("metrics") or {}).items():
            if k not in keys and isinstance(v, (int, float)) and not isinstance(v, bool):
                keys.append(k)
    return [k for k in first if k in keys] + [k for k in keys if k not in first]


def key_metrics(meta):
    km = meta.get("key_metrics") if isinstance(meta, dict) else None
    return [str(k) for k in km] if isinstance(km, list) else []


def aggregate(runs, keys):
    groups = {}
    for r in runs:
        if r.get("status") == "done" and r.get("group"):
            groups.setdefault(r["group"], []).append(r)
    out = []
    for g, rs in groups.items():
        row = {"group": g, "n": len(rs), "stats": {}}
        for k in keys:
            vals = [r["metrics"][k] for r in rs if isinstance((r.get("metrics") or {}).get(k), (int, float))]
            if vals:
                row["stats"][k] = (statistics.fmean(vals), statistics.stdev(vals) if len(vals) > 1 else 0.0, len(vals))
        out.append(row)
    out.sort(key=lambda x: natkey(x["group"]))
    return out


def counts(runs):
    c = {}
    for r in runs:
        c[r.get("status")] = c.get(r.get("status"), 0) + 1
    return c


def project_files(proj):
    cand = [("实验计划", "refine-logs/EXPERIMENT_PLAN.md"), ("实验追踪", "refine-logs/EXPERIMENT_TRACKER.md"),
            ("初步结果", "refine-logs/EXPERIMENT_RESULTS.md"), ("实验日志", "EXPERIMENT_LOG.md"),
            ("结果分析", "ANALYSIS.md"), ("审稿记录", "review-stage/AUTO_REVIEW.md"), ("项目约定", "CLAUDE.md")]
    return [(t, p) for t, p in cand if os.path.exists(os.path.join(proj, p))]


def latest_time(meta, runs):
    ts = [meta.get("created", "")] + [r.get("finished") or r.get("started") or "" for r in runs]
    return max(t for t in ts if t is not None) or ""


def run_metrics_cells(r, keys):
    m = r.get("metrics") or {}
    return [fmt_num(m[k]) if k in m else "" for k in keys]


def md_escape(s):
    return str(s).replace("|", "\\|").replace("\n", " ")


def render_md(proj, meta, runs):
    first = key_metrics(meta)
    keys = metric_keys([r for r in runs if r.get("group") and r.get("status") == "done"], first)
    agg = aggregate(runs, keys)
    c = counts(runs)
    L = [f"# 🧪 实验看板：{meta.get('title', meta.get('name'))}", "",
         f"> 要回答的问题：{meta.get('question', '')}", "",
         f"- 运行：共 {len(runs)} 次 · ✅ 完成 {c.get('done', 0)} · ❌ 失败 {c.get('failed', 0) + c.get('timeout', 0) + c.get('killed', 0) + c.get('lost', 0)} · ⏳ 运行中 {c.get('running', 0)}",
         f"- 数据更新：{latest_time(meta, runs)}"]
    files = project_files(proj)
    if files:
        L.append("- 文件：" + " · ".join(f"[{t}]({p})" for t, p in files))
    L += ["", "_由 `aris-lab` 自动生成，手改会被覆盖。_", ""]
    if agg and keys:
        L += ["## 按配置汇总（均值 ± 标准差）", "", "| 配置 | 完成次数 | " + " | ".join(keys) + " |",
              "|---|---:|" + "---:|" * len(keys)]
        for row in agg:
            cells = []
            for k in keys:
                if k in row["stats"]:
                    m, s, n = row["stats"][k]
                    cells.append(f"{fmt_num(m)} ± {fmt_num(s)}" if n > 1 else fmt_num(m))
                else:
                    cells.append("")
            L.append(f"| {md_escape(row['group'])} | {row['n']} | " + " | ".join(cells) + " |")
        L.append("")
    L += ["## 全部运行", ""]
    if not runs:
        L += ["还没有运行。在这个文件夹里用 `aris-lab run R001 --milestone M0 --desc \"健全性检查\" -- .venv/bin/python src/xxx.py` 开始。", ""]
    by_ms = {}
    for r in runs:
        by_ms.setdefault(r.get("milestone") or "未分组", []).append(r)
    for ms in sorted(by_ms, key=natkey):
        keys = metric_keys(by_ms[ms], first)
        L += [f"### {ms}", "", "| 编号 | 说明 | 状态 | 配置 | " + " | ".join(keys) + (" | " if keys else "") + "用时 | 日志 | 代码版本 |",
              "|---|---|---|---|" + "---:|" * len(keys) + "---|---|---|"]
        for r in by_ms[ms]:
            note = f"（{r['note']}）" if r.get("note") else ""
            L.append("| " + " | ".join([r["run_id"], md_escape(r.get("desc", "") + note), STATUS.get(r.get("status"), r.get("status", "")),
                                        md_escape(r.get("group", "")), *run_metrics_cells(r, keys), fmt_dur(r.get("duration_s")),
                                        f"[log]({r.get('log')})", r.get("git_commit", "") + ("*" if r.get("code_dirty") else "")]) + " |")
        L.append("")
    if any(r.get("code_dirty") for r in runs):
        L += ["代码版本带 * 的运行：运行时还有没提交的代码改动。", ""]
    return "\n".join(L)


CSS = """:root{--bg:#f7f6f3;--fg:#1d1d1b;--muted:#6b6a66;--card:#fff;--line:#e3e1db;--accent:#c96442;--chip:#efede8;--bar:#d9a48f;--ok:#2f7d4f;--bad:#b3261e}
@media (prefers-color-scheme:dark){:root:not([data-theme="light"]){--bg:#1a1a19;--fg:#ecebe7;--muted:#a19f99;--card:#242423;--line:#3a3936;--accent:#e08a6a;--chip:#2f2e2c;--bar:#9a5a43;--ok:#7cc79a;--bad:#f2b8b5}}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--fg);font:15px/1.6 -apple-system,BlinkMacSystemFont,"Segoe UI","PingFang SC","Microsoft YaHei",sans-serif}
a{color:var(--accent)}
.wrap{max-width:1100px;margin:0 auto;padding:24px 16px 80px}
h1{font-size:24px;margin:0 0 6px}
h2{font-size:16px;color:var(--accent);border-bottom:1px solid var(--line);padding-bottom:6px;margin-top:32px}
h3{font-size:15px;margin:20px 0 6px}
.meta{color:var(--muted);font-size:13px}
.stats{display:flex;gap:12px;flex-wrap:wrap;margin:18px 0}
.stat{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:10px 16px;min-width:110px}
.stat b{display:block;font-size:22px}
.stat span{color:var(--muted);font-size:12px}
.card{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:14px 16px;margin:12px 0}
.tbl{overflow-x:auto}
table{border-collapse:collapse;width:100%;font-size:13px}
th,td{border-bottom:1px solid var(--line);padding:6px 8px;text-align:left;vertical-align:top;white-space:nowrap}
td.num,th.num{text-align:right;font-variant-numeric:tabular-nums}
td.desc{white-space:normal;min-width:12em}
.s-done{color:var(--ok)}.s-failed,.s-timeout,.s-killed,.s-lost{color:var(--bad)}
.chip{display:inline-block;background:var(--chip);border-radius:999px;padding:1px 10px;font-size:12px;margin:2px 4px 2px 0;color:var(--muted)}
.charts{display:grid;grid-template-columns:repeat(auto-fit,minmax(300px,1fr));gap:12px}
svg text{fill:var(--fg);font-size:11px}
svg .bar{fill:var(--bar)}svg .err{stroke:var(--fg);stroke-width:1}
"""


def esc(s):
    return html.escape(str(s if s is not None else ""))


def chart_svg(agg, key):
    rows = [(r["group"], *r["stats"][key][:2]) for r in agg if key in r["stats"]]
    if len(rows) < 2 or any(m < 0 for _, m, _ in rows):
        return ""
    top = max(m + s for _, m, s in rows) or 1.0
    w, lab, bh, gap = 320, 110, 16, 6
    h = len(rows) * (bh + gap) + 24
    out = [f'<svg viewBox="0 0 {w} {h}" width="100%" role="img" aria-label="{esc(key)}">',
           f'<text x="0" y="12" style="font-weight:600">{esc(key)}（均值 ± 标准差）</text>']
    span = w - lab - 50
    for i, (g, m, s) in enumerate(rows):
        y = 22 + i * (bh + gap)
        x1 = lab + span * m / top
        out.append(f'<text x="{lab - 6}" y="{y + bh - 4}" text-anchor="end">{esc(g[:16])}</text>')
        out.append(f'<rect class="bar" x="{lab}" y="{y}" width="{max(span * m / top, 1):.1f}" height="{bh}" rx="2"/>')
        if s > 0:
            a, b = lab + span * max(m - s, 0) / top, lab + span * (m + s) / top
            out.append(f'<line class="err" x1="{a:.1f}" x2="{b:.1f}" y1="{y + bh / 2}" y2="{y + bh / 2}"/>')
        out.append(f'<text x="{x1 + 6 + (span * s / top if s > 0 else 0):.1f}" y="{y + bh - 4}">{esc(fmt_num(m))}</text>')
    out.append("</svg>")
    return "".join(out)


def render_html(proj, meta, runs):
    first = key_metrics(meta)
    keys = metric_keys([r for r in runs if r.get("group") and r.get("status") == "done"], first)
    agg = aggregate(runs, keys)
    c = counts(runs)
    title = meta.get("title", meta.get("name"))
    bad = c.get("failed", 0) + c.get("timeout", 0) + c.get("killed", 0) + c.get("lost", 0)
    P = [f"<!doctype html><html lang='zh-CN'><head><meta charset='utf-8'><meta name='viewport' content='width=device-width,initial-scale=1'>",
         f"<title>实验看板 · {esc(title)}</title><style>{CSS}</style></head><body><div class='wrap'>",
         f"<h1>🧪 {esc(title)}</h1><div class='meta'>要回答的问题：{esc(meta.get('question', ''))}</div>",
         f"<div class='meta'>数据更新：{esc(latest_time(meta, runs))} · 由 aris-lab 自动生成</div>",
         "<div class='stats'>" + "".join(f"<div class='stat'><b>{n}</b><span>{t}</span></div>" for n, t in (
             (len(runs), "运行总数"), (c.get("done", 0), "✅ 完成"), (bad, "❌ 失败/中断"), (c.get("running", 0), "⏳ 运行中"))) + "</div>"]
    files = project_files(proj)
    if files:
        P.append("<div>" + "".join(f"<a class='chip' href='{esc(p)}'>{esc(t)}</a>" for t, p in files) + "</div>")
    if agg and keys:
        P.append("<h2>按配置汇总（均值 ± 标准差）</h2><div class='card tbl'><table><tr><th>配置</th><th class='num'>完成次数</th>"
                 + "".join(f"<th class='num'>{esc(k)}</th>" for k in keys) + "</tr>")
        for row in agg:
            cells = []
            for k in keys:
                if k in row["stats"]:
                    m, s, n = row["stats"][k]
                    cells.append(f"<td class='num'>{esc(fmt_num(m))}" + (f" ± {esc(fmt_num(s))}" if n > 1 else "") + "</td>")
                else:
                    cells.append("<td></td>")
            P.append(f"<tr><td>{esc(row['group'])}</td><td class='num'>{row['n']}</td>{''.join(cells)}</tr>")
        P.append("</table></div>")
        charts = [chart_svg(agg, k) for k in ([k for k in first if k in keys] or keys)[:8]]
        charts = [x for x in charts if x]
        if charts:
            P.append("<div class='charts'>" + "".join(f"<div class='card'>{x}</div>" for x in charts) + "</div>")
    P.append("<h2>全部运行</h2>")
    if not runs:
        P.append("<p class='meta'>还没有运行。</p>")
    by_ms = {}
    for r in runs:
        by_ms.setdefault(r.get("milestone") or "未分组", []).append(r)
    for ms in sorted(by_ms, key=natkey):
        keys = metric_keys(by_ms[ms], first)
        P.append(f"<h3>{esc(ms)}</h3><div class='card tbl'><table><tr><th>编号</th><th>说明</th><th>状态</th><th>配置</th>"
                 + "".join(f"<th class='num'>{esc(k)}</th>" for k in keys) + "<th>用时</th><th>日志</th><th>代码版本</th></tr>")
        for r in by_ms[ms]:
            st = r.get("status", "")
            note = f"<br><span class='meta'>{esc(r['note'])}</span>" if r.get("note") else ""
            cmd = f"<br><span class='meta'><code>{esc(r.get('command', ''))}</code></span>"
            P.append(f"<tr><td>{esc(r['run_id'])}</td><td class='desc'>{esc(r.get('desc', ''))}{note}{cmd}</td>"
                     f"<td class='s-{esc(st)}'>{esc(STATUS.get(st, st))}</td><td>{esc(r.get('group', ''))}</td>"
                     + "".join(f"<td class='num'>{esc(v)}</td>" for v in run_metrics_cells(r, keys))
                     + f"<td>{esc(fmt_dur(r.get('duration_s')))}</td><td><a href='{esc(r.get('log'))}'>log</a></td>"
                     f"<td>{esc(r.get('git_commit', ''))}{'*' if r.get('code_dirty') else ''}</td></tr>")
        P.append("</table></div>")
    P.append("</div></body></html>\n")
    return "".join(P)


def all_projects(repo_or_dir):
    base = os.path.join(repo_or_dir, "experiments")
    return sorted((os.path.dirname(p) for p in glob.glob(os.path.join(base, "*", MARK))), key=natkey)


def build_index(exp_dir):
    projs = sorted((os.path.dirname(p) for p in glob.glob(os.path.join(exp_dir, "*", MARK))), key=natkey)
    rows = []
    for proj in projs:
        meta = load_json(os.path.join(proj, MARK), {})
        runs = load_runs(proj)
        c = counts(runs)
        rows.append((os.path.basename(proj), meta, len(runs), c, latest_time(meta, runs)))
    md = ["| 项目 | 要回答的问题 | 运行 | 完成 | 最近更新 | 看板 |", "|---|---|---:|---:|---|---|"]
    for name, meta, n, c, t in rows:
        md.append(f"| {md_escape(meta.get('title', name))} | {md_escape(meta.get('question', ''))} | {n} | {c.get('done', 0)} | {t} | [{name}/DASHBOARD.md]({name}/DASHBOARD.md) |")
    if not rows:
        md.append("| （还没有项目，用 `aris-lab new <名字>` 新建） | | | | | |")
    block = "<!-- BEGIN aris-lab projects -->\n" + "\n".join(md) + "\n<!-- END aris-lab projects -->"
    readme = os.path.join(exp_dir, "README.md")
    old = open(readme, encoding="utf-8").read() if os.path.exists(readme) else EXP_README
    pat = re.compile(r"<!-- BEGIN aris-lab projects -->.*?<!-- END aris-lab projects -->", re.S)
    new = pat.sub(lambda _: block, old) if pat.search(old) else old.rstrip() + "\n\n" + block + "\n"
    gpat = re.compile(r"<!-- BEGIN aris-lab guide -->.*?<!-- END aris-lab guide -->", re.S)
    new = gpat.sub(lambda _: GUIDE_BLOCK, new)  # 使用说明跟着 aris-lab 版本自动更新；区块外的内容不动
    write_if_changed(readme, new)
    H = ["<!doctype html><html lang='zh-CN'><head><meta charset='utf-8'><meta name='viewport' content='width=device-width,initial-scale=1'>",
         f"<title>实验总览</title><style>{CSS}</style></head><body><div class='wrap'><h1>🧪 实验总览</h1>",
         "<div class='meta'>每个实验项目一张看板，由 aris-lab 自动生成</div><div class='card tbl'><table>",
         "<tr><th>项目</th><th>要回答的问题</th><th class='num'>运行</th><th class='num'>完成</th><th>最近更新</th></tr>"]
    for name, meta, n, c, t in rows:
        H.append(f"<tr><td><a href='{esc(name)}/DASHBOARD.html'>{esc(meta.get('title', name))}</a></td>"
                 f"<td class='desc'>{esc(meta.get('question', ''))}</td><td class='num'>{n}</td><td class='num'>{c.get('done', 0)}</td><td>{esc(t)}</td></tr>")
    H.append("</table></div></div></body></html>\n")
    write_if_changed(os.path.join(exp_dir, "index.html"), "".join(H))


def build_reports(proj):
    """重新生成本项目看板和 experiments/ 总览。加锁排队，免得并行运行同时改同一个文件。"""
    os.makedirs(os.path.dirname(REPORT_LOCK), exist_ok=True)
    with open(REPORT_LOCK, "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        meta = load_json(os.path.join(proj, MARK), {})
        runs = load_runs(proj)
        write_if_changed(os.path.join(proj, "DASHBOARD.md"), render_md(proj, meta, runs) + "\n")
        write_if_changed(os.path.join(proj, "DASHBOARD.html"), render_html(proj, meta, runs))
        exp_dir = os.path.dirname(proj)
        if os.path.basename(exp_dir) == "experiments":
            build_index(exp_dir)


def try_build_reports(proj):
    """跑实验途中更新看板：出错只提示，不能让实验本身的记录跟着失败。"""
    try:
        build_reports(proj)
    except Exception as e:
        say(f"[aris-lab] ⚠️ 看板没更新成功（{type(e).__name__}: {e}），稍后运行 aris-lab report 重试", file=sys.stderr)


def cmd_report(a):
    proj = find_project(a.project)
    if proj and not a.all:
        build_reports(proj)
        print(os.path.join(proj, "DASHBOARD.md"))
        return
    root = git_root() or os.getcwd()
    projs = all_projects(root)
    for p in projs:
        build_reports(p)
        print(os.path.join(p, "DASHBOARD.md"))
    if not projs:
        print("没有找到实验项目（experiments/*/.aris-lab.json）")


def cmd_status(a):
    proj = need_project(a)
    runs = load_runs(proj)
    keys = metric_keys(runs, key_metrics(load_json(os.path.join(proj, MARK), {})))[:4]
    if not runs:
        print("还没有运行。")
        return
    print(f"{'编号':<10}{'阶段':<8}{'状态':<10}{'开始时间':<21}{'用时':<12}指标")
    for r in runs:
        m = r.get("metrics") or {}
        ms = ", ".join(f"{k}={fmt_num(m[k])}" for k in keys if k in m)
        dur = fmt_dur(r.get("duration_s")) if r.get("duration_s") is not None else "…"
        print(f"{r['run_id']:<10}{(r.get('milestone') or '-'):<8}{STATUS.get(r.get('status'), r.get('status')):<10}"
              f"{r.get('started', ''):<21}{dur:<12}{ms}")
    build_reports(proj)


def cmd_publish(a):
    repo = git_root()
    if not repo:
        if a.auto:
            return
        sys.exit("不在 git 仓库里")
    exp = os.path.join(repo, "experiments")
    if not os.path.isdir(exp):
        if a.auto:
            return
        sys.exit("这个仓库还没有 experiments/ 文件夹")
    if a.auto and not git(repo, "status", "--porcelain", "--", "experiments").stdout.strip():
        return
    for p in all_projects(repo):
        build_reports(p)
    sha, ok, warns = commit_paths(repo, ["experiments"], a.message or "实验：更新实验记录和看板")
    for w in warns:
        print(w)
    if sha:
        print(f"{'已推送' if ok else '已提交（推送失败）'} {sha}：{a.message or '实验：更新实验记录和看板'}")
    elif not a.auto:
        print("experiments/ 没有需要提交的改动")


# ---------- 审稿模型 ----------
def read_env_file(path):
    out = {}
    try:
        for line in open(path, encoding="utf-8"):
            m = re.match(r"\s*(?:export\s+)?(\w+)=(.*)", line.rstrip("\n"))
            if m:
                v = m.group(2).strip()
                try:
                    v = shlex.split(v)[0] if v else ""
                except ValueError:
                    pass
                out[m.group(1)] = v
    except OSError:
        pass
    return out


def reviewer_conf():
    """环境变量优先，其次 ~/.aris/reviewer.env；LLM_PROVIDER 或 Key 前缀补全地址和默认模型。"""
    f = read_env_file(REVIEWER_ENV)
    get = lambda k: (os.environ.get(k) or f.get(k) or "").strip()
    key, base, model, prov = get("LLM_API_KEY"), get("LLM_BASE_URL"), get("LLM_MODEL"), get("LLM_PROVIDER").lower()
    if not prov and not base:
        prov = "modelscope" if key.startswith("ms-") else "openrouter" if key.startswith("sk-or-") else \
            "gemini" if key.startswith("AIza") else ""
    if prov in PROVIDERS:
        base = base or PROVIDERS[prov][0]
        model = model or PROVIDERS[prov][1]
    return {"provider": prov, "key": key, "base": base, "model": model,
            "fallback": get("LLM_FALLBACK_MODEL") or model}


def reviewer_test(conf, timeout=90):
    url = conf["base"].rstrip("/") + "/chat/completions"
    body = json.dumps({"model": conf["model"], "max_tokens": 64,
                       "messages": [{"role": "user", "content": "Reply with exactly: OK"}]}).encode()
    req = urlrequest.Request(url, data=body, headers={"Content-Type": "application/json",
                                                       "Authorization": f"Bearer {conf['key']}"})
    t0 = time.time()
    try:
        with urlrequest.urlopen(req, timeout=timeout) as r:
            d = json.loads(r.read().decode("utf-8", "replace"))
        msg = (d.get("choices") or [{}])[0].get("message") or {}
        text = (msg.get("content") or msg.get("reasoning_content") or "").strip().replace("\n", " ")
        return True, f"{d.get('model') or conf['model']} 可用（{time.time() - t0:.1f} 秒，回复：{text[:30] or '空'}）"
    except urlerror.HTTPError as e:
        detail = e.read().decode("utf-8", "replace")[:160].replace("\n", " ")
        hint = {401: "Key 不对或已失效", 403: "没有权限（可能要实名或开通）", 404: "地址或模型名不对",
                429: "请求太频繁或额度用完", 400: "请求被拒绝（多半是模型名不对）"}.get(e.code, "")
        return False, f"HTTP {e.code} {hint}：{detail}"
    except Exception as e:
        return False, f"连不上：{type(e).__name__} {str(e)[:120]}"


def cmd_reviewer(a):
    if a.exec_server:  # 给 MCP 用：补全配置后启动 ARIS 的 llm-chat 服务（标准输出只能留给 MCP 协议）
        conf = reviewer_conf()
        env = dict(os.environ, LLM_REVIEW_FALLBACK_ENABLED=os.environ.get("LLM_REVIEW_FALLBACK_ENABLED", "true"))
        for k, v in (("LLM_API_KEY", conf["key"]), ("LLM_BASE_URL", conf["base"]), ("LLM_MODEL", conf["model"]),
                     ("LLM_FALLBACK_MODEL", conf["fallback"])):
            if v:
                env[k] = v
        repo = (open(os.path.join(HOME, ".aris", "repo")).read().strip()
                if os.path.exists(os.path.join(HOME, ".aris", "repo")) else os.path.join(HOME, "aris_repo"))
        py = VENV_PY if os.path.exists(VENV_PY) else sys.executable
        server = os.path.join(repo, "mcp-servers", "llm-chat", "server.py")
        os.execve(py, [py, server], env)
    conf = reviewer_conf()
    if not conf["key"]:
        print("审稿模型：未配置（没有 LLM_API_KEY）")
        print("配置方法：在云端环境的环境变量里加两行，然后开新对话：")
        print("  LLM_PROVIDER=modelscope   （或 deepseek / openrouter / gemini / openai / siliconflow / dashscope / moonshot / zhipu）")
        print("  LLM_API_KEY=你的 Key")
        print("  （其他提供商再加 LLM_MODEL=模型名；自定义地址用 LLM_BASE_URL）")
        return 1
    print(f"审稿模型：{conf['provider'] or '自定义'} · {conf['model'] or '（缺 LLM_MODEL）'} · {conf['base'] or '（缺 LLM_BASE_URL）'}")
    if not conf["base"] or not conf["model"]:
        print("缺少地址或模型名：请补上 LLM_BASE_URL 或 LLM_MODEL")
        return 1
    if a.test:
        ok, msg = reviewer_test(conf)
        print(("✅ " if ok else "❌ ") + msg)
        return 0 if ok else 1
    return 0


def mcp_registered(name):
    cfg = load_json(os.path.join(HOME, ".claude.json"), {}) or {}
    return name in (cfg.get("mcpServers") or {})


# ---------- 体检 ----------
def cmd_check(a):
    rows = []
    here = git_root()
    doc = ("experiments/README.md" if here and os.path.exists(os.path.join(here, "experiments", "README.md"))
           else "aris-lab new 之后生成的 experiments/README.md，或 github.com/NNNoxin/claude-config")
    repo = os.path.join(HOME, "aris_repo")
    if os.path.exists(os.path.join(HOME, ".aris", "repo")):
        repo = open(os.path.join(HOME, ".aris", "repo")).read().strip() or repo
    if os.path.isdir(os.path.join(repo, "skills")):
        r = git(repo, "log", "-1", "--format=%h · %cd", "--date=short")
        rows.append(("ARIS 仓库", "✅", f"{r.stdout.strip() or '?'} · {repo}"))
    else:
        rows.append(("ARIS 仓库", "❌", "没装：运行 claude-config 的 setup.sh"))
    sk = os.path.join(HOME, ".claude", "skills")
    linked = [n for n in (os.listdir(sk) if os.path.isdir(sk) else [])
              if os.path.islink(os.path.join(sk, n)) and os.path.realpath(os.path.join(sk, n)).startswith(os.path.realpath(repo))
              and os.path.isfile(os.path.join(sk, n, "SKILL.md"))]
    rows.append(("ARIS skills", "✅" if linked else "❌",
                 f"{len(linked)} 个（/experiment-plan、/experiment-bridge、/run-experiment、/auto-review-loop 等）" if linked else "没装好：重跑 setup.sh"))
    conf = reviewer_conf()
    if not conf["key"]:
        rows.append(("审稿模型", "❌ 未配置", f"在环境变量里加 LLM_PROVIDER 和 LLM_API_KEY（见 {doc}）；不配也能跑，审稿由下面的审稿子代理临时代替"))
    elif not conf["base"] or not conf["model"]:
        rows.append(("审稿模型", "❌", "缺 LLM_BASE_URL 或 LLM_MODEL"))
    else:
        ok, msg = reviewer_test(conf)
        rows.append(("审稿模型", "✅" if ok else "❌", msg))
    rows.append(("审稿工具注册", "✅" if mcp_registered("llm-chat") else "❌",
                 "llm-chat（ARIS 需要审稿时调用；新对话生效）" if mcp_registered("llm-chat") else "没注册：重跑 setup.sh"))
    agent = os.path.join(HOME, ".claude", "agents", "aris-reviewer.md")
    rows.append(("审稿子代理", "✅" if os.path.exists(agent) else "❌",
                 "aris-reviewer（另一个 Claude 模型，只读；没有外部审稿模型时做同家族临时审稿）" if os.path.exists(agent)
                 else "没装：重跑 setup.sh"))
    rows.append(("Codex 审稿", "✅" if shutil.which("codex") else "➖", "已安装" if shutil.which("codex") else "可选，没装不影响（有 ChatGPT 账号才用得上；没有就用上面的审稿模型）"))
    hw, gpus = hardware()
    rows.append(("算力", "✅" if gpus else "ℹ️", hw + ("" if gpus else f"：适合 CPU 小实验和调 API 的实验；要 GPU 见 {doc}")))
    try:
        free = shutil.disk_usage(HOME).free / 1024 ** 3
        rows.append(("磁盘", "✅" if free > 5 else "⚠️", f"剩余 {free:.0f} GB"))
    except OSError:
        pass
    probe = ("import importlib.util as u\n"
             "print(' '.join(n+('✓' if u.find_spec(m) else '✗') for n,m in "
             "[('numpy','numpy'),('scipy','scipy'),('scikit-learn','sklearn'),('torch','torch'),('transformers','transformers')]))")
    r = subprocess.run([sys.executable, "-c", probe], capture_output=True, text=True)
    rows.append(("Python 包（系统）", "ℹ️", (r.stdout.strip() or "?") + "（每个实验项目建议用自己的 .venv）"))
    repo_here = here
    if repo_here:
        n = len(all_projects(repo_here))
        rows.append(("实验项目", "ℹ️", f"{os.path.basename(repo_here)}/experiments/ 下有 {n} 个" if n else "当前仓库还没有，用 aris-lab new <名字> 新建"))
    out = [f"## ARIS 实验环境体检（{now('%Y-%m-%d %H:%M')}）", "", "| 项目 | 状态 | 说明 |", "|---|---|---|"]
    out += [f"| {a_} | {b} | {md_escape(c_)} |" for a_, b, c_ in rows]
    text = "\n".join(out)
    print(text)
    os.makedirs(os.path.join(HOME, ".aris"), exist_ok=True)
    write_if_changed(os.path.join(HOME, ".aris", "health-report.md"), text + "\n")


def main():
    ap = argparse.ArgumentParser(prog="aris-lab", description="配合 ARIS 自动跑实验", formatter_class=argparse.RawDescriptionHelpFormatter,
                                 epilog=__doc__)
    sub = ap.add_subparsers(dest="cmd_name", required=True)
    p = sub.add_parser("new", help="新建实验项目")
    p.add_argument("name")
    p.add_argument("--title")
    p.add_argument("--question")
    p.add_argument("--no-commit", action="store_true", help="只在本地创建，不提交")
    p.add_argument("--key-metrics", help="逗号分隔的关键指标名；看板图表、列顺序和提交说明优先显示它们（之后也可以改 .aris-lab.json）")
    p.set_defaults(fn=cmd_new)
    p = sub.add_parser("run", help="跑一次实验并记录")
    p.add_argument("run_id")
    p.add_argument("--milestone", default="")
    p.add_argument("--desc", default="")
    p.add_argument("--group", default="")
    p.add_argument("--timeout", type=float, default=0, help="超过这么多秒就停掉")
    p.add_argument("--no-commit", action="store_true", help="不提交（批量跑时用，最后 aris-lab publish）")
    p.add_argument("--force", action="store_true", help="覆盖已经完成的同名运行")
    p.add_argument("--project", help="实验项目文件夹（默认从当前目录往上找）")
    p.set_defaults(fn=cmd_run)
    p = sub.add_parser("status", help="列出本项目的运行")
    p.add_argument("--project")
    p.set_defaults(fn=cmd_status)
    p = sub.add_parser("report", help="重新生成看板")
    p.add_argument("--project")
    p.add_argument("--all", action="store_true")
    p.set_defaults(fn=cmd_report)
    p = sub.add_parser("publish", help="提交并推送 experiments/")
    p.add_argument("-m", "--message")
    p.add_argument("--auto", action="store_true")
    p.set_defaults(fn=cmd_publish)
    p = sub.add_parser("reviewer", help="查看 / 测试审稿模型配置")
    p.add_argument("--test", action="store_true")
    p.add_argument("--exec-server", action="store_true", help=argparse.SUPPRESS)
    p.set_defaults(fn=cmd_reviewer)
    p = sub.add_parser("check", help="体检")
    p.set_defaults(fn=cmd_check)
    argv, cmd = sys.argv[1:], []
    if argv[:1] != ["run"]:  # 查看类命令接 | head 时安静退出；run 自己处理，保证记录写完
        signal.signal(signal.SIGPIPE, signal.SIG_DFL)
    if argv[:1] == ["run"]:  # run 的命令写在 -- 后面，前面才是 aris-lab 自己的选项
        if "--" not in argv:
            sys.exit("用法：aris-lab run R001 [--milestone M0 --desc 说明 --group 配置] -- 命令 参数...（命令前面要有 --）")
        i = argv.index("--")
        argv, cmd = argv[:i], argv[i + 1:]
    a = ap.parse_args(argv)
    a.cmd = cmd
    sys.exit(a.fn(a) or 0)


if __name__ == "__main__":
    main()
EOF
chmod +x "$BIN_DIR/aris-lab"

# ARIS 审稿子代理：另一个 Claude 模型 + 专门的审稿提示，只读。
# 没有外部审稿模型（llm-chat / Codex）时，ARIS 的审稿步骤用它做“同家族临时审稿”
mkdir -p "$HOME/.claude/agents"
cat > "$HOME/.claude/agents/aris-reviewer.md" <<'EOF'
---
name: aris-reviewer
description: ARIS 风格的独立审稿人（只读）。只看原始文件（代码、实验计划、结果、日志、论文），独立挑错，给出严重程度、位置和修改要求，最后给出 verdict 和分数。用于实验代码审查、结果是否支持结论、文档和论文审查。没有外部审稿模型（llm-chat / Codex）时，ARIS 的审稿步骤用它做“同家族临时审稿”。调用时只传文件路径和要审什么，不要传执行者自己的总结或解释。
tools: Read, Grep, Glob, Bash
model: sonnet
---

你是 ARIS 自动科研流程里的**独立审稿人（reviewer）**，不是执行者。执行者（主会话）负责写代码、跑实验、写结论；你的工作是用新鲜的眼光找出它的错误。你看不到执行者的思考过程，这正是你的价值：不要替它补全它没写下来的假设。

## 规则

1. **只认原始证据。** 只根据你自己读到的原始文件下判断：代码、`refine-logs/EXPERIMENT_PLAN.md`、`runs/*.json`、`results/*.json`、`logs/*.log`、论文或文档。调用方给你的总结、解释、“已经修好了”一律不算证据，要对照原文自己核实。
2. **只读。** 不修改、不删除、不新建任何文件，不运行 git 的写操作，不安装东西。Bash 只用来读文件、搜索和做只读检查（例如运行已有的测试、用一小段 Python 重算一个数字核对）。
3. **实验代码重点查：**
   - 评估是否用数据集自带的真实标签（拿别的模型的输出当标准答案是严重错误）；
   - 数据划分有没有泄漏（测试集参与了训练、调参或选模型）；
   - 指标的算法对不对（可以用小例子手算核对）；
   - 随机种子、超参数是否和实验计划一致、能否复现；
   - 结果文件里的数字和日志是否一致，有没有没跑过却写出来的数字；
   - 结论是否真的被结果支持（seed 数、方差、样本量够不够；“提升”是否超过噪声）。
4. **文档和论文重点查：** 说法和原始数据是否一致；有没有夸大；步骤照做是否真的能跑通；读者会不会误解。
5. **范围限制（只限制你建议什么，不限制你查什么）：** 不提议哈希、签名之类的防伪机制；不建议为假想的恶意用户加防御；不纠结极端边角情况，除非能指出它在这里真的会发生；能用一句话说清的不要做成复杂评分表。**没有问题就直接说没有问题，不要为了显得认真而编造问题。**

## 输出格式（中文）

1. **一句话总结**
2. **问题清单**：按严重程度排序，每条写
   - 严重程度：CRITICAL（结论或结果会错）/ MAJOR（明显影响可信度或可复现性）/ MINOR（小问题）
   - 位置：`文件:行号`
   - 问题是什么、为什么是问题（引用原文）
   - 具体怎么改
3. **你核实过的地方**：列出你实际检查过、确认没问题的关键点（让执行者知道哪些不用再查）
4. **结论块**（固定格式，供流程读取）：

```
verdict: ready | almost | not ready
score: <1-10>
review_independence: same-family
acceptance_status: provisional
```

`review_independence: same-family` 的意思是：你和执行者都是 Claude 家族的模型，训练来源相近，盲点可能相似。所以你的结论只算**临时审稿**；涉及正式结论（论文里的 claim、投稿前的审计）时，提醒执行者再用另一家模型（llm-chat 配置的审稿模型或 Codex）复核。
EOF

# 注册 ARIS 的审稿工具 llm-chat（用户级 MCP）。Key 不写进配置文件：每次启动时从环境变量 LLM_* 读取
if command -v claude >/dev/null 2>&1; then
  claude mcp remove llm-chat -s user >/dev/null 2>&1 || true
  claude mcp add llm-chat -s user -- "$BIN_DIR/aris-lab" reviewer --exec-server >/dev/null 2>&1 \
    && log "llm-chat MCP registered" || log "llm-chat MCP registration failed"
else
  python3 - <<'PY'
import json, os
path = os.path.expanduser("~/.claude.json")
cfg = json.load(open(path)) if os.path.exists(path) else {}
cfg.setdefault("mcpServers", {})["llm-chat"] = {"type": "stdio", "command": os.environ["BIN_DIR"] + "/aris-lab",
                                               "args": ["reviewer", "--exec-server"], "env": {}}
json.dump(cfg, open(path, "w"), indent=2)
PY
fi

# 注册为用户级 Stop hook（所有项目生效；只改 hooks.Stop，保留 settings.json 里其他设置）
python3 - <<'PY'
import json, os
path = os.path.expanduser("~/.claude/settings.json")
cfg = json.load(open(path)) if os.path.exists(path) else {}
stop = cfg.setdefault("hooks", {}).setdefault("Stop", [])
bin_dir = os.environ.get("BIN_DIR", "/usr/local/bin")
wanted = (f"{bin_dir}/chat-export --source user", f"{bin_dir}/research-site publish --auto >/dev/null 2>&1 || true",
          f"{bin_dir}/aris-lab publish --auto >/dev/null 2>&1 || true")
# 去掉旧版本注册的同名 hook，再按当前路径注册
stop[:] = [e for e in stop if not any(("chat-export --source user" in h.get("command", "")
                                        or "research-site publish --auto" in h.get("command", "")
                                        or "aris-lab publish --auto" in h.get("command", ""))
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

## 自动跑实验（ARIS）

- 用户要跑实验、做实验、用 ARIS 时：实验放在当前仓库的 `experiments/<项目名>/`（没有就先 `aris-lab new <项目名> --title "标题" --question "要回答的问题"`），进入那个文件夹，按它的 `CLAUDE.md` 做。
- 流程：`/experiment-plan`（写计划）→ `/experiment-bridge`（写代码、审代码、先跑 sanity、再跑全部、收结果）→ `/analyze-results` → `/result-to-claim`；要多轮“审稿 → 补实验”时用 `/auto-review-loop`。
- 每次正式运行都用 `aris-lab run <编号> --milestone … --desc … -- <命令>`：它记录日志和指标、更新看板（`DASHBOARD.md` / `.html`）并提交推送。
- 审稿人：有外部审稿模型（`mcp__llm-chat__review`，配了 `LLM_API_KEY`）就用它，算正式审稿；没有就用 Agent 工具调 `aris-reviewer` 子代理（另一个 Claude 模型，只读；只给文件路径和审查要求，不给你自己的总结），报告存进项目的 `review-stage/`，记为同家族临时审稿（`review_independence: same-family`、`acceptance_status: provisional`）。正式结论只认外部审稿。
- 用户说“检查实验环境”，或者每个新对话第一次跑实验之前，运行 `aris-lab check`，把表格给用户看（审稿模型、算力是否就绪）。审稿模型没配置也照常跑，结果里写明“未经外部审稿”。
- 云端容器没有 GPU，也不能 SSH 到别的服务器（只放行 HTTPS）；需要 GPU 时告诉用户：在有 GPU 的机器上装好这套配置并运行 Claude Code（`claude remote-control`），见 https://github.com/NNNoxin/claude-config 的「自动跑实验」一节。
- 每批实验跑完，在回复里写一行：「🧪 实验看板已更新：<提交号> · <项目名> · 共 N 次运行 · experiments/<项目名>/DASHBOARD.md」。
- 回复结束后 Stop hook 会运行 `aris-lab publish --auto`，把漏提交的 `experiments/` 改动补传上去，这只是兜底。
<!-- END cloud-setup -->"""
old = open(path).read() if os.path.exists(path) else ""
pat = re.compile(r"<!-- BEGIN cloud-setup -->.*?<!-- END cloud-setup -->", re.S)
new = pat.sub(lambda _: block, old) if pat.search(old) else (old.rstrip() + "\n\n" + block if old.strip() else block) + "\n"
os.makedirs(os.path.dirname(path), exist_ok=True)
open(path, "w").write(new)
PY

# 如果环境变量里已经有 Cookie，顺便导入（不影响快照的可用性）
[ -n "${XHS_COOKIES:-}" ] && { printf '%s' "$XHS_COOKIES" | xhs-cookies-import || true; }

log "done — run research-init in each new session (aris-lab check for experiments)"
exit 0
