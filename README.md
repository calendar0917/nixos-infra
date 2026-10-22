# nixos-infra

`calendar` 的单机 NixOS 配置：一个 flake、NixOS 原生模块、NixOS 集成 Home
Manager，nixpkgs 固定在一个不可变的 `nixos-unstable` channel tarball 上
（rev `02c087f3fe673c9e317f206a627cb6b910336dbe`，channel 版本
`pre1097682.02c087f3fe67`）。日常主力是 niri + DankMaterialShell（DMS），Sway 是
不依赖 DMS 的备用桌面，Plasma 6 可选。

## 设计目标

- 保持单一 `flake.nix` / `flake.lock`，不引入额外配置框架。
- 可复现：nixpkgs 指向带版本号的不可变 tarball，而不是 URL 不变、内容会变的滚动
  channel；`flake.lock` 的 `narHash` 必须与 URL 内容一致。
- 系统、桌面、Shell、Neovim 和 MIME 默认值由 Nix 声明；应用自己的订阅、历史、
  书签和运行状态由应用管理，不强行改成只读文件。
- 安全默认：防火墙开启，订阅/Token/私钥不进 Nix store 或 Git，备份只手动执行。
- 依赖尽量少：Nautilus 负责图形文件操作，Yazi 负责终端键盘工作流，Clash Verge
  Rev 是唯一的代理实现。

## 目录结构

```text
flake.nix / flake.lock              # 唯一入口和锁定版本
hosts/nixos/
  default.nix                       # 主机名、用户、桌面/网络/备份开关
  hardware-configuration.nix        # 安装前必须按目标机重新核对
modules/
  base.nix                          # boot、Nix/GC、locale、keyd、基础工具
  network.nix                       # NetworkManager、resolved、Tailscale、Clash Verge
  secrets.nix                       # sops-nix age key 路径
  backup.nix                        # 手动 USB Restic + 启动前设备/UUID 校验
  desktop/common.nix                # SDDM、PipeWire、Fcitx5、字体、portal、Nautilus
  desktop/niri.nix                  # niri + DMS（DMS 绑定 niri.service）
  desktop/sway.nix                  # 独立 Sway 备用桌面
  desktop/plasma.nix                # 可选 Plasma 6
home/calendar/                      # Home Manager：Fish、Yazi、Neovim、桌面软链
config/niri/config.kdl              # niri 快捷键的唯一权威来源
config/sway/                        # Sway、Waybar、Mako、Fuzzel
config/nvim/                        # LazyVim 文本配置 + lazy-lock.json 基线
secrets/secrets.yaml                # SOPS 密文；明文永不进 Git
docs/RECOVERY.md                    # 安装前核对、恢复、网络、Secrets、备份
```

## 修改桌面与功能开关

编辑 `hosts/nixos/default.nix`：

```nix
my.desktop.niri.enable = true;     # 主力桌面
my.desktop.sway.enable = true;     # 备用桌面
my.desktop.plasma.enable = false;  # 可选 Plasma 6

my.network.clashVerge.enable = true;
my.network.clashVerge.tunInterface = "Meta"; # TUN 实际接口名，见下文

my.backup.enable = false;          # 填入真实 USB UUID 后才改为 true
my.backup.usbUuid = null;
```

三个桌面开关互相独立；启用的会话都会出现在 SDDM 中，登录时切换桌面不需要重建，
增删会话才需要重建。niri 的快捷键以 `config/niri/config.kdl` 为准，Sway 的快捷键
以 `config/sway/config` 为准。`Mod+E` 在两个桌面中都是打开 Nautilus。

## 常用构建、更新和回滚命令

在仓库根目录执行：

```bash
nix flake show
nix flake check --show-trace
nix eval --raw '.#nixosConfigurations.nixos.config.system.build.toplevel.drvPath'
nix build '.#nixosConfigurations.nixos.config.system.build.toplevel'

# 只构建，不激活；第一次切换前必须先核对 hardware-configuration.nix
sudo nixos-rebuild build --flake .#nixos
sudo nixos-rebuild switch --flake .#nixos

# 只写入下一次启动项，不立即切换
sudo nixos-rebuild boot --flake .#nixos
```

更新锁定输入并部署：

nixpkgs 的 URL 是一个**固定版本**的 channel tarball，因此 `nix flake update`
不会自动跟随 upstream。升级 nixpkgs 的完整流程：

```bash
# 1. 选一个新的 nixos-unstable channel 版本，例如：
#    https://releases.nixos.org/nixos/unstable/nixos-<next-version>/nixexprs.tar.xz
# 2. 同时修改 flake.nix 的 URL 和 flake.lock 中 nixpkgs 节点的 url
# 3. 重新计算锁文件（下载新 tarball 并写入 narHash）
nix flake lock --update-input nixpkgs
nix flake check --show-trace
sudo nixos-rebuild build --flake .#nixos
sudo nixos-rebuild switch --flake .#nixos
```

不要只改 URL 不更新 `narHash`，也不要只改 `narHash` 不核对 URL。只更新
home-manager / sops-nix 时，用 `nix flake lock --update-input home-manager` 等，
不要顺带升级 nixpkgs。

回滚：

```bash
sudo nixos-rebuild switch --rollback          # 回到上一个 generation
sudo nixos-rebuild boot --rollback             # 让下一次启动使用上一代
nix-env -p /nix/var/nix/profiles/system --list-generations
sudo reboot                                  # 或在 systemd-boot 菜单选择旧 generation
```

GC：`--delete-older-than 30d` **会删除超过 30 天的 profile generation**，不只是
store 路径；被删的 generation 不能再回滚。首次部署阶段
`hosts/nixos/default.nix` 用 `nix.gc.automatic = lib.mkForce false` 暂停自动 GC。
确认系统成功重启并且至少有一个可回滚的旧 generation 后，再删除该覆盖；也可以手动
执行：

```bash
sudo nix-collect-garbage --delete-older-than 30d
```

不要为了节省空间删除最后一个已知可用的 generation；systemd-boot 菜单里的旧条目
以 `boot.loader.systemd-boot.configurationLimit` 和实际保留的 generation 为准。

## 远程登录（OpenSSH）

OpenSSH 和用户公钥都由 `hosts/nixos/default.nix` 声明，不依赖 `/etc/ssh` 的临时
修改：

- 服务端启用，端口 22，`PermitRootLogin = "no"`，只允许 `calendar` 登录，
  `KbdInteractiveAuthentication = false`。
- 公钥写入 `users.users.calendar.openssh.authorizedKeys.keys`，部署后出现在
  `/etc/ssh/authorized_keys.d/calendar`。公钥不是秘密；私钥永远不入库。
- `PasswordAuthentication` 仍是 NixOS 默认值（开启）。确认密钥登录可用后才可以
  显式关闭；修改前保留一个已登录的 SSH 会话，避免把自己锁在外面。
- 修改 SSH 设置后先 `nixos-rebuild build`，再用新会话验证
  `ssh -o PreferredAuthentications=publickey nixos`。

当前主目录 `~/.ssh` 还是空的，所以 `git@github.com`、`gh auth login` 和 LazyVim
首次插件安装都还没有可用的 GitHub 凭证/主机密钥。这属于首次使用时要手动完成的
步骤：在 NixOS 上生成新密钥、把公钥加到 GitHub，不要把 Arch 上的私钥复制过来。

## 桌面与常用软件

### SDDM

SDDM 使用 X11 greeter（`services.displayManager.sddm.wayland.enable = false`）。
这是这台机器上修复鼠标/输入问题后的稳定配置；登录后的 niri 和 Sway 仍然是
Wayland 会话。默认会话是 niri，Sway 可以在 SDDM 里选择。

### Nautilus

- `Mod+E` 打开 Nautilus（niri 和 Sway 相同；Sway 的 `Mod+E` 是新增绑定）。
- Nautilus 由 `pkgs.nautilus` 提供，不安装完整 GNOME 桌面。
- `inode/directory` 的默认应用是 `org.gnome.Nautilus.desktop`，由 Home Manager
  的 `xdg.mimeApps` 声明。
- `services.gvfs`、`services.udisks2`、GNOME Keyring 和桌面 portal 已启用；
  回收站、挂载 U 盘和文件选择器走正常的 GVfs/udisks2 路径。首次使用 U 盘时在
  Nautilus 侧栏挂载即可，不需要 root。

### Yazi

在 Fish 中直接运行：

```bash
y            # 当前目录
y ~/code     # 指定目录
```

Home Manager 的 `programs.yazi` 提供 Fish 集成和 `y` 函数；退出 Yazi 后 Fish 会
切换到 Yazi 最后选中的目录。没有额外的 Fish wrapper。预览依赖只有
`fd`、`ripgrep`、`fzf`、`file`、`ffmpegthumbnailer`、`poppler-utils` 和
`imagemagick`，没有插件/主题集合。Nautilus 仍是图形默认文件管理器。

### Clash Verge Rev

- 启动方式：应用菜单中的 Clash Verge，或在终端运行 `clash-verge`；启用自动启动时
  由 XDG autostart 启动，niri 和 Sway 都可用。Clash Verge 自身有单实例检查。
- DMS 和 Waybar 都提供托盘；通知使用当前会话的通知服务（niri 下是 DMS，Sway 下
  是 Mako），Clash 不需要额外的 notification daemon。
- Service Mode、TUN 和必要的系统权限由 NixOS 的 `programs.clash-verge` 模块提供
  （`serviceMode = true`、`tunMode = true`）。不要在 GUI 里再执行“安装服务”脚本。
- 订阅、节点、策略和规则全部在 GUI 中导入/管理，本仓库不保存订阅 URL、Token 或
  节点凭据。GUI 的用户数据目录是
  `~/.local/share/io.github.clash-verge-rev.clash-verge-rev/`。
- TUN 接口默认叫 `Meta`；如果 GUI/配置改成别的名字，必须同步修改
  `my.network.clashVerge.tunInterface` 并重建。详细排障见
  [`docs/RECOVERY.md`](docs/RECOVERY.md)。
- Tailscale 保持 `--accept-dns=false --accept-routes=false`，`systemd-resolved`
  继续监听 `127.0.0.53`。不要把 Tailscale 的 `HTTP_PROXY` 指向 Clash。

## 声明式管理与应用状态

| 内容 | 管理方式 |
| --- | --- |
| flake 输入、NixOS/HM 模块、用户和服务 | Nix 声明式 |
| niri KDL、Sway/Waybar/Mako/Fuzzel 配置 | 仓库文件，经 Home Manager 软链 |
| Fish、Starship、zoxide、direnv、Neovim 配置 | Home Manager 声明式 |
| Neovim 插件和 `~/.local/state/nvim/lazy-lock.json` | lazy.nvim 管理；仓库只提供首次安装的锁文件基线 |
| Nautilus 书签、最近文件、回收站 | Nautilus/GVfs 管理 |
| Yazi 历史、状态 | Yazi 管理 |
| Fcitx5 配置、词库 | Fcitx5 管理（`~/.config/fcitx5`、`~/.local/share/fcitx5`） |
| Clash Verge 订阅、节点、规则、运行状态 | Clash Verge Rev GUI 管理 |
| Restic 仓库和快照 | USB 上的 Restic 仓库；手动备份 |

## 安装与恢复

首次安装前必须核对磁盘、UUID、ESP 和 Windows 双系统条件；TTY 恢复、网络/Tailscale/
Clash 排障、age/SOPS 密钥恢复、Restic 实际恢复演练和重装步骤统一放在
[`docs/RECOVERY.md`](docs/RECOVERY.md)。

本仓库不会执行 `nixos-rebuild switch`、`nixos-install`、分区、格式化或 EFI 修改。
`secrets/secrets.yaml` 里的旧 `mihomo-config` 密文会保留，未经确认不删除；其中可能
仍有需要手动迁移到 Clash Verge 的订阅信息。
