# 开发环境与远程会话

本文只记录可复用的开发方法。具体某次临时目录、账号、网络和容器评估记录已移到
[`history/development-notes.md`](history/development-notes.md)；那些快照不代表
当前环境。

## 1. 分层原则

| 层 | 负责 | 不负责 |
| --- | --- | --- |
| NixOS 系统（`modules/`、`hosts/`） | 用户、SSH、网络、桌面、音频、字体、容器/虚拟化等基础设施 | 具体项目的 Python/Node 版本 |
| Home Manager（`home/calendar/`） | Fish、Git、direnv、tmux、Helix、常用 CLI 和终端 | 项目依赖、全局 pip/npm 包 |
| 项目 devShell（项目自己的 `flake.nix`） | Python/Node/编译器/LSP CLI 等可执行文件 | 系统服务、全局配置 |
| 项目数据 | `.venv`、`node_modules`、`.direnv`、`.pnpm-store` | 不进入 Git，必要时可删除重建 |

换项目不会改变系统 Python/Node；删除项目的 `.venv` 或 `node_modules` 不会影响
其他项目。`uv` 下载缓存和 pnpm store 不是系统包管理器，清理它们不会破坏 NixOS。

## 2. 项目 devShell

Python 项目使用固定的 nixpkgs 输入，不在系统层安装项目包。示意：

```nix
{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/<commit>";

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      python = pkgs.python313;
    in {
      devShells.${system}.default = pkgs.mkShell {
        packages = [ python pkgs.uv pkgs.ruff ];
        shellHook = ''
          export UV_PYTHON=${python}/bin/python3.13
          export UV_PYTHON_DOWNLOADS=never
        '';
      };
    };
}
```

项目 `pyproject.toml` 只声明项目元数据和 dev group；pytest 不装到系统：

```toml
[project]
name = "uv-demo"
version = "0.1.0"
requires-python = ">=3.12"
dependencies = []

[dependency-groups]
dev = ["pytest>=8"]

[tool.pytest.ini_options]
testpaths = ["tests"]
pythonpath = ["src"]
```

典型命令：

```bash
nix flake lock
nix develop --command bash -c '
  uv lock
  uv sync
  uv run pytest -q
'

nix develop --command bash -c '
  uv lock --check
  uv sync --frozen
  ruff check src tests
  ruff format --check src tests
'
```

Node.js/TypeScript 项目同样由 devShell 提供 Node 和 pnpm，项目依赖留在本地
`node_modules`：

```nix
{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/<commit>";

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      devShells.${system}.default = pkgs.mkShell {
        packages = [ pkgs.nodejs_22 pkgs.pnpm_10 ];
      };
    };
}
```

项目内 `.npmrc` 可把 pnpm store 放在项目目录，避免写进用户级全局目录：

```ini
store-dir=.pnpm-store
```

`package.json` 的检查与启动脚本仍用项目自己的依赖，例如
`pnpm run check`（`tsc --noEmit`）和 `pnpm start`。pnpm 提示
`Ignored build scripts` 时，先阅读该包的 postinstall；确实需要原生构建再用
`pnpm approve-builds` 精确放行，不要全局关闭脚本保护。

## 3. 复现一个新项目

```bash
mkdir my-project && cd my-project
# 创建项目 flake.nix 和 .envrc：
printf 'use flake\n' > .envrc

nix flake lock
nix develop
direnv allow
```

建议：

- 固定 nixpkgs URL 和 `flake.lock`，不要在项目里使用会滚动的分支 URL。
- Python 用 `uv lock` + `uv sync --frozen`；Node 用
  `pnpm install --frozen-lockfile`。
- 不在 NixOS 层安装项目 Python/Node 包，也不执行 `pip install --user` 或
  `npm install -g`。
- `.envrc` 只写 `use flake`；不要放 token、密码或私有 registry 凭据。
- 旧项目迁移时先提交 lock 文件，再删除旧的全局 `node_modules`/虚拟环境，最后在
  devShell 中重装。

## 4. tmux：远程会话

`home/calendar/tmux.nix` 提供无插件的简单配置，随 Home Manager 安装：

- `base-index 1`、vi 模式、鼠标、focus events、24 小时时钟、10000 行历史。
- `set-clipboard on` 与 `allow-passthrough on`；外部终端支持 OSC 52 时，远程
  tmux 中的复制可以到本地剪贴板。
- `|` / `-` 在当前目录水平/垂直分屏，`c` 在当前目录新窗口。
- 不自动 `new-session`，不安装 resurrect/continuum 等插件，不写 statusline 主题。
- Home Manager 默认 `secureSocket = true`，socket 位于
  `$XDG_RUNTIME_DIR/tmux-<uid>/default`，仅用户所属组可访问。

常用操作：

```bash
tmux new -s work       # 新建/命名会话
tmux ls                # 列出会话
tmux attach -t work    # 重新连接
tmux kill-session -t work
```

tmux 会话能跨 SSH 断开存活，但不跨重启保存，也不会自动启动。SSH Agent 不会
因为使用 tmux 而自动转发；只在可信主机上按需使用 `ssh -A`，不要把私钥复制到
仓库或另一台机器。

## 5. 在 Arch 与 NixOS 之间共享

项目 flake 只在 `x86_64-linux` 上求值，两个系统都可以使用同一个
`flake.nix`/`flake.lock`：

```bash
# Arch（已安装 Nix + flakes）或 NixOS
nix develop
# 或
direnv allow
```

注意：

- 两边各自有 Nix store；`nix develop` 会按 lock 重新取/构建，不会把 NixOS 的
  系统库带进 Arch。
- 不要在 Arch 上把项目依赖 `pip install --user` 后再指望 NixOS 复用；用
  `uv.lock`/`pnpm-lock.yaml` 重建。
- Node 原生模块、Python C 扩展在两边都由各自 devShell 的库提供；不要跨系统
  复制 `node_modules` 或 `.venv`。
- 需要离线/弱网时，可先在有网机器执行 `nix flake archive` 或预热 store，再
  把闭包带到目标机；不要把整个 `/nix` 当普通文件同步。
- 共享的是声明和 lock，不是运行时状态；`.envrc` 只写 `use flake`。

## 6. 历史记录

- 2026-10-28 的临时 Python/Node 示例日志、GitHub/SSH 账号状态、Docker/Podman
  评估和当时的验证结论：
  [`history/development-notes.md`](history/development-notes.md)。
- main 的迁移与运行状态快照：
  [`history/main-workstation-2026-10-28.md`](history/main-workstation-2026-10-28.md)。
