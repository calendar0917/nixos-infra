# 开发环境、远程会话与容器评估

本文记录这台 6 GiB / Ryzen 5 3500U 小主机上的开发环境分层、已经实际验证过的
Python/TypeScript 示例、tmux 和 SSH Agent 行为，以及 Docker/Podman 的评估结论。
这里的“验证通过”只表示在 NixOS 上实际执行过对应命令，不表示已经执行
`nixos-rebuild switch` 或完成图形界面验收。

## 1. 分层原则

| 层 | 负责 | 不负责 |
| --- | --- | --- |
| NixOS 系统（`modules/`、`hosts/`） | 用户、SSH、网络、桌面、音频、字体、容器/虚拟化等基础设施 | 具体项目的 Python/Node 版本 |
| Home Manager（`home/calendar/`） | Fish、Git、direnv、tmux、Helix、常用 CLI 和终端 | 项目依赖、全局 pip/npm 包 |
| 项目 devShell（项目自己的 `flake.nix`） | Python/Node/编译器/LSP CLI 等可执行文件 | 系统服务、全局配置 |
| 项目数据 | `.venv`、`node_modules`、`.direnv`、`.pnpm-store` | 不进入 Git，必要时可删除重建 |

这样做的结果是：换项目不会改变系统 Python/Node；删除项目的 `.venv` 或
`node_modules` 不会影响其他项目；升级 nixpkgs 或项目工具链可以分别进行。
`uv` 的下载缓存和 `pnpm` 的 store 不是系统包管理器，清理它们不会破坏 NixOS。

## 2. 已验证的 Python + uv 示例

临时目录为 `/tmp/dev-examples/python`。它使用固定 nixpkgs tarball，不依赖
GitHub HTTPS；flake 输入和仓库根目录保持同一版本：

```nix
{
  inputs.nixpkgs.url =
    "https://releases.nixos.org/nixos/unstable/nixos-26.11pre1097682.02c087f3fe67/nixexprs.tar.xz";

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

`pyproject.toml` 只声明项目元数据和一个 dev group；pytest 不装到系统：

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

实际执行并得到的结果：

```bash
cd /tmp/dev-examples/python
nix flake lock
nix develop --command bash -c '
  uv lock
  uv sync
  uv run pytest -q
'
# Python 3.13.16
# uv 0.13.1
# pytest 9.1.1
# 2 passed in 0.01s

nix develop --command bash -c '
  uv lock --check
  uv sync --frozen
  ruff check src tests
  ruff format --check src tests
'
# All checks passed!
# 2 files already formatted
```

- `.venv` 约 9.6 MiB；`uv` 缓存位于 `~/.cache/uv`，由多个项目共享。
- `uv lock --check` 与 `uv sync --frozen` 都能在已有 `.venv` 上复用，不必每次
  重建；删除 `.venv` 后仍可由 `uv.lock` 重建。
- `direnv` 也可以工作：

  ```bash
  direnv allow
  direnv exec . bash -c 'uv run pytest -q'
  ```

- 从项目目录退出后，`python`/`python3` 在系统 PATH 中仍然不存在；只有进入
  `nix develop` 或 direnv 环境才出现。没有执行任何 `pip install`。

## 3. 已验证的 Node.js/TypeScript + pnpm 示例

临时目录为 `/tmp/dev-examples/ts`。devShell 只提供 Node 22 和 pnpm 10：

```nix
{
  inputs.nixpkgs.url =
    "https://releases.nixos.org/nixos/unstable/nixos-26.11pre1097682.02c087f3fe67/nixexprs.tar.xz";

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

项目使用本地 `node_modules` 和项目内 pnpm store，避免把包写进用户级全局目录：

```ini
# ts/.npmrc
store-dir=.pnpm-store
```

`package.json` 使用 `tsc --noEmit` 做类型检查，`tsx` 直接运行 TypeScript：

```json
{
  "private": true,
  "type": "module",
  "packageManager": "pnpm@10.34.5",
  "scripts": {
    "check": "tsc --noEmit",
    "start": "tsx src/main.ts"
  },
  "devDependencies": {
    "@types/node": "^22.0.0",
    "tsx": "^4.0.0",
    "typescript": "^5.0.0"
  }
}
```

实际执行并得到的结果：

```bash
cd /tmp/dev-examples/ts
nix flake lock
nix develop --command bash -c '
  node --version       # v22.23.3
  pnpm --version       # 10.34.5
  pnpm install --frozen-lockfile
  pnpm run check       # tsc --noEmit
  pnpm start           # tsx src/main.ts
'
# Hello NixOS, sum=6

direnv allow
direnv exec . bash -c 'node --version; pnpm run check; pnpm start'
# 同一套版本，退出后 node/pnpm 不在系统 PATH
```

- `node_modules` 和 `.pnpm-store` 各约 38 MiB，但 store 与 `node_modules` 使用
  hardlink，磁盘占用不会简单相加；两者都由项目 `.gitignore` 排除。
- pnpm 会提示 `Ignored build scripts: esbuild@...`。当前 `tsx` 仍能正常运行；
  如果项目确实需要 postinstall（原生模块），先阅读该包的构建脚本，再用
  `pnpm approve-builds` 精确放行，不要全局关闭 pnpm 的脚本保护。
- `pnpm-lock.yaml`、`uv.lock`、`flake.lock` 都应提交；`node_modules`、
  `.venv`、`.direnv`、`.pnpm-store` 不提交。

## 4. 复现一个新项目

最小步骤：

```bash
mkdir my-project && cd my-project
# 创建 flake.nix（上面的模板之一）和 .envrc：
printf 'use flake\n' > .envrc

nix flake lock
nix develop
direnv allow
```

建议：

- 固定 nixpkgs URL 和 `flake.lock`，不要在项目里使用会滚动的 `nixos-unstable`
  分支 URL。
- Python 用 `uv lock` + `uv sync --frozen`；Node 用 `pnpm install --frozen-lockfile`。
- 不在 NixOS 层安装项目 Python/Node 包，也不执行 `pip install --user` 或
  `npm install -g`。
- `.envrc` 只写 `use flake`；不要放 token、密码或私有 registry 凭据。
- 旧项目迁移时先提交 lock 文件，再删除旧的全局 `node_modules`/虚拟环境，最后在
  devShell 中重装。

## 5. tmux：远程会话

`home/calendar/tmux.nix` 提供无插件的简单配置，随 Home Manager 安装：

- `base-index 1`、vi 模式、鼠标、focus events、24 小时时钟、10000 行历史。
- `set-clipboard on` 与 `allow-passthrough on`；外部终端支持 OSC 52 时，远程
  tmux 中的复制可以到本地剪贴板。
- `|` / `-` 在当前目录水平/垂直分屏，`c` 在当前目录新窗口。
- 不自动 `new-session`，不安装 resurrect/continuum 等插件，不写 statusline 主题。
- Home Manager 默认 `secureSocket = true`，socket 位于
  `$XDG_RUNTIME_DIR/tmux-<uid>/default`（本机为
  `/run/user/1000/tmux-1000/default`），仅用户所属组可访问。激活前该配置只存在于
  构建出的 `home-manager-files` 中，尚未写入 `~/.config/tmux/tmux.conf`。

实际验证：

```bash
# 激活后；本轮实际使用的是构建输出 home-manager-files 中的同一份 tmux.conf
tmux -L hmtest -f ~/.config/tmux/tmux.conf new-session -d -s smoke 'sleep 60'
tmux -L hmtest show-options -g default-terminal   # tmux-256color
tmux -L hmtest show-options -g base-index         # 1
tmux -L hmtest show-options -g set-clipboard      # on
tmux -L hmtest list-keys -T prefix | grep split-window
tmux -L hmtest kill-server
```

在 SSH 命令退出后重新连接，`tmux ls` 仍能看到 `hm-persist` 会话；socket 位于
`/run/user/1000/tmux-1000/default`。这验证的是“SSH 断开后仍存活”，**不是**
重启后仍存活：tmux 不跨重启保存，重启后需要重新启动。当前 `loginctl` 的
`Linger=no`、`KillUserProcesses=false`，本次测试不需要启用 linger；如果以后
系统策略改变或需要在完全注销后保留 socket，再单独评估
`loginctl enable-linger calendar`，不要默认打开。

常用操作：

```bash
tmux new -s work       # 新建/命名会话
tmux ls                # 列出会话
tmux attach -t work    # 重新连接
tmux kill-session -t work
```

SSH Agent 不会因为使用 tmux 而自动转发。需要在当前 SSH 连接中临时使用 Arch
上的 agent 时，显式 `ssh -A nixos`；只对可信主机这样做。不要把私钥复制到
NixOS，也不要把 `SSH_AUTH_SOCK` 写进仓库。

## 6. Git / SSH / GitHub 现状

- 当前 NixOS 主机的 `~/.ssh` 只有 `known_hosts` 和 gcr agent 目录，没有长期
  私钥或 SSH `config`；直接执行 `ssh -T git@github.com` 得到
  `Permission denied (publickey)`。这不影响用公钥登录 NixOS 本身。
- 从 Arch 发起 `ssh -A nixos` 并在 Arch 上运行 `ssh-agent` 时，NixOS 侧可以
  通过转发的 agent 完成 GitHub SSH 认证和 clone（`ssh -T` 返回
  `Hi calendar0917!`）。Arch 侧 agent 环境只放在本地临时文件
  （如 `/tmp/arch-agent.env`），不要提交；不要复制 Arch 私钥到 NixOS。
- 直接 HTTPS Git 在这台机器/当前代理链路上不可靠：smart-HTTP 会建立 TCP 后
  停滞，或经 `127.0.0.1:7897` 报 TLS EOF。GitHub SSH（默认 22；必要时可用
  `ssh.github.com:443`）已经通过转发的 agent 验证可克隆。
- `gh` 已安装但未登录；需要时在 NixOS 上运行 `gh auth login`，不要把 token
  写进 shell 配置或仓库。
- Clash Verge 的 HTTP/SOCKS 代理是应用级配置，不是系统全局代理；本次没有改
  TUN、DNS、路由或防火墙。修好节点/规则后再初始化依赖 GitHub HTTPS 的工具。

## 7. Docker 与 Podman：只评估，不安装

当前主机没有安装 Docker、Podman、docker-compose 或 podman-compose；本轮没有
启用任何容器服务。已核对的运行条件：

- 内存 5.7 GiB，8 线程，swap 8.8 GiB；cgroup v2；无虚拟化嵌套需求。
- `/etc/subuid`、`/etc/subgid` 已有 `calendar:100000:65536`，可支持 rootless
  Podman；`user.max_user_namespaces = 23312`。
- Flatpak 1.18.4 已启用，但 Flatpak 不是容器运行时，不能替代 Docker/Podman。

| 维度 | Docker | Podman |
| --- | --- | --- |
| 架构 | 守护进程 `dockerd`，客户端通过 socket 访问 | 无守护进程，直接 fork/exec；可选 socket |
| rootless | 需要额外配置 rootless Docker | 原生 rootless，适合单用户小主机 |
| Compose | Docker Compose 生态最完整 | `podman compose`/`podman-compose`，兼容性取决于版本 |
| 资源占用 | 常驻 daemon，空闲也有内存/CPU 开销 | 无常驻 daemon，空闲开销更低 |
| NixOS 集成 | `virtualisation.docker.enable` | `virtualisation.podman.enable`，可加 docker 兼容 socket |
| 本机建议 | 只有在必须使用 Docker 专属工具链时 | **首选**，尤其是 rootless + 少量服务 |

如果以后启用，优先按以下顺序做小规模试点：

1. 先只启用 Podman rootless，不启用 Docker 兼容 socket；确认 `podman run
   --rm hello-world` 和用户命名空间正常。
2. 迁移 compose 时逐项检查：镜像、环境变量、端口、bind mount、named volume、
   `depends_on`、healthcheck、`network_mode`。不要把整个 compose 文件和数据目录
   一次性搬过来。
3. rootless 绑定 80/443 需要额外的端口转发或
   `net.ipv4.ip_unprivileged_port_start` 调整；先在高端口验证，再决定是否改系统
   参数。
4. bind mount 的用户/组 ID 在 rootless 下会映射到 subuid；需要时使用 `:U`
   或明确 `--userns=keep-id`，不要盲目 `chown -R` 宿主机目录。
5. 需要开机自启时用 systemd user unit/Quadlet，而不是在登录 shell 里
   `podman run`；先手动运行并确认日志、重启策略和数据卷。
6. volume 迁移先 `docker volume inspect`/备份，再在 Podman 中创建同名 volume；
   没有实际数据前不要删除旧 volume。

NixOS 配置草案（**未应用**，仅作评审）：

```nix
virtualisation.podman = {
  enable = true;
  # dockerCompat 会提供 docker socket；只有确实需要 Docker CLI 时再打开。
  # dockerCompat = true;
};
```

## 8. 这台机器的角色

- 6 GiB 内存适合作为 SSH 开发/构建节点、轻量容器宿主和日常桌面；不适合同时
  跑多个大型 JVM/数据库/容器，也不建议在本地跑完整 Kubernetes。
- Python/Node 工具链放在 devShell，避免系统升级时被项目依赖绑死；构建缓存由
  Nix store 和 uv/pnpm cache 分担。
- 目前没有启用 zram、自动 GC 仍由主机配置控制；不要为了腾空间删除最后一个
  可用 generation 或备份盘数据。
- 远程工作优先 SSH + tmux；需要图形时再登录 niri/Sway。main 的 niri 使用
  Waybar，小主机的 niri 使用 DMS；显示器管理仍是独立的桌面任务，不与开发环境
  耦合。

## 9. 在 Arch 与 NixOS 之间共享

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

## 10. 验证记录与未完成项

本轮已执行：

```bash
# 仓库检查与构建（只 build，不 switch/test/boot）
nix flake check --show-trace
# all checks passed!

nixos-rebuild build --flake .#nixos
# => /nix/store/dandv7nl9s53w42wxshak6jbvp867d10-nixos-system-nixos-26.11.20261020.dirty

# Python
uv lock; uv sync; uv run pytest -q          # 2 passed
uv lock --check; uv sync --frozen
ruff check src tests; ruff format --check   # passed

# TypeScript
pnpm install --frozen-lockfile
pnpm run check                              # tsc --noEmit
pnpm start                                  # Hello NixOS, sum=6

# tmux
# 配置解析、选项、窗口索引、分屏绑定和 SSH 断开后会话存活均已验证
```

尚未完成/需要单独授权：

- `nixos-rebuild switch`（本轮禁止）；当前运行系统仍是旧的 test generation，
  重启会回到更旧的 boot generation；tmux/Helix 的新配置尚未激活。
- 编辑器已从 Neovim 切换为 Helix。`hx --version`、`hx --health` 以及
  nil/nixfmt、pyright、bash-language-server、JSON/YAML server 的入口已离线验证；
  图形终端中的实际补全/诊断仍需实机确认。旧 Neovim 运行时目录没有被删除，但不再
  作为默认编辑器或由仓库提供 LazyVim 配置。
- GitHub HTTPS 的代理节点/规则问题未修复；GitHub SSH 只能通过 Arch agent
  转发使用，主机本身没有长期密钥。`gh` 尚未登录。
- Docker/Podman 未安装、未启用；上面的配置只是评估草案。
