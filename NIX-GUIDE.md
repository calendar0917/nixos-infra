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
