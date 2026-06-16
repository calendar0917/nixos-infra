{ self, inputs, ... }: {

  flake.nixosConfigurations.myMachine = inputs.nixpkgs.lib.nixosSystem {
    modules = [
      self.nixosModules.myMachineModule
    ];
  };

  flake.nixosModules.myMachineModule = { pkgs, ... }: {
    environment.systemPackages = [
      self.packages.${pkgs.system}.default
    ];
  };

}
