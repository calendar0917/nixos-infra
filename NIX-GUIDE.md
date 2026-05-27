# NixOS 学习指南

## 一、Nix 是什么？

**核心理念：声明式 + 可复现。**

你不需要手动 `apt install xxx`，而是在一个配置文件里**声明**"我要什么"，NixOS 自动算出具体的安装步骤。

类比：
- Arch: `sudo pacman -S git`（命令式，你告诉电脑怎么做）
- NixOS: `environment.systemPackages = [ pkgs.git ];`（声明式，你告诉电脑你要什么）

## 二、Nix 语言速览（5 分钟）

Nix 语言就是用来写配置的。只讲你用到的语法：

```nix
# 注释用 #
# 字符串
"hello"
# 多行字符串
''
  line1
  line2
''
# 布尔值
true    false
# 列表（空格分隔）
[ "a" "b" "c" ]
# 属性集（花括号，分号分隔）
{
  name = "calendar";
  age = 25;
}
# 访问属性
pkgs.git          # pkgs 的属性 git
pkgs.xfce.thunar  # 嵌套访问
# with 语句（把属性集的字段展开到当前作用域）
with pkgs; [ git vim wget ]  # 等价于 [ pkgs.git pkgs.vim pkgs.wget ]
# let ... in（定义局部变量）
let
  foo = "hello";
in
{ greeting = foo; }
# 函数
{ config, pkgs, ... }:       # 参数（模式匹配）
{                            # 函数体
  environment.systemPackages = with pkgs; [ git ];
}
# import（导入文件）
imports = [ ./hardware-configuration.nix ];
```

## 三、NixOS 是怎么工作的

```
你的配置（.nix 文件）
    ↓ nixos-rebuild 读取
nixpkgs（官方包仓库，几千个包的配方）
    ↓ 计算依赖关系
/nix/store/ 里的二进制文件
    ↓ 激活
系统生效
```

**关键概念：** 每次 `nixos-rebuild switch` 都会创建一个"世代"(generation)。崩了可以随时回滚：重启时在 boot 菜单选上一代即可。

## 四、你的项目结构（逐文件解释）

```
code/nixos/
├── flake.nix               # 入口：声明输入源 + 输出系统
├── flake.lock              # 自动生成：锁定输入源的版本
├── clash.yaml              # mihomo 代理配置
├── hosts/
│   └── nixos/
│       ├── default.nix     # 自动导入同目录模块
│       ├── configuration.nix  # 主配置（你改得最多的地方）
│       └── hardware-configuration.nix  # 分区、内核模块（通常不改）
└── modules/
    ├── features/
    │   └── niri/
    │       ├── default.nix    # niri 相关配置
    │       └── config.kdl     # niri 原生键位配置
    └── fonts/
        └── default.nix    # 字体配置
```

### 4.1 `flake.nix`

```nix
{
  inputs = {
    # 从哪里下载 nixpkgs（官方包仓库）
    nixpkgs.url = "https://mirrors.tuna.../nixos-unstable/nixexprs.tar.xz";
  };
  outputs = { nixpkgs, ... } @ inputs: {
    # 定义一台名为 nixos 的电脑的配置
    nixosConfigurations.nixos = nixpkgs.lib.nixosSystem {
      modules = [ ./hosts/nixos ];  # 导入 hosts/nixos 下的所有 .nix 文件
    };
  };
}
```

- `inputs`：数据来源。这里只有 nixpkgs，从清华 TUNA 镜像拉取 unstable 版本
- `outputs`：输出。`nixosConfigurations.nixos` 就是你的系统
- `nixpkgs.lib.nixosSystem`：用 nixpkgs 构建一个 NixOS 系统

### 4.2 `hosts/nixos/default.nix`

```nix
{ imports = [ ./configuration.nix ]; }
```

就是把同目录的 `configuration.nix` 纳入模块列表。如果以后要拆分配置，在这加就行。

### 4.3 `hosts/nixos/hardware-configuration.nix`

**这个文件通常不动。** 它是 `nixos-generate-config` 自动扫描硬件生成的：

- 分区信息（`fileSystems."/"`、`fileSystems."/home"`
- 内核模块（`boot.initrd.availableKernelModules`）
- CPU 微码（`hardware.cpu.amd.updateMicrocode`）

我帮你加了 Windows 盘挂载和 swap。

### 4.4 `hosts/nixos/configuration.nix`（核心文件）

这是你日常改得最多的文件。按区块讲解：

```nix
{ config, lib, pkgs, inputs, ... }:   # ← 函数参数，模块系统传入

{
  imports = [                           # ← 导入其他模块
    ./hardware-configuration.nix
    ../../modules/features/niri         # 导入 niri 模块（自动找 default.nix）
    ../../modules/fonts                 # 导入字体模块
  ];

  # -- 每个选项的格式：service.组件.子组件.开关 = 值 --
  boot.loader.systemd-boot.enable = true;   # 用 systemd-boot 引导
  networking.hostName = "nixos";             # 主机名
  networking.networkmanager.enable = true;  # 启用 NetworkManager

  services.mihomo.enable = true;             # 启用代理
  services.tailscale.enable = true;          # 启用 tailscale

  time.timeZone = "Asia/Shanghai";          # 时区
  i18n.defaultLocale = "zh_CN.UTF-8";       # 语言

  i18n.inputMethod = {                      # 输入法
    enable = true;
    type = "fcitx5";
    fcitx5.addons = with pkgs; [ fcitx5-rime ];
  };

  # 桌面环境
  services.xserver.enable = true;
  services.displayManager.sddm.enable = true;    # 登录管理器 SDDM
  services.desktopManager.plasma6.enable = true; # KDE Plasma 6
  programs.niri.enable = true;                    # niri 窗口管理器
  programs.dms-shell = { enable = true; ... };   # dms 桌面 shell

  services.keyd.enable = true;               # 键盘映射（Caps→Esc/Ctrl）

  programs.fish.enable = true;               # fish shell
  programs.zoxide.enable = true;             # zoxide 快速跳转
  programs.neovim = { enable = true; defaultEditor = true; };

  virtualisation.docker.enable = true;       # Docker
  virtualisation.virtualbox.host.enable = true;

  # 用户
  users.users.calendar = {
    isNormalUser = true;
    shell = pkgs.fish;
    extraGroups = [ "networkmanager" "wheel" "docker" "video" "render" ];
  };

  # 安装的软件包
  environment.systemPackages = with pkgs; [
    git vim wget curl htop btop ...
    cmake clang gdb gh go nodejs python3 ...
  ];

  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  system.stateVersion = "25.05";  # 首次安装的版本，不要改
}
```

**关键理解：** 每个顶层 key（`boot`、`networking`、`services`、`programs`、`users`、`environment` 等）都是 NixOS 的"选项"。全部选项可查：https://search.nixos.org/options

### 4.5 `modules/features/niri/default.nix`

这是一个"特性模块"——把与 niri 相关的所有配置集中在一个文件：

```nix
{ config, lib, pkgs, ... }:
{
  environment.etc."niri/config.kdl".source = ./config.kdl;  # 安装 KDL 配置到 /etc/niri/

  systemd.user.services.niri.environment = { ... };  # 设置环境变量

  environment.systemPackages = with pkgs; [ ... ];   # 安装 niri 周边工具

  systemd.user.services.kanshi = { ... };   # kanshi 显示器管理自启动
  systemd.user.services.polkit-gnome-authentication-agent-1 = { ... };  # polkit 认证
}
```

## 五、日常操作速查

```bash
# 改完配置后应用
sudo nixos-rebuild switch --flake ~/code/nixos#nixos

# 只测试不保存（重启后还原）
sudo nixos-rebuild test --flake ~/code/nixos#nixos

# 查看所有世代
sudo nixos-rebuild list-generations

# 回滚到上一代
sudo nixos-rebuild switch --rollback

# 搜索包
nix search nixpkgs 包名

# 临时试用一个包（不安装）
nix shell nixpkgs#包名

# 清理旧世代和垃圾
sudo nix-collect-garbage -d
```

## 六、如何添加一个新包

1. 把包名加到 `environment.systemPackages` 里
2. 如果包不存在，查 https://search.nixos.org/packages
3. 如果是 unfree 包，确保 `nixpkgs.config.allowUnfree = true;`
4. `sudo nixos-rebuild switch`

## 七、如何启用一个新服务

```nix
# 很多常见服务有现成的模块，比如：
services.openssh.enable = true;     # SSH
services.tailscale.enable = true;   # Tailscale
services.postgresql.enable = true;  # PostgreSQL
programs.fish.enable = true;        # fish shell

# 查全部可用服务：https://search.nixos.org/options
```

## 八、调试技巧

```bash
# 查看上次启动的系统日志
journalctl -b -p3              # 只看错误

# 查看某个服务的日志
journalctl -u niri

# 查看用户服务
systemctl --user status dms

# 查看当前系统使用的 nixpkgs 版本
nixos-version

# 查看某个选项的当前值
nixos-option services.xserver.desktopManager

# 查看磁盘空间
nix-store --gc --print-roots   # 当前活跃的 store 路径
df -h /nix/store               # store 占用
```

## 九、如果系统崩了怎么办

1. 重启，在 systemd-boot 菜单选旧世代
2. 登入后修复配置
3. `sudo nixos-rebuild switch` 重新构建

**你的数据在 `/home`（独立 btrfs 子卷），重装都不会丢。**

## 十、进阶：看懂你配置里的关键模式

### `with pkgs; [ ... ]`
```nix
environment.systemPackages = with pkgs; [ git vim ];
# 等价于
environment.systemPackages = [ pkgs.git pkgs.vim ];
```

### `lib.mkDefault` vs 直接赋值
```nix
services.gnome.gnome-keyring.enable = true;         # 强制
services.gnome.gnome-keyring.enable = lib.mkDefault true;  # 默认值，可被覆盖
```

### 模块导入顺序
越靠后的模块优先级越高。同名选项，后面的覆盖前面的。

### `environment.etc` 写配置文件
```nix
environment.etc."niri/config.kdl".source = ./config.kdl;
# 把 ./config.kdl 的内容安装到 /etc/niri/config.kdl
```

### `systemd.user.services` 自动启动
```nix
systemd.user.services.kanshi = {
  wantedBy = [ "graphical-session.target" ];  # 图形会话启动时自动启动
  serviceConfig.ExecStart = "${pkgs.kanshi}/bin/kanshi";
};
```

## 十一、下一步可以学什么

1. **Home Manager**：管理用户级配置（dotfiles、GTK 主题、浏览器插件）
2. **Overlay / Override**：覆盖/修改已有包的构建参数
3. **自定义 derivation**：自己打包不在 nixpkgs 里的软件
4. **多机器共享配置**：同一套 flake 管多台电脑

---

# 进阶篇

## 十二、NixOS 模块系统深层理解

### 12.1 你写的配置到底经历了什么

```
你写的 .nix 文件
    ↓ 模块系统合并（lib.evalModules）
一个巨大的 "config" 属性集
    ↓ nixpkgs 构建系统
/nix/store 里的二进制 + 配置文件 + systemd unit + ...
    ↓ switch-to-configuration
重启对应服务 / 更新符号链接 / 写入 /etc
```

**模块合并规则：**
- 同名**列表**选项 → 合并（后面的追加到前面）
- 同名**属性集**选项 → 递归合并
- 同名**标量**选项 → 后定义的覆盖先定义的（高优先级覆盖低）
- `lib.mkDefault` 标记的值优先级最低
- `lib.mkForce` 标记的值优先级最高

### 12.2 怎么找到所有可用选项

**方法一：search.nixos.org**

打开 https://search.nixos.org/options ，搜索关键词即可。切换 unstable/stable 频道看差异。

**方法二：nixos-option**

```bash
# 查看某个选项的文档和当前值
nixos-option services.xserver.desktopManager

# 查看某个选项的所有可能子选项
nixos-option services.openssh
```

**方法三：直接读 nixpkgs 源码**

所有模块都在 nixpkgs 仓库里：https://github.com/NixOS/nixpkgs/tree/nixos-unstable/nixos/modules

- `services/` → 各类服务的模块
- `programs/` → 桌面软件的模块
- `system/boot/` → 引导相关
- `security/` → 安全策略

**方法四：用 nix repl 探索**

```bash
nix repl --file '<nixpkgs/nixos>'
# 然后：
nixos-config = ./hosts/nixos/configuration.nix
# 可以 tab 补全看有哪些选项
```

### 12.3 模块的 import 和参数传递

```nix
# flake.nix 中
modules = [ ./hosts/nixos ];

# 自动等价于：
modules = [
  (import ./hosts/nixos/default.nix)
  (import ./hosts/nixos/configuration.nix)
  (import ./hosts/nixos/hardware-configuration.nix)
  (import ./modules/features/niri/default.nix)
];

# 每个模块都是一个函数，接收这些参数：
{ config, lib, pkgs, options, modulesPath, ... }:
```

**关键理解：**
- `config`：整个系统最终的配置结果（所有模块合并后）
- `options`：所有可用选项的元数据
- `pkgs`：nixpkgs 包集合（和你在 flake.nix 里选的 nixpkgs 是同一个）
- `lib`：nixpkgs 工具函数库

## 十三、NixOS 没有提供模块时怎么办

这是从"会用"到"会搞"的关键分水岭。

### 13.1 情况一：只需要一个 systemd 服务

你不需要等 NixOS 有人写模块。直接用 `systemd.services`：

```nix
systemd.services.my-service = {
  description = "My custom service";
  wantedBy = [ "multi-user.target" ];
  serviceConfig = {
    ExecStart = "${pkgs.some-package}/bin/some-daemon";
    Restart = "on-failure";
  };
};
```

我们配置里的 kanshi 就是这样做的（`modules/features/niri/default.nix:36-44`）：

```nix
systemd.user.services.kanshi = {
  wantedBy = [ "graphical-session.target" ];
  serviceConfig.ExecStart = "${pkgs.kanshi}/bin/kanshi";
};
```

`systemd.services.xxx` 和 `systemd.user.services.xxx` 分别对应系统级和用户级服务。

### 13.2 情况二：需要写配置文件到 /etc

```nix
environment.etc."应用名/config.conf".text = ''
  [Section]
  key = value
'';

# 或者从文件复制
environment.etc."应用名/config.conf".source = ./my-config.conf;
```

我们的 niri KDL 配置就是用这个（`modules/features/niri/default.nix:5`）。

### 13.3 情况三：需要创建目录或临时文件

```nix
systemd.tmpfiles.rules = [
  "d /var/lib/myapp 0755 myuser mygroup"
  "f /etc/myapp.conf 0644 root root - config content here"
];
```

### 13.4 情况四：需要添加 udev 规则

```nix
services.udev.extraRules = ''
  SUBSYSTEM=="usb", ATTR{idVendor}=="1234", MODE="0666"
'';
```

### 13.5 情况五：需要编译不在 nixpkgs 里的软件

这就是我们写 maple-mono 字体的方式（`modules/fonts/default.nix`）：

```nix
let
  my-package = pkgs.stdenv.mkDerivation {
    pname = "...";
    version = "...";
    src = pkgs.fetchurl { url = "..."; hash = "..."; };

    # 不需要编译的话用 stdenvNoCC
    # 构建命令
    buildPhase = "make";
    installPhase = "mkdir -p $out/bin && cp mybin $out/bin/";
  };
in
{
  environment.systemPackages = [ my-package ];
}
```

### 13.6 情况六：需要修改已有包的构建参数（override）

```nix
environment.systemPackages = [
  (pkgs.kitty.override {  # 用不同选项重新编译 kitty
    withWayland = true;
  })
];
```

### 13.7 情况七：用 overlay 全局替换包

```nix
nixpkgs.overlays = [
  (final: prev: {
    # 把系统里的 vim 替换成 neovim
    vim = prev.neovim;
  })
];
```

## 十四、如何阅读 nixpkgs 源码

以你关心的包为例：

### 14.1 找一个包的源码

```bash
# 方法1：从 search.nixos.org 点进去
# 方法2：在 nixpkgs GitHub 仓库里搜索文件名
# 方法3：用 nix edit（需要先配好编辑器）
nix edit nixpkgs#kitty
```

### 14.2 看懂一个 derivation

以 kitty 为例，打开 `pkgs/applications/terminal-emulators/kitty/default.nix`：

```nix
{ stdenv, lib, fetchFromGitHub, ... }:

stdenv.mkDerivation rec {
  pname = "kitty";
  version = "0.40.1";

  src = fetchFromGitHub { ... };   # 源码从哪下载

  buildInputs = [ ... ];           # 编译依赖

  meta = {
    description = "...";
    homepage = "...";
    license = lib.licenses.gpl3;
  };
}
```

- `src`：从哪下载源码
- `buildInputs` / `nativeBuildInputs`：编译时需要什么
- `meta`：元信息

### 14.3 看懂一个 NixOS 模块

以我们用的 dms-shell 为例，打开 `nixos/modules/programs/wayland/dms-shell.nix`：

```nix
{ config, lib, pkgs, ... }:
let
  cfg = config.programs.dms-shell;  # 引用用户配置
in
{
  options.programs.dms-shell = {    # 声明有哪些可配的选项
    enable = mkEnableOption "...";
    package = mkPackageOption pkgs "dms-shell" { };
    systemd.enable = mkOption { ... };
  };

  config = mkIf cfg.enable {        # 如果启用，做什么
    systemd.packages = [ cfg.package ];
    systemd.user.services.dms = { ... };
    environment.systemPackages = [ cfg.package ... ];
  };
}
```

**模式：** `options` 声明"用户可以配什么"，`config` 声明"配了之后系统干什么"。

## 十五、nixos-rebuild 的完整生命周期

```bash
sudo nixos-rebuild switch --flake ~/code/nixos#nixos
```

1. **Evaluation**：读取你的 .nix 文件，算出整个系统配置
2. **Build**：按配置在 /nix/store 里构建所有需要的文件
3. **Activation**：把新文件链接到系统：
   - 写入 `/etc/` 配置文件
   - 创建 systemd unit 文件
   - 重启变化了的服务
   - 更新 `/run/current-system` → 指向新世代

**switch vs boot vs test：**
| 命令 | 效果 |
|------|------|
| `switch` | 构建 + 立即生效 |
| `boot` | 构建 + 下次重启生效（当前不受影响） |
| `test` | 构建 + 立即生效 + **重启后自动回滚** |

## 十六、Flake 的深入理解

### 16.1 inputs 和 follows

```nix
inputs = {
  nixpkgs.url = "...";
  nixpkgs-unstable.url = "...";
  # 如果有其他 flake，可以用 follows 共享 nixpkgs：
  some-flake = {
    url = "github:...";
    inputs.nixpkgs.follows = "nixpkgs";  # 用我们的 nixpkgs，不要另下一份
  };
};
```

- 不加 `follows` → 每个 flake 各自下载一份 nixpkgs
- 加了 `follows` → 共用同一份，节省空间和时间

### 16.2 flake.lock

这是自动生成的文件，锁定所有 input 的精确版本。类似 `package-lock.json`。**应该提交到 git**，保证其他人（或未来的你）重建出来的系统完全一致。

```bash
nix flake update           # 更新所有 input 到最新版本
nix flake lock --update-input nixpkgs  # 只更新 nixpkgs
```

### 16.3 flake check

```bash
nix flake check   # 验证配置是否有语法/类型错误（不实际构建）
```

我们每次改配置后都会跑这个。如果 `flake check` 报错，说明有选项名写错了或包不存在，不需要等到 `nixos-rebuild` 才知道。

## 十七、常见坑和经验

### 为什么包名有时是 `pkgs.thunar` 有时是 `pkgs.xfce.thunar`

nixpkgs 有时会把一个项目的包放在子命名空间下。在 unstable 里 thunar 被移到了顶层（`pkgs.thunar`），但在旧版本里是 `pkgs.xfce.thunar`。**查 search.nixos.org 最准。**

### unfree 包

```nix
nixpkgs.config.allowUnfree = true;
# 高级用法：只允许特定 unfree 包
nixpkgs.config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) [
  "steam"
  "vscode"
];
```

### 代理和镜像

国内用清华 TUNA 镜像：
```nix
# 1. nixpkgs 源码（flake input）
nixpkgs.url = "https://mirrors.tuna.tsinghua.edu.cn/nix-channels/nixos-unstable/nixexprs.tar.xz";

# 2. 二进制缓存
nix.settings.substituters = [ "https://mirrors.tuna.tsinghua.edu.cn/nix-channels/store" ... ];
```

### 磁盘空间

/nix/store 会累积很多历史版本。定期清理：
```bash
sudo nix-collect-garbage -d        # 删所有未引用的 store 路径
sudo nix-collect-garbage --delete-older-than 7d  # 删 7 天前的
```

## 十八、你能看懂自己的配置了吗？（自测）

现在再打开你的 `configuration.nix`：

1. `boot.loader.systemd-boot.enable` → 选项路径 `boot.loader.systemd-boot.enable`，值 `true`
2. `environment.systemPackages = with pkgs; [ git vim ... ]` → with 展开，等价于 `[ pkgs.git pkgs.vim ... ]`
3. `services.keyd.keyboards.default.settings.main.capslock = "overload(control, esc)"` → 深层嵌套选项
4. `programs.dms-shell.systemd.enable = true` → 启用 dms-shell 模块的 systemd 子选项
5. `systemd.user.services.kanshi = { ... }` → 自定义 systemd 用户服务（因为没有现成的 kanshi 模块）
6. `imports = [ ./hardware-configuration.nix ../../modules/features/niri ]` → 导入其他模块文件

如果都能解释清楚——你已经掌握了 NixOS 的核心逻辑。

---

# 高级篇

## 十九、NixOS 到底管什么（边界模型）

```
┌─────────────────────────────────────────────┐
│  /home/calendar/    ← 你的数据              │
│  ├── Documents/     ← NixOS 不碰            │
│  ├── .config/       ← 你手动管（或用 HM）    │
│  ├── .ssh/          ← 直接通用              │
│  └── .mozilla/      ← 直接通用              │
├─────────────────────────────────────────────┤
│  /etc/              ← NixOS 管（只读）       │
│  /run/current-system/sw/  ← NixOS 管        │
│  /nix/store/        ← NixOS 管（不可变）     │
└─────────────────────────────────────────────┘
```

**关键理解：** `/etc/` 在 NixOS 上是**只读的**（软链接到 /nix/store）。不能手动编辑 `/etc/niri/config.kdl`——改了下次 rebuild 就覆盖。正确做法是改源码 `.nix` 文件或源 `.kdl` 文件，然后 rebuild。

**那 ~/.config 和 /etc 冲突了怎么办？** 以 niri 为例，可以在模块里禁用系统级配置，只让用户自己管：

```nix
# 不装到 /etc，让用户自己在 ~/.config/niri/ 管
# environment.etc."niri/config.kdl".source = ./config.kdl;  # 注释掉这行
```

这样 niri 会用 `~/.config/niri/config.kdl`，你可以随时手动改，不受 rebuild 影响。

## 二十、配置优先级链

```
用户 ~/.config/  (最高优先，手动改)
    ↓ 覆盖
系统 /etc/       (NixOS 管，rebuild 时覆盖)
    ↓ 覆盖
程序默认值       (最低优先)
```

**实际案例：** 你的 niri 配置通过 `environment.etc` 写到 `/etc/niri/config.kdl`。但如果你在 `~/.config/niri/config.kdl` 放一个文件，niri 会忽略 `/etc/` 的版本。这是 POSIX XDG 规范的标准行为。

## 二十一、为什么 Arch 数据在 NixOS 里有时"不见了"

`/home` 是同一个 btrfs 子卷，文件都在。但软件版本差异导致数据格式不兼容：

| 软件 | Arch 版本 | NixOS 版本 | 数据兼容？ |
|------|----------|-----------|-----------|
| GNOME dconf | 48 | 50 | ❌ GNOME 50 崩溃 |
| Firefox | ~148 | ~150 | ✅ |
| Git | 2.54 | 2.54 | ✅ |
| SSH | same | same | ✅ |
| fish | 4.7 | 4.7 | ✅ |
| fcitx5 | 5.1 | 5.1 | ✅ |
| kitty | 0.46 | 0.46 | ✅ |

**规则：** 跨大版本（GNOME 48→50）配置大概率不兼容。小版本增量或纯文本配置（git、ssh、nvim）直接通用。

---

# Home Manager 篇

## 二十二、Home Manager 是什么

Home Manager（HM）是 NixOS 的"用户级扩展"。NixOS 管 `/etc` 和系统包，HM 管 `~/.config` 和用户级包。

```
NixOS：  系统级    /etc/  systemd  内核  驱动  系统包
HM：     用户级    ~/.config/  systemd --user  用户包  dotfiles
```

**什么时候用 HM：**
- 管理 dotfiles（kitty.conf、fish config、nvim 插件、GTK 主题）
- 安装只有当前用户需要的包（不和系统混一起）
- 管理 systemd 用户服务（现在我们手动写的 kanshi、polkit 这些可以迁移进去）
- 多机器共享用户配置

## 二十三、给现有 flake 加 Home Manager

### 1. flake.nix 加 input：

```nix
{
  inputs = {
    nixpkgs.url = "https://mirrors.tuna.tsinghua.edu.cn/nix-channels/nixos-unstable/nixexprs.tar.xz";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";  # 共用 nixpkgs
    };
  };

  outputs = { nixpkgs, home-manager, ... }@inputs: {
    nixosConfigurations.nixos = nixpkgs.lib.nixosSystem {
      modules = [
        ./hosts/nixos
        home-manager.nixosModules.home-manager  # ← 加这一行
      ];
    };
  };
}
```

### 2. 创建 user config：

```nix
# home/calendar.nix
{ config, pkgs, ... }:
{
  home.username = "calendar";
  home.homeDirectory = "/home/calendar";

  # 不用 source，用 program.xxx 管理 dotfiles
  programs.kitty = {
    enable = true;
    settings = {
      font_family = "Maple Mono NF CN";
      font_size = 12;
    };
  };

  # 或者直接写文件
  home.file.".config/niri/config.kdl".source = ../modules/features/niri/config.kdl;

  # 用户级包（不影响系统）
  home.packages = with pkgs; [ yazi zoxide ];

  # 用户级 systemd 服务
  systemd.user.services.my-service = {
    Unit.Description = "...";
    Service.ExecStart = "${pkgs.xxx}/bin/xxx";
    Install.WantedBy = [ "graphical-session.target" ];
  };

  home.stateVersion = "25.05";
}
```

### 3. 在 configuration.nix 引用：

```nix
home-manager.users.calendar = import ../../home/calendar.nix;
```

### 4. HM 的 niri KDL 管理（替代 environment.etc）

```nix
# 在 home/calendar.nix 里
xdg.configFile."niri/config.kdl".source = ../../modules/features/niri/config.kdl;
```

这会把 KDL 写到 `~/.config/niri/config.kdl`，而不是 `/etc/niri/config.kdl`。好处：可以手动临时改，HM rebuild 时覆盖。

## 二十四、Home Manager 的工作流

```bash
# 改完 home/calendar.nix 后
home-manager switch --flake ~/code/nixos#calendar

# 或者和系统一起 rebuild
sudo nixos-rebuild switch --flake ~/code/nixos#nixos
```

`nixos-rebuild switch` 会自动触发 `home-manager` 的切换。

---

# 多机器篇

## 二十五、多机器共享配置

### 目录结构：

```
code/nixos/
├── flake.nix
├── hosts/
│   ├── laptop/           # 笔记本
│   │   ├── default.nix
│   │   ├── configuration.nix
│   │   └── hardware-configuration.nix
│   └── desktop/          # 台式机
│       ├── default.nix
│       ├── configuration.nix
│       └── hardware-configuration.nix
├── modules/
│   ├── common/           # 两台机器都用的
│   │   ├── packages.nix  # 通用软件包
│   │   └── fonts.nix
│   └── features/
│       └── niri/         # 主力机用
└── home/
    └── calendar.nix      # 用户配置（两台都可用）
```

### flake.nix（多机器版）：

```nix
{
  outputs = { nixpkgs, ... }@inputs: {
    nixosConfigurations = {
      laptop = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          ./modules/common        # 共享模块
          ./hosts/laptop          # 笔记本特有
          home-manager.nixosModules.home-manager
        ];
      };
      desktop = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          ./modules/common        # 共享模块（同一套）
          ./hosts/desktop         # 台式机特有
          home-manager.nixosModules.home-manager
        ];
      };
    };
  };
}
```

### 共享模块示例：

```nix
# modules/common/packages.nix
{ pkgs, ... }:
{
  environment.systemPackages = with pkgs; [
    git vim wget curl htop btop ripgrep fd jq
    # 两台机器都装的
  ];
}
```

### 机器特有配置：

```nix
# hosts/laptop/configuration.nix
{ ... }:
{
  imports = [ ../../modules/features/niri ];  # 笔记本有 niri
  services.tailscale.enable = true;           # 笔记本需要
}

# hosts/desktop/configuration.nix
{ ... }:
{
  # 台式机不需要 niri，可能用 GNOME
  services.xserver.desktopManager.gnome.enable = true;
}
```

### 构建命令：

```bash
sudo nixos-rebuild switch --flake ~/code/nixos#laptop
sudo nixos-rebuild switch --flake ~/code/nixos#desktop
```

---

# Nix 开发环境实战

## 二十六、核心理念

```
每个项目 = 一个声明式环境
                ↓
     flake.nix 里写：我要 go 1.26, nodejs 24, postgresql 18
                ↓
     nix develop 进入隔离环境
                ↓
     退出 shell → 环境消失，系统零污染
```

## 二十七、最简单用法（不掉进 flake）

不需要写 flake。一行命令临时进环境：

```bash
# Go 项目
nix shell nixpkgs#go nixpkgs#gopls

# Python 项目
nix shell nixpkgs#python3 nixpkgs#uv

# 多工具
nix shell nixpkgs#nodejs_22 nixpkgs#go nixpkgs#postgresql
```

exit 就退出，工具就没了。适合临时用一下。

## 二十八、标准用法：项目自带 flake.nix

在项目根目录创建 `flake.nix`：

```nix
# flake.nix
{
  description = "My project dev environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { nixpkgs, ... }: let
    system = "x86_64-linux";
    pkgs = nixpkgs.legacyPackages.${system};
  in {
    devShells.${system}.default = pkgs.mkShell {
      packages = with pkgs; [
        go
        gopls          # LSP
        gotools        # goimports, etc.
        nodejs_22
        python3
        uv
        postgresql_18
      ];

      shellHook = ''
        echo "✅ 开发环境就绪"
        export GOPATH=$PWD/.go
        export PATH=$GOPATH/bin:$PATH
      '';
    };
  };
}
```

然后每次进项目：

```bash
nix develop        # 进入环境
go build           # 直接用
exit               # 退出
```

## 二十九、direnv：自动激活，零感知

写一个 `.envrc`，`cd` 进去就自动激活：

```bash
# .envrc（放项目根目录）
use flake
```

安装 direnv：

```bash
# 全局装（你已经在系统配置里，可以加）
environment.systemPackages = with pkgs; [ direnv ];

# 然后 hook 进 shell（fish）
# 或者用 home-manager：
programs.direnv = {
  enable = true;
  nix-direnv.enable = true;
};
```

效果：`cd myproject/` → 自动进入 nix 环境，`cd ..` → 自动退出。完全无感。

## 三十、语言工具的共存

```
Nix 装： python3, go, nodejs, cargo 本体
        ↓（只读，/nix/store）
你装：   pip install, npm install, cargo install
        ↓（写 /home，正常读写）
结果：   项目依赖在项目目录，语言工具由 Nix 提供
```

`uv pip install`、`npm install`、`go mod download` 照常用，装的包在项目目录或 `~/.local/`，Nix 不管。

## 三十一、你的项目模板

把下面这个 `flake.nix` 放到任何项目根目录：

```nix
{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  outputs = { nixpkgs, ... }: let
    pkgs = nixpkgs.legacyPackages.x86_64-linux;
  in {
    devShells.x86_64-linux.default = pkgs.mkShell {
      # 按需增减
      packages = with pkgs; [
        git vim ripgrep fd jq    # 通用工具
        go nodejs python3        # 语言
        gopls                    # LSP
      ];
    };
  };
}
```

然后 `nix develop` 或配 `.envrc` + `direnv allow`。
