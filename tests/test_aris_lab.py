#!/usr/bin/env python3
"""aris-lab 的自动测试。

在临时目录里建一个带“远端”的假 git 仓库，把 aris-lab 的各种用法跑一遍：
新建项目、跑实验（完成 / 失败 / 超时 / 命令不存在）、看板汇总、并行运行、
提交前拦截密钥和大文件、改名、说明文档自动更新、审稿模型配置、体检。
不联网（除非加 --network），不会碰你的真实仓库和配置，大约 1 分钟。

用法：
  python3 tests/test_aris_lab.py              # 测 setup.sh 里内嵌的 aris-lab（改完 setup.sh 先跑这个）
  python3 tests/test_aris_lab.py --installed  # 测已经装好的 aris-lab 命令
  python3 tests/test_aris_lab.py --network    # 另外测审稿模型连不连得上（用假 Key，期望 401）
  python3 tests/test_aris_lab.py --keep       # 跑完保留临时目录，方便排查

全部通过时退出码为 0，有失败时为 1。
"""
import argparse
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import time
from concurrent.futures import ThreadPoolExecutor

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SETUP = os.path.join(ROOT, "setup.sh")
REAL_HOME = os.path.expanduser("~")
RESULTS = {"pass": [], "fail": [], "skip": []}

# 测试用的假密钥在运行时拼出来，源码里不出现像真密钥的字符串
FAKE_SK = "sk-" + "abcdefghij" * 3
FAKE_SK2 = "sk-" + "zyxwvutsrq" * 3
FAKE_ENV_SECRET = "zz-test-secret-" + "1234567890" * 2
FAKE_MS = "ms-" + "-".join(["0" * 8, "0" * 4, "0" * 4, "0" * 4, "0" * 12])

EXP_SCRIPT = r'''
import argparse, json, os, sys, time
ap = argparse.ArgumentParser()
ap.add_argument("--seed", type=int, default=0)
ap.add_argument("--mode", default="ok")
a = ap.parse_args()
print("训练中…", flush=True)
if a.mode == "fail":
    sys.exit(3)
if a.mode == "slow":
    time.sleep(60)
if a.mode == "spam":
    for i in range(50000):
        print(i)
res = {"metrics": {"a": a.seed + 0.25, "b": 7.35e-6 * (a.seed + 1)}, "config": vars(a)}
if a.mode == "line":
    print("ARIS_RESULT " + json.dumps(res))
    sys.exit(0)
json.dump(res, open(os.environ.get("ARIS_RESULT_FILE", "result.json"), "w"))
'''


def check(name, ok, detail=""):
    RESULTS["pass" if ok else "fail"].append(name)
    print(f"{'✅' if ok else '❌'} {name}" + ("" if ok or not detail else f"\n     {str(detail)[:400]}"), flush=True)
    return ok


def skip(name, why):
    RESULTS["skip"].append(name)
    print(f"➖ {name}（跳过：{why}）", flush=True)


def extract_from_setup(dest):
    s = open(SETUP, encoding="utf-8").read()
    head = "cat > \"$BIN_DIR/aris-lab\" <<'EOF'\n"
    i = s.index(head) + len(head)
    j = s.index("\nEOF\n", i)
    with open(dest, "w", encoding="utf-8") as f:
        f.write(s[i:j + 1])
    return dest


class Lab:
    def __init__(self, exe, tmp):
        self.exe, self.tmp = exe, tmp
        self.home = os.path.join(tmp, "home")  # 假的 HOME：锁文件、审稿配置都放这里，不碰真实配置
        os.makedirs(self.home)
        self.remote = os.path.join(tmp, "remote.git")
        self.repo = os.path.join(tmp, "work")
        subprocess.run(["git", "init", "-q", "--bare", self.remote], check=True)
        subprocess.run(["git", "clone", "-q", self.remote, self.repo], check=True, capture_output=True)
        for k, v in (("user.email", "test@example.com"), ("user.name", "aris-lab test")):
            self.git("config", k, v)
        self.git("commit", "-q", "--allow-empty", "-m", "init")
        self.git("push", "-q", "-u", "origin", "HEAD")
        self.proj = os.path.join(self.repo, "experiments", "p")

    def env(self, **extra):
        e = {k: v for k, v in os.environ.items() if not k.startswith("LLM_")}
        e["HOME"] = self.home
        e.update(extra)
        return e

    def run(self, *args, cwd=None, env=None, timeout=180):
        return subprocess.run(self.exe + list(args), cwd=cwd or self.proj, env=env or self.env(),
                              capture_output=True, text=True, timeout=timeout)

    def git(self, *args):
        return subprocess.run(["git", "-C", self.repo, *args], capture_output=True, text=True)

    def head(self):
        return self.git("rev-parse", "--short", "HEAD").stdout.strip()

    def remote_head(self):
        return subprocess.run(["git", "-C", self.remote, "rev-parse", "--short", "HEAD"],
                              capture_output=True, text=True).stdout.strip()

    def rec(self, rid):
        return json.load(open(os.path.join(self.proj, "runs", f"{rid}.json"), encoding="utf-8"))

    def read(self, rel):
        return open(os.path.join(self.proj, rel), encoding="utf-8").read()


def summary_rows(dashboard):
    m = re.search(r"## 按配置汇总.*?\n(.*?)\n## 全部运行", dashboard, re.S)
    if not m:
        return []
    return [line for line in m.group(1).splitlines() if line.startswith("| ") and not line.startswith("| 配置")]


def test_new(lab):
    r = lab.run("new", "p", "--title", "测试项目", "--question", "问题？", "--key-metrics", "b,a", cwd=lab.repo)
    check("new：新建项目成功", r.returncode == 0, r.stderr or r.stdout)
    need = [".aris-lab.json", "CLAUDE.md", "README.md", "EXPERIMENT_LOG.md", ".gitignore", "requirements.txt",
            "DASHBOARD.md", "DASHBOARD.html", "runs", "results", "logs", "src", "refine-logs"]
    missing = [n for n in need if not os.path.exists(os.path.join(lab.proj, n))]
    check("new：项目文件和目录齐全", not missing, f"缺少：{missing}")
    req = lab.read("requirements.txt")
    check("new：requirements.txt 只有注释（pip install -r 能直接用）",
          all(not ln.strip() or ln.lstrip().startswith("#") for ln in req.splitlines()), req)
    gi = lab.read(".gitignore")
    check("new：.gitignore 忽略 .venv 和 result.json", ".venv/" in gi and "result.json" in gi, gi)
    readme = open(os.path.join(lab.repo, "experiments", "README.md"), encoding="utf-8").read()
    check("new：experiments/README.md 有项目列表和使用说明区块",
          "<!-- BEGIN aris-lab projects -->" in readme and "<!-- BEGIN aris-lab guide -->" in readme
          and "测试项目" in readme)
    log = subprocess.run(["git", "-C", lab.remote, "log", "--format=%s"], capture_output=True, text=True).stdout
    check("new：自动提交并推送到远端", "实验 p：新建实验项目" in log, log)
    before = lab.head()
    r = lab.run("new", "q", "--no-commit", cwd=lab.repo)
    check("new --no-commit：只在本地创建、不提交", r.returncode == 0 and lab.head() == before, r.stdout + r.stderr)


def test_runs(lab):
    with open(os.path.join(lab.proj, "src", "exp.py"), "w", encoding="utf-8") as f:
        f.write(EXP_SCRIPT)
    r = lab.run("run", "R001", "--milestone", "M1", "--group", "g1", "--", "python3", "src/exp.py", "--seed", "0")
    rec = lab.rec("R001")
    check("run：正常完成并记录指标", r.returncode == 0 and rec["status"] == "done" and rec["metrics"].get("a") == 0.25,
          r.stdout[-300:] + r.stderr)
    log = lab.git("log", "--format=%h %s").stdout
    snap = [ln.split()[0] for ln in log.splitlines() if "实验代码快照：p R001 运行前" in ln]
    check("run：运行前自动给代码拍快照提交，记录里的代码版本就是它",
          bool(snap) and rec["git_commit"] == snap[0] and rec["code_dirty"] is False, f"{snap} {rec.get('git_commit')}")
    check("run：结果提交并推送到远端", lab.remote_head() == lab.head() and "实验 p/R001" in log, log[:300])
    check("run：完整日志写进 logs/", "训练中" in lab.read("logs/R001.log"))

    lab.run("run", "R002", "--milestone", "M1", "--group", "g1", "--", "python3", "src/exp.py", "--seed", "1")
    lab.run("run", "R003", "--milestone", "M1", "--group", "g1", "--no-commit", "--", "python3", "src/exp.py", "--seed", "2")
    check("run --no-commit：只有结果变化时不算“代码有未提交改动”", lab.rec("R003")["code_dirty"] is False)
    lab.run("run", "R004", "--milestone", "M1", "--no-commit", "--", "python3", "src/exp.py", "--seed", "9")
    dash = lab.read("DASHBOARD.md")
    rows = summary_rows(dash)
    check("看板：同一 --group 的 3 次运行合并成“均值 ± 标准差”", len(rows) == 1 and re.match(r"\| g1 \| 3 \|.*±", rows[0]),
          rows)
    check("看板：没有 --group 的运行不进汇总表、只在全部运行里", "| R004 |" in dash and len(rows) == 1)
    check("看板：关键指标（--key-metrics b,a）排在最前面", "| 配置 | 完成次数 | b | a |" in dash)
    check("看板：很小的数用科学计数法显示", re.search(r"\d\.\d\de-0\d", dash) is not None and "0.0000 ±" not in dash)
    check("看板：只有一个配置组时不画柱状图", "<svg" not in lab.read("DASHBOARD.html"))
    lab.run("run", "R011", "--milestone", "M1", "--group", "g2", "--no-commit", "--", "python3", "src/exp.py", "--seed", "4")
    check("看板：有两个以上配置组时，网页版画出柱状图对比", "<svg" in lab.read("DASHBOARD.html"))

    r = lab.run("run", "R005", "--no-commit", "--", "python3", "src/exp.py", "--seed", "3", "--mode", "line")
    check("run：从标准输出的 ARIS_RESULT 行读取指标", r.returncode == 0 and lab.rec("R005")["metrics"].get("a") == 3.25)

    r = lab.run("run", "R006", "--no-commit", "--", "python3", "src/exp.py", "--mode", "fail")
    check("run：命令失败时记为失败，退出码原样返回", r.returncode == 3 and lab.rec("R006")["status"] == "failed",
          f"退出码 {r.returncode}")
    t0 = time.time()
    r = lab.run("run", "R007", "--no-commit", "--timeout", "2", "--", "python3", "src/exp.py", "--mode", "slow")
    check("run --timeout：超时自动停掉，退出码 124", r.returncode == 124 and lab.rec("R007")["status"] == "timeout"
          and time.time() - t0 < 30, f"退出码 {r.returncode}，用时 {time.time() - t0:.0f} 秒")
    r = lab.run("run", "R008", "--no-commit", "--", "no-such-command-xyz")
    check("run：命令不存在时记为失败（退出码 127）", r.returncode == 127 and "无法启动命令" in lab.rec("R008")["note"])
    r = lab.run("run", "R009", "python3", "src/exp.py")
    check("run：命令前没有 -- 时给出用法提示", r.returncode != 0 and "命令前面要有 --" in (r.stderr + r.stdout))
    r = lab.run("run", "R001", "--", "python3", "src/exp.py")
    check("run：已完成的编号不能覆盖", r.returncode != 0 and "已经跑完了" in (r.stderr + r.stdout))
    r = lab.run("run", "R001", "--force", "--milestone", "M1", "--group", "g1", "--no-commit", "--",
                "python3", "src/exp.py", "--seed", "0")
    check("run --force：可以覆盖重跑", r.returncode == 0 and lab.rec("R001")["status"] == "done")

    r = lab.run("run", "R010", "--project", "experiments/p", "--no-commit", "--", "python3", "src/exp.py", "--seed", "5",
                cwd=lab.repo)
    check("run --project：从仓库根目录启动，命令照样在项目文件夹里执行",
          r.returncode == 0 and lab.rec("R010")["status"] == "done" and lab.rec("R010")["workdir"] == ".",
          r.stdout[-300:] + r.stderr)


def test_robustness(lab):
    p = subprocess.Popen(lab.exe + ["run", "P001", "--no-commit", "--", "python3", "src/exp.py", "--mode", "spam"],
                         cwd=lab.proj, env=lab.env(), stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
    p.stdout.readline()
    p.stdout.readline()
    p.stdout.close()  # 相当于接了 | head -2
    code = p.wait(timeout=120)
    check("run：输出被提前关掉（| head）时照样把记录写完", code == 0 and lab.rec("P001")["status"] == "done", f"退出码 {code}")

    ids = [f"S{i:02d}" for i in range(1, 25)]

    def go(rid):
        return lab.run("run", rid, "--milestone", "S", "--group", "stress", "--no-commit", "--",
                       "python3", "src/exp.py", "--seed", "1").returncode
    with ThreadPoolExecutor(12) as ex:
        codes = list(ex.map(go, ids))
    recs = [lab.rec(i) for i in ids]
    check("并行：24 次运行同时跑，全部记为完成，没有残留进程号",
          all(c == 0 for c in codes) and all(r["status"] == "done" for r in recs)
          and not any("pid" in r for r in recs), [r["status"] for r in recs])
    try:
        dash = lab.read("DASHBOARD.md")
        readme = open(os.path.join(lab.repo, "experiments", "README.md"), encoding="utf-8").read()
        intact = "## 全部运行" in dash and "<!-- BEGIN aris-lab guide -->" in readme and "# 🧪 实验区" in readme
    except UnicodeDecodeError as e:
        intact = False
        readme = repr(e)
    check("并行：看板和 experiments/README.md 没有被同时写坏", intact, readme[:200])

    dead = subprocess.Popen([sys.executable, "-c", "pass"])
    dead.wait()
    rec = {"run_id": "L001", "milestone": "L", "status": "running", "pid": dead.pid, "host": socket.gethostname(),
           "started": "2026-01-01 00:00:00", "metrics": {}, "log": "logs/L001.log"}
    try:
        rec["boot_id"] = open("/proc/sys/kernel/random/boot_id").read().strip()
    except OSError:
        pass
    path = os.path.join(lab.proj, "runs", "L001.json")
    json.dump(rec, open(path, "w"), ensure_ascii=False)
    out = lab.run("status").stdout
    still = json.load(open(path))["status"]
    check("中断检测：进程已不在的运行显示为“中断”，但不改写记录文件",
          any(ln.startswith("L001") and "中断" in ln for ln in out.splitlines()) and still == "running", out[-300:])
    os.remove(path)


def test_publish_and_guards(lab):
    r = lab.run("publish", "-m", "测试：批量提交")
    check("publish：提交并推送实验区的改动", r.returncode == 0 and lab.remote_head() == lab.head(), r.stdout + r.stderr)
    before = lab.head()
    lab.run("report")
    lab.run("publish", "--auto")
    lab.run("publish", "--auto")
    check("publish --auto：没有改动时不产生空提交（看板内容是确定的）", lab.head() == before)

    src = os.path.join(lab.proj, "src")
    open(os.path.join(src, "ok.py"), "w").write("print('ok')\n")
    open(os.path.join(src, "leak.py"), "w").write(f"api = '{FAKE_SK}'\n")
    open(os.path.join(lab.proj, "logs", "leak.log"), "w").write(f"loaded key {FAKE_ENV_SECRET}\n")
    with open(os.path.join(lab.proj, "results", "big.bin"), "wb") as f:
        f.truncate(25 * 1024 * 1024)
    r = lab.run("publish", "-m", "测试：拦截", env=lab.env(FAKE_API_KEY=FAKE_ENV_SECRET))
    names = lab.git("show", "--name-only", "--format=", "HEAD").stdout
    history = lab.git("log", "-p", "--all").stdout
    check("拦截：含疑似密钥的文件不提交（格式像密钥 / 等于环境变量里的密钥）",
          "leak.py" not in names and "leak.log" not in names and FAKE_SK not in history
          and FAKE_ENV_SECRET not in history and "发现疑似密钥" in r.stdout, r.stdout)
    check("拦截：超过 20 MB 的文件不提交", "big.bin" not in names and "超过 20 MB" in r.stdout, r.stdout)
    check("拦截：其他正常文件照常提交", "experiments/p/src/ok.py" in names, names)
    for rel in ("src/leak.py", "logs/leak.log", "results/big.bin"):
        os.remove(os.path.join(lab.proj, rel))

    open(os.path.join(src, "tracked.py"), "w").write("x = 1\n")
    lab.run("publish", "-m", "测试：已跟踪文件")
    with open(os.path.join(src, "tracked.py"), "a") as f:
        f.write(f"k = '{FAKE_SK2}'\n")
    lab.run("publish", "-m", "测试：已跟踪文件加密钥")
    check("拦截：已经提交过的文件后来加了密钥，也不会被提交",
          FAKE_SK2 not in lab.git("log", "-p", "--all").stdout
          and FAKE_SK2 in lab.git("diff", "--", "experiments/p/src/tracked.py").stdout)
    lab.git("checkout", "-q", "--", "experiments/p/src/tracked.py")

    lab.git("mv", "experiments/p/src/ok.py", "experiments/p/src/renamed.py")
    lab.run("publish", "-m", "测试：改名")
    tree = lab.git("ls-tree", "-r", "--name-only", "HEAD").stdout
    check("改名：新旧文件名都正确提交（旧的删掉、新的加上）",
          "experiments/p/src/renamed.py" in tree and "experiments/p/src/ok.py" not in tree
          and not lab.git("status", "--porcelain", "--", "experiments/p/src").stdout.strip())

    readme_path = os.path.join(lab.repo, "experiments", "README.md")
    s = open(readme_path, encoding="utf-8").read()
    s = s.replace("## 看结果", "## 看结果（被改坏）") + "\n我自己加的说明\n"
    open(readme_path, "w", encoding="utf-8").write(s)
    lab.run("report")
    s = open(readme_path, encoding="utf-8").read()
    check("说明文档：使用说明区块自动恢复，区块外自己写的内容保留",
          "被改坏" not in s and "## 看结果" in s and "<!-- BEGIN aris-lab guide -->" in s and "我自己加的说明" in s)


def test_reviewer(lab, network):
    r = lab.run("reviewer")
    check("审稿模型：没配置时提示怎么配", r.returncode == 1 and "未配置" in r.stdout, r.stdout)
    r = lab.run("reviewer", env=lab.env(LLM_PROVIDER="deepseek", LLM_API_KEY=FAKE_SK))
    check("审稿模型：LLM_PROVIDER 自动补全地址和默认模型", "deepseek · deepseek-chat" in r.stdout, r.stdout)
    r = lab.run("reviewer", env=lab.env(LLM_API_KEY=FAKE_MS))
    check("审稿模型：ms- 开头的 Key 自动认成魔搭", "modelscope" in r.stdout, r.stdout)
    if network:
        r = lab.run("reviewer", "--test", env=lab.env(LLM_PROVIDER="deepseek", LLM_API_KEY=FAKE_SK))
        check("审稿模型（联网）：假 Key 得到 401，说明连得上服务器", "HTTP 401" in r.stdout, r.stdout)
    else:
        skip("审稿模型（联网）", "没加 --network")

    server = os.path.join(REAL_HOME, "aris_repo", "mcp-servers", "llm-chat", "server.py")
    venv_py = os.path.join(REAL_HOME, ".aris-venv", "bin", "python")
    if not (os.path.exists(server) and os.path.exists(venv_py)):
        skip("审稿工具 MCP 握手", "这台机器没装 ARIS（~/aris_repo）或 ~/.aris-venv")
        return
    msgs = [
        {"jsonrpc": "2.0", "id": 1, "method": "initialize",
         "params": {"protocolVersion": "2024-11-05", "capabilities": {}, "clientInfo": {"name": "test", "version": "0"}}},
        {"jsonrpc": "2.0", "method": "notifications/initialized"},
        {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
    ]
    env = {k: v for k, v in os.environ.items() if not k.startswith("LLM_")}
    env.update(HOME=REAL_HOME, LLM_PROVIDER="deepseek", LLM_API_KEY=FAKE_SK)
    p = subprocess.run(lab.exe + ["reviewer", "--exec-server"], input="".join(json.dumps(m) + "\n" for m in msgs),
                       capture_output=True, text=True, env=env, timeout=60)
    tools = set()
    for line in p.stdout.splitlines():
        try:
            tools |= {t["name"] for t in json.loads(line).get("result", {}).get("tools", [])}
        except ValueError:
            pass
    check("审稿工具 MCP 握手：提供 chat / review / review_reply", {"chat", "review", "review_reply"} <= tools,
          f"{sorted(tools)} {p.stderr[-200:]}")


def test_check(lab):
    r = lab.run("check", cwd=lab.repo)
    rows = ("| ARIS 仓库 |", "| ARIS skills |", "| 审稿模型 |", "| 审稿工具注册 |", "| 审稿子代理 |", "| Codex 审稿 |", "| 算力 |")
    check("check：体检表能正常输出", r.returncode == 0 and all(x in r.stdout for x in rows), r.stdout + r.stderr)


def test_reviewer_agent():
    """setup.sh 安装的审稿子代理：格式正确、只读、写明是同家族临时审稿。"""
    s = open(SETUP, encoding="utf-8").read()
    head = "cat > \"$HOME/.claude/agents/aris-reviewer.md\" <<'EOF'\n"
    if head not in s:
        check("审稿子代理：setup.sh 会安装 ~/.claude/agents/aris-reviewer.md", False, "setup.sh 里没找到")
        return
    i = s.index(head) + len(head)
    text = s[i:s.index("\nEOF\n", i)]
    m = re.match(r"---\n(.*?)\n---\n(.*)", text, re.S)
    meta = dict(line.split(":", 1) for line in m.group(1).splitlines() if ":" in line) if m else {}
    meta = {k.strip(): v.strip() for k, v in meta.items()}
    tools = {t.strip() for t in meta.get("tools", "").split(",")}
    check("审稿子代理：定义格式正确（名字、说明、模型、工具）",
          bool(m) and meta.get("name") == "aris-reviewer" and meta.get("description") and meta.get("model"), meta)
    check("审稿子代理：只读（没有 Write / Edit 工具）", tools and not tools & {"Write", "Edit", "NotebookEdit"}, tools)
    body = m.group(2) if m else ""
    check("审稿子代理：报告里写明同家族、临时审稿",
          "review_independence: same-family" in body and "acceptance_status: provisional" in body)


def main():
    ap = argparse.ArgumentParser(description="aris-lab 的自动测试")
    ap.add_argument("--installed", action="store_true", help="测已经装好的 aris-lab 命令，而不是 setup.sh 里的版本")
    ap.add_argument("--network", action="store_true", help="另外测审稿模型能不能连上（需要联网）")
    ap.add_argument("--keep", action="store_true", help="保留临时目录")
    a = ap.parse_args()

    tmp = tempfile.mkdtemp(prefix="aris-lab-test-")
    try:
        if a.installed:
            path = shutil.which("aris-lab")
            if not path:
                sys.exit("没找到 aris-lab 命令，先运行 setup.sh")
            exe = [path]
            print(f"测试已安装的 aris-lab：{path}")
        else:
            r = subprocess.run(["bash", "-n", SETUP], capture_output=True, text=True)
            check("setup.sh 语法正确", r.returncode == 0, r.stderr)
            path = extract_from_setup(os.path.join(tmp, "aris-lab.py"))
            r = subprocess.run([sys.executable, "-m", "py_compile", path], capture_output=True, text=True)
            check("setup.sh 里内嵌的 aris-lab 能编译", r.returncode == 0, r.stderr)
            exe = [sys.executable, path]
            test_reviewer_agent()
            print("测试 setup.sh 里内嵌的 aris-lab")
        lab = Lab(exe, tmp)
        for fn in (test_new, test_runs, test_robustness, test_publish_and_guards):
            try:
                fn(lab)
            except Exception as e:  # 一组出错不影响其他组
                check(f"{fn.__name__} 运行时出错", False, repr(e))
        try:
            test_reviewer(lab, a.network)
            test_check(lab)
        except Exception as e:
            check("审稿模型 / 体检测试运行时出错", False, repr(e))
    finally:
        if a.keep:
            print(f"临时目录保留在：{tmp}")
        else:
            shutil.rmtree(tmp, ignore_errors=True)
    n_pass, n_fail, n_skip = (len(RESULTS[k]) for k in ("pass", "fail", "skip"))
    print(f"\n结果：通过 {n_pass}，失败 {n_fail}，跳过 {n_skip}")
    sys.exit(1 if n_fail else 0)


if __name__ == "__main__":
    main()
