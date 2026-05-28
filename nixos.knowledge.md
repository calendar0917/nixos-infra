# NixOS Knowledge — AI-assisted preferences

## Setup
- Mirror: TUNA (tsinghua.edu.cn)
- Channel: nixos-unstable
- Desktop: niri + dms-shell (primary), KDE Plasma 6 (fallback)
- DM: SDDM

## Configuration management
- **HM manages:** niri (config.kdl + dms/)
- **stow manages:** fish, kitty, kanshi, nvim (dotfiles/ directory)
- HM type: NixOS module (not standalone), with `home-manager.backupFileExtension = "hm-backup"`

## Proxy
- clash-verge-rev GUI (from nixpkgs), not mihomo service
- Clash config file is private — never commit to git

## Known issues
- GNOME 50 crashes → use KDE or niri
- 40G root partition is tight → auto-optimise-store + weekly GC enabled
- Cross-version (stable/unstable overlay) causes GPU/DRM failures — don't do it
- `wechat-uos` in nixpkgs broken (403 download) → use Flatpak
- Fish config has Arch-only sections guarded by `if not test -e /etc/NIXOS`

## User preferences
- No GNOME
- Flatpak for QQ, WeChat, wemeet
- stow for editable configs, HM for static ones
- Build only with `nix flake check` passed first
