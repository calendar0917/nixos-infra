# NixOS 重装流程（零数据丢失）

## 前提

`/home` 在独立 btrfs 子卷 `@home`（nvme0n1p8），重装时**不格式化**。
`.` 配置仓库在 `/home/calendar/code/nixos/`，重装后原样可用。

## 步骤

### 1. ISO 启动 + 分区

```bash
# 这次给 / 分 80G（之前 40G 不够）
sudo cfdisk /dev/nvme0n1
# → 删 nvme0n1p9 → New → 80G → Write
sudo mkfs.ext4 /dev/nvme0n1p9
```

### 2. 挂载（不格式化 /home）

```bash
sudo mount /dev/nvme0n1p9 /mnt
sudo mkdir -p /mnt/boot
sudo mount /dev/nvme0n1p6 /mnt/boot     # 共用 EFI
sudo mkdir -p /mnt/home
sudo mount -o subvol=@home /dev/nvme0n1p8 /mnt/home  # 关键：subvol
sudo swapon /dev/nvme0n1p7
```

### 3. 代理 + 安装

```bash
# 终端1: 启代理
./mihomo -d .

# 终端2:
export https_proxy=http://127.0.0.1:7890 http_proxy=http://127.0.0.1:7890
sudo -E calamares
```

安装器里：用户名 `calendar`，桌面先不选，引导用 systemd-boot。

### 4. 首次启动后，直接重建

```bash
# /home 还在，代码仓库原样存在
cd ~/code/nixos
git pull  # 如果推到了 GitHub

# 构建（需要代理拉 home-manager）
sudo env https_proxy=http://127.0.0.1:7890 http_proxy=http://127.0.0.1:7890 \
  nixos-rebuild switch --flake ~/code/nixos#nixos

sudo reboot
```

### 5. 装 Flatpak 软件

```bash
flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
flatpak install flathub com.qq.QQ
flatpak install flathub com.tencent.WeChat
flatpak install flathub com.tencent.wemeet
```

**完毕。** 系统、桌面、配置、数据全部恢复。
