{
  description = "calendar's NixOS configurations";

  inputs = {
    # Pin an immutable nixpkgs commit from nixos-unstable. GitHub commit URLs
    # do not move, so the lock file stays reproducible and fetchable. This is
    # the nixos-unstable revision published on 2026-11-17:
    #   04906337b6d53e8bb0eaf0470ae9f070a4d4eb55
    #
    # To upgrade, change the commit below and run
    # `nix flake update nixpkgs`, then build and verify. Do not edit
    # flake.lock's narHash by hand or update unrelated inputs at the same time.
    nixpkgs.url = "github:NixOS/nixpkgs/04906337b6d53e8bb0eaf0470ae9f070a4d4eb55";

    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    lazyvim-nix = {
      url = "github:pfassina/lazyvim-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    flakida = {
      url = "github:LyCecilion/flakida-9.4/5e69153b0d60ac7932a2aec53739476c5b9c0db7";
    };

    burpPro = {
      url = "github:KIRAN-KUMAR-K3/BurpPro-Installer/7627e854d555889bc361b3ed81db48ca5ff49814";
    };

    pwndbg = {
      url = "github:pwndbg/pwndbg/9760ac8f1346d142857cffc933995cd6fca34dff";
    };

    # fcitx5 voice-input addon (local SenseVoice via sherpa-onnx, or cloud
    # ASR). Follows our nixpkgs so the addon links the same fcitx5 ABI as the
    # system fcitx5, like every other add-on in i18n.inputMethod.fcitx5.addons.
    fcitx5-vinput = {
      url = "github:fcitx5-vinput/fcitx5-vinput";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      nixpkgs,
      home-manager,
      sops-nix,
      lazyvim-nix,
      burpPro,
      flakida,
      pwndbg,
      fcitx5-vinput,
      ...
    }:
    let
      lib = nixpkgs.lib;

      mkHost =
        host: extraModules:
        lib.nixosSystem {
          system = "x86_64-linux";
          # main's extra module uses the flake-level voice-input package; the
          # mini host simply ignores the argument.
          specialArgs = { inherit fcitx5-vinput; };
          modules = [
            host
            sops-nix.nixosModules.sops
            home-manager.nixosModules.home-manager
          ] ++ extraModules;
        };

    in
    {
      nixosConfigurations = {
        # LazyVim and the security lab are main-only additions. The extra
        # module is appended after hosts/main, so the existing Home Manager
        # user configuration keeps applying and only imports the extra user
        # modules.
        main = mkHost ./hosts/main [
          (
            {
              pkgs,
              fcitx5-vinput,
              ...
            }:
            let
              vinput = fcitx5-vinput.packages.${pkgs.system}.default;
            in
            {
              # Voice input belongs to the fcitx5 process itself (global add-on
              # hotkeys), not to an input method, so there is no profile entry
              # and Rime keeps being DefaultIM.
              i18n.inputMethod.fcitx5.addons = [ vinput ];

              # vinput CLI + GUI for model management; the add-on alone puts
              # nothing on PATH. This also puts the package's D-Bus activation
              # file and user unit under /run/current-system/sw/share, which the
              # session bus and the user systemd instance already scan.
              environment.systemPackages = [ vinput ];

              # The add-on only speaks D-Bus; recording + ASR runs in this
              # separate user daemon. Declared here instead of relying on the
              # store-path unit so `systemctl --user enable` never records a
              # stale /nix/store path that a flake update would invalidate.
              systemd.user.services.vinput-daemon = {
                description = "Vinput voice input daemon";
                after = [ "pipewire.service" "wireplumber.service" ];
                serviceConfig = {
                  Type = "dbus";
                  BusName = "org.fcitx.Vinput";
                  ExecStart = "${vinput}/bin/vinput-daemon";
                };
                wantedBy = [ "default.target" ];
              };

              # Extra hardware triggers (gamepads, remotes, mouse buttons) come
              # from the package's udev rules. Keyboard triggers work already
              # through logind's uaccess on the active seat.
              services.udev.packages = [ vinput ];

              home-manager.extraSpecialArgs = {
                inherit burpPro flakida pwndbg;
              };

              home-manager.sharedModules = [
                lazyvim-nix.homeManagerModules.default
              ];

              home-manager.users.calendar.imports = [
                ./home/calendar/lazyvim.nix
                ./home/calendar/security-lab.nix
              ];
            }
          )
        ];

        nixos = mkHost ./hosts/nixos [ ];
      };
    };
}
