<p align="center">
  <img src="./assets/logo.svg" alt="Statusline HUD logo" width="84" />
</p>

<h1 align="center">Statusline HUD</h1>

<p align="center">
  <a href="./README.md">English</a> | 简体中文
</p>

<p align="center">
  面向 <a href="https://antigravity.google/docs/cli/statusline">Antigravity CLI (<code>agy</code>)</a> 的多行终端状态栏与交互式 <code>/hud</code> 配置插件。
</p>

> [!NOTE]
> 仅适用于 **Antigravity CLI (`agy`)**（Linux / macOS / WSL）；桌面端与 IDE 扩展不渲染自定义 TUI 状态栏。

![Statusline HUD 效果预览](./assets/example.png)

## 快速开始

依赖：`agy`、`bash` 3.2+、`jq` 1.6+，以及可选的 `git`。

1. **安装插件**

   ```bash
   agy plugin install https://github.com/linbo0518/antigravity-hud
   ```

2. **启用与定制**

   打开 `agy` 并输入 **`/hud`**，自动完成环境检查、效果预览与启用引导；或直接执行：

   ```text
   /statusline ~/.gemini/config/plugins/statusline-hud/scripts/statusline.sh
   ```

随时重新运行 `agy plugin install ...` 即可升级，个人偏好会自动保留。

## 使用 `/hud`

全部配置与维护都可以直接通过 `/hud` 或中英文自然语言完成，无需记忆配置文件格式：

- `/hud` — 检查状态、预览当前状态栏并按需开关模块
- `/hud setup` / `/hud uninstall` — 引导启用状态栏或安全卸载
- `/hud hide title` / `/hud show title` — 隐藏或显示任意模块（修改立即热生效）
- `/hud hide cost in split panes` — 仅在窄屏（`<100` 列）单独覆盖显示项
- `/hud check` — 排查依赖、配置或显示异常
- `/hud reset` — 恢复默认配置

## 符号说明

- **Git**：`[...]` 仓库状态（`=` 冲突、`+` 已暂存、`!` 未暂存修改、`✘` 删除、`»` 重命名、`?` 未跟踪、`$` stash、`↑N`/`↓N` 领先/落后提交）与 `(+N −M)` 已跟踪增删行数；窄屏有改动时收敛为 `*`。
- **配额**：已用百分比（绿 `<60%`、黄 `60–89%`、红 `>=90%`）+ 距重置时间；仅返回剩余数量时显示 `<N> left`。
- **Token**：`tok <总量> (<输入>↑ <输出>↓)` 按整场会话累计，其后 `<N> tok/s` 为本轮端到端输出速率。

## 卸载

卸载插件前请**先恢复默认状态栏**：

1. 在 `agy` 中执行 `/statusline delete`。
2. 在终端执行：

```bash
agy plugin uninstall statusline-hud
rm -rf "${XDG_CONFIG_HOME:-$HOME/.config}/statusline-hud" "${XDG_CACHE_HOME:-$HOME/.cache}/statusline-hud"  # 可选
```

<details>
<summary>进阶：手动编辑 <code>config.json</code>、单脚本安装与开发验证</summary>

### 手动编辑 `config.json`

配置位于 `${XDG_CONFIG_HOME:-~/.config}/statusline-hud/config.json`，修改后下次刷新自动生效：

| 行 | 开关（从左到右） |
| --- | --- |
| 1 | `showMode`, `showModel`, `showContext`, `showPath`, `showGit` |
| 2 | `showGeminiQuota`, `show3pQuota` |
| 3 | `showArtifacts`, `showSubagents`, `showTasks`, `showSandbox`, `showTokens`, `showTokenSpeed`, `showCache`, `showDuration`, `showCost`, `showTitle` |

核心状态始终在第一行开头。所有开关均为布尔值且默认全部开启；计数与状态项（上下文、产物、子代理、任务、沙箱、Token、速度、时长）在 CLI 省略时按 `0`、`0.0%`、`0 tok/s`、`0m` 或 `OFF` 照常显示，确实无值的项（如未生成标题、非 Git 目录、未上报的配额/缓存/费用）与空行自动省略。低于 100 列时生效 `narrow` 覆盖（未写则继承）并使用短写形式，内容过多时终端可能折行。

```json
{
  "showTitle": false,
  "showCost": false,
  "narrow": { "showCost": true }
}
```

### 手动单脚本安装（不含 `/hud`）

```bash
cp scripts/statusline.sh ~/.gemini/antigravity-cli/statusline.sh
chmod +x ~/.gemini/antigravity-cli/statusline.sh
```

随后在 `agy` 中执行 `/statusline ~/.gemini/antigravity-cli/statusline.sh`。

### 开发与校验

```bash
./tests/test.sh
agy plugin validate --strict .
```

</details>

## 致谢

- **[claude-hud](https://github.com/jarrodwatts/claude-hud)**（by Jarrod Watts，MIT License）— 多行 HUD 层次与 `/hud` 交互思路启发。
- **[Google Antigravity CLI 官方 `statusline` 示例](https://github.com/google-antigravity/antigravity-cli/tree/main/examples/statusline)** — 16 色基调与状态协议参考。

## License

[MIT](./LICENSE)
