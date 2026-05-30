default:
    @just --list

# === 构建与部署 ===
switch:
    sudo nixos-rebuild switch --flake .#nixos

boot:
    sudo nixos-rebuild boot --flake .#nixos

test:
    sudo nixos-rebuild test --flake .#nixos

# === 维护 ===
update:
    nix flake update
    just switch

check:
    nix flake check

clean:
    sudo nix-collect-garbage -d
    nix-collect-garbage -d

# === Secrets ===
edit-secrets:
    sops secrets/secrets.yaml

# === 格式化 ===
format:
    nixpkgs-fmt **/*.nix
