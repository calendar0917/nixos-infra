# NixOS Knowledge — AI-assisted preferences

## Setup
- Mirror: TUNA (tsinghua.edu.cn)
- Channel: nixos-unstable
- Desktop: niri + dms-shell (primary), KDE Plasma 6 (fallback)
- DM: SDDM

## Configuration management
- **HM manages all dotfiles** — niri, DMS, fish, kitty, kanshi, nvim
- **`mkOutOfStoreSymlink`** — 所有配置都是直接 symlink 到 repo 里的源文件，改了即时生效，不用 rebuild
- HM type: NixOS module (not standalone), with `home-manager.backupFileExtension = "hm-backup"`

## Proxy
- mihomo 系统服务 + TUN 模式（systemd 服务）
- Web UI: metacubexd (http://127.0.0.1:9090/ui)
- Clash config: managed by sops-nix, stored encrypted at secrets/secrets.yaml
  - Decrypted by sops-nix at runtime, key path: `config.sops.secrets."mihomo-config".path`
  - Edit with: `just edit-secrets`
- GeoIP 数据库需手动下载到 /var/lib/private/mihomo/

## Secrets
- sops-nix with age encryption
- Key files:
  - `~/.config/sops/age/keys.txt` — age 私钥（sops CLI 和 sops-nix 都用这个）
  - `~/.ssh/id_ed25519` — SSH 私钥（可以转换为 age key，作为备份参考）
  - **必须备份这两个文件**，丢失 = 所有加密的 secrets 无法恢复
- Edit secrets: `just edit-secrets`
- Encrypted file: `secrets/secrets.yaml`

## Known issues
- GNOME 50 crashes → use KDE or niri
- 40G root partition is tight → auto-optimise-store + weekly GC enabled
- Cross-version (stable/unstable overlay) causes GPU/DRM failures — don't do it
- `wechat-uos` in nixpkgs broken (403 download) → use Flatpak
- Fish config has Arch-only sections guarded by `if not test -e /etc/NIXOS`

## Pitfalls
- Nix sandbox 不继承代理环境变量，crates.io 下载会 403 → 预编译二进制更可靠
- mihomo 启动时下载 GeoIP 会失败（代理还没启动）→ 先禁用 GEOIP 规则，再手动补充
- HM 需要 `extraSpecialArgs` 才能接收 overlay 中的自定义包
- HM 中引用自定义包时，overlay 必须放在 HM 模块之前

## User preferences
- No GNOME
- Flatpak for QQ, WeChat, wemeet
- stow for editable configs, HM for static ones
- Build only with `nix flake check` passed first
- Laptop lid close action: ignore (no action)
