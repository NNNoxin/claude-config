# claude-config

Claude Code 一键配置。换账号、换电脑、换环境，一条命令装好：

```bash
curl -fsSL https://raw.githubusercontent.com/NNNoxin/claude-config/main/setup.sh | bash
```

本仓库只有配置脚本和规则，**不含任何 Cookie、密码或对话内容**。Cookie 放在各自环境的环境变量里。

## 装了什么

| 内容 | 作用 |
|---|---|
| Agent Reach + Exa 全网搜索 + Jina 网页读取 | 搜索和读取网页、Reddit、linux.do、CSDN、YouTube、V2EX、GitHub |
| 小红书 MCP（带两个修复补丁） | 用你的账号 Cookie 搜索小红书 |
| `research-init` / `research-check` | 每个对话开始时导入 Cookie、启动服务、检查各网站，输出表格 |
| `research-site` | 调研档案馆：每次调研的问题、需求、搜索记录、全部来源和分析，生成 HTML 网站并推送 |
| `chat-export` | 每次回复后把对话转成 HTML + Markdown，推送到仓库的 `chat-logs/`（需按仓库开启） |
| `~/.claude/CLAUDE.md` 规则 | 每步自动 commit + push、每次回复末尾汇报更新内容、调研流程 |
| `~/.claude/skills/research-toolkit` | 调研 Skill：每个网站怎么查 |
| `~/.claude/settings.json` Stop hook | 回复结束后自动导出对话记录、补发布调研网站、补提交实验记录 |
| [ARIS](https://github.com/wanshuiyin/Auto-claude-code-research-in-sleep) 的 22 个 Skill | 自动跑实验：写实验计划、写代码、审代码、先小测试再正式跑、汇总结果、多轮审稿改进（`/experiment-plan`、`/experiment-bridge`、`/auto-review-loop` 等） |
| `aris-lab` | 实验项目工具：新建项目、跑实验并记录日志和指标、生成看板（Markdown + 网页）、提交推送、体检 |
| `llm-chat` MCP | ARIS 的审稿模型：任意 OpenAI 兼容 API（魔搭、DeepSeek、OpenRouter 等），Key 从环境变量读取 |

## 在 claude.ai/code 云端使用

1. 左边栏 **New** → 输入框上方**云朵图标** → **Cloud** → 环境名右侧**齿轮**。
2. **Network access** 选 **Full**。
3. **Setup script** 里只写一行：
   ```bash
   curl -fsSL https://raw.githubusercontent.com/NNNoxin/claude-config/main/setup.sh | bash
   ```
4. **Environment variables**（可选，不填就不能搜对应平台）：
   ```
   XHS_COOKIES=web_session=...; id_token=...; ...
   TWITTER_COOKIES=auth_token=...; ct0=...; ...
   ```
   用 Chrome 插件 Cookie-Editor 登录后 Export → Header String 导出，整行粘在等号后面。建议用小号。
   要用 ARIS 审稿模型再加两行（见下面「自动跑实验」）：
   ```
   LLM_PROVIDER=modelscope
   LLM_API_KEY=...
   ```
5. 保存，新开对话，说“**检查调研工具**”。

> 云端环境会把 setup 的结果缓存约 7 天。本仓库更新后想马上生效：在对话里让 Claude 运行一次上面的 curl 命令，
> 或者在 Setup script 里随便改一个字（比如末尾加个注释）触发重建。

## 在自己电脑上使用（macOS / Linux / Windows 的 WSL）

前提：已装 Claude Code、git、Python 3、Node.js；要用小红书还需要 Go。

```bash
curl -fsSL https://raw.githubusercontent.com/NNNoxin/claude-config/main/setup.sh | bash
```

- 没有 `/usr/local/bin` 写权限时，命令装到 `~/.local/bin`，并自动加进 `~/.bashrc` / `~/.zshrc` 的 PATH。重开终端生效。
- Cookie 用环境变量提供（写进 `~/.zshrc` 等），然后在 Claude Code 里说“检查调研工具”。
- 在本机用 X / 推特不会被屏蔽（云服务器 IP 会被 X 拒绝）。

## 自动跑实验（ARIS）

对 Claude 说“**用 ARIS 跑实验：<你的想法>**”。Claude 会在当前仓库的 `experiments/<项目名>/` 里：
写实验计划 → 写代码 → 审代码 → 先跑小测试 → 正式跑（多个随机种子）→ 生成看板 → 判断结果支持哪些结论，每一步都提交推送。
第一次建项目时会生成 `experiments/README.md`，里面有完整的使用说明。新对话里说“**检查实验环境**”会运行 `aris-lab check`。

**审稿模型**（可选，建议配）：ARIS 让另一家的模型来挑刺。在环境变量里加：

| 用哪家 | `LLM_PROVIDER` | 说明 |
|---|---|---|
| 魔搭 ModelScope | `modelscope` | 免费额度（每天约 2000 次），Key 以 `ms-` 开头，要先绑定阿里云账号 |
| DeepSeek | `deepseek` | 按量付费，便宜 |
| OpenRouter | `openrouter` | 一个 Key 用多家模型 |
| OpenAI / Gemini / Kimi / 智谱 / 通义 / 硅基流动 | `openai` / `gemini` / `moonshot` / `zhipu` / `dashscope` / `siliconflow` | 再加 `LLM_MODEL=模型名` |

然后 `LLM_API_KEY=你的 Key`。不配也能跑，结果会标注“未经外部审稿”。

**GPU**：云端容器没有 GPU，网络只放行 HTTPS（不能 SSH 到服务器，也连不上 Modal），适合 CPU 小实验和调大模型 API 的评测。
要训练模型，就在有 GPU 的机器上：装 Claude Code → 运行上面的一键命令 → `git clone` 你的仓库 → 在仓库里运行 `claude remote-control`，
然后在 Claude 网页或手机 App 里继续用，和云端一样。

## 测试

改了 `setup.sh` 里的 aris-lab 之后，先跑一遍测试再推送：

```bash
python3 tests/test_aris_lab.py              # 测 setup.sh 里的版本（约 10 秒，不联网）
python3 tests/test_aris_lab.py --installed  # 测已经装好的 aris-lab 命令
python3 tests/test_aris_lab.py --network    # 另外测审稿模型能不能连上（用假 Key，期望 401）
```

覆盖：新建项目、跑实验（完成 / 失败 / 超时 / 命令不存在 / 重复编号）、看板汇总和图表、24 个运行同时跑、
提交前拦截密钥和大文件、改名、说明文档自动更新、审稿模型配置、体检。
全部在临时目录里的假仓库中进行，不碰真实仓库和配置。最后一行显示“失败 0”就是全部通过。

## 在项目里开启对话记录

对 Claude 说“**开启对话记录**”。Claude 会先确认仓库是私有的，再在仓库根目录创建 `.chat-export-on`。
之后每次回复，对话会自动保存到 `chat-logs/`。Cookie、Token 会被替换成 `[已隐藏]`。

## 已知限制

| 网站 | 限制 |
|---|---|
| X / 推特 | 云服务器 IP 被 X 屏蔽；本机可用 |
| 小红书 | 用真账号搜索，频率太高有封号风险；Claude 会控制搜索次数和间隔 |
| Reddit / linux.do / CSDN | 云端直连被封，经 Exa 中转；最新几小时的帖子可能搜不到 |
| Discord | 不支持 |
| GPU 实验 | 云端容器没有 GPU、不能 SSH；在 GPU 机器上运行 Claude Code（Remote Control） |
| ARIS 审稿 | 默认的 Codex（GPT）审稿需要 ChatGPT 账号，这里改用 `llm-chat` + 任意 OpenAI 兼容 API |
| 其他 AI 编程工具（Cursor、Codex 等） | 命令行工具都能用；`CLAUDE.md`、Skill、hook 是 Claude Code 专用格式 |
