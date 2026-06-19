{
  description = "NixOS configuration";
  inputs = {
    nixpkgs.url = "https://mirrors.tuna.tsinghua.edu.cn/nix-channels/nixos-unstable/nixexprs.tar.xz";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    llm-agents.url = "github:numtide/llm-agents.nix";
  };

  outputs = { nixpkgs, home-manager, sops-nix, llm-agents, ... } @ inputs: {
    nixosConfigurations.nixos = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      specialArgs = { inherit inputs; };
      modules = [
        ./overlays
        ./hosts/nixos/configuration.nix
        sops-nix.nixosModules.sops
        home-manager.nixosModules.home-manager
        {
          nixpkgs.overlays = [ llm-agents.overlays.default ];
        }
      ];
    };
  };
}
