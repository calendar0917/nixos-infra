# nixos-infra

NixOS flake configuration for my laptop (AMD Ryzen, dual-boot with Arch Linux).

## Quick start

```bash
# Rebuild system
sudo nixos-rebuild switch --flake .#nixos

# Update all inputs to latest
nix flake update

# Test build (auto-rollback on reboot)
sudo nixos-rebuild test --flake .#nixos

# Rollback
sudo nixos-rebuild switch --rollback
```

## Structure

```
.
├── flake.nix              # Entry: inputs (nixpkgs, home-manager), output
├── flake.lock             # Pinned versions (committed)
├── clash.yaml             # mihomo proxy config
├── hosts/nixos/           # Machine-specific config
│   ├── configuration.nix  # Main system config
│   └── hardware-configuration.nix  # Partitions, kernel modules
├── modules/
│   ├── features/niri/     # niri compositor (default.nix + config.kdl + dms/)
│   ├── features/kitty/    # Kitty terminal config
│   ├── features/kanshi/   # Kanshi output config
│   └── fonts/             # Custom fonts (maple-mono NF CN)
└── home/
    └── calendar.nix       # Home Manager user config
```

## Key facts

- **Channel**: nixos-unstable (TUNA mirror)
- **Desktop**: niri + dms-shell (primary), KDE Plasma 6 (fallback)
- **Display manager**: SDDM
- **Input method**: fcitx5 + rime
- **Shell**: fish + zoxide
- **Editor**: neovim (default)
- **Key remap**: keyd (Caps -> Esc tap / Ctrl hold)
- **Proxy**: mihomo

## Reinstall

See [docs/REINSTALL.md](docs/REINSTALL.md).

## Learning resources

- [docs/NIX-GUIDE.md](docs/NIX-GUIDE.md) - NixOS from scratch
- [docs/POSTMORTEM.md](docs/POSTMORTEM.md) - Full migration log (Arch -> NixOS)
- [search.nixos.org/options](https://search.nixos.org/options) - All available options
- [search.nixos.org/packages](https://search.nixos.org/packages) - All available packages
- [nixos.wiki](https://nixos.wiki) - Community wiki
