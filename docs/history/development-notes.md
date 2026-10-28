# 开发环境历史记录（2026-10-28）

> **历史观察，不代表当前运行状态。** 以下内容来自 2026-10-28 前后在 KOLOE
> 小主机（6 GiB 内存 / Ryzen 5 3500U）上的临时验证、账号/网络检查和容器评估。
> 路径、版本、登录状态和硬件条件此后都可能变化；可复用的开发方法见
> [`../DEVELOPMENT.md`](../DEVELOPMENT.md)，不要把本文当成当前环境说明。

## Python + uv 临时示例（原第 2 节）

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


## Node.js/TypeScript + pnpm 临时示例（原第 3 节）

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


## Git / SSH / GitHub 当时状态（原第 6 节）

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


## Docker 与 Podman 评估（原第 7 节）

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


## 小主机角色判断（原第 8 节）

- 6 GiB 内存适合作为 SSH 开发/构建节点、轻量容器宿主和日常桌面；不适合同时
  跑多个大型 JVM/数据库/容器，也不建议在本地跑完整 Kubernetes。
- Python/Node 工具链放在 devShell，避免系统升级时被项目依赖绑死；构建缓存由
  Nix store 和 uv/pnpm cache 分担。
- 目前没有启用 zram、自动 GC 仍由主机配置控制；不要为了腾空间删除最后一个
  可用 generation 或备份盘数据。
- 远程工作优先 SSH + tmux；需要图形时再登录 niri/Sway。main 的 niri 使用
  Waybar，小主机的 niri 使用 DMS；显示器管理仍是独立的桌面任务，不与开发环境
  耦合。


## 当时的验证记录与未完成项（原第 10 节）

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
