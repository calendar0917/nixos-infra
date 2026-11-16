{
  lib,
  osConfig,
  pkgs,
  burpPro,
  flakida,
  pwndbg,
  ...
}:

let
  cfg = osConfig.my.securityLab;
  system = pkgs.stdenv.hostPlatform.system;
in
{
  # This module is imported only by nixosConfigurations.main. Each package
  # group is gated by the top-level switch as well as its own switch, so a
  # disabled lab adds nothing even if a sub-switch is left enabled.
  home.packages =
    lib.optionals (cfg.enable && cfg.reverse.enable) [
      # flakida's default package provides the IDA Pro 9.4 GUI and desktop
      # entry. The upstream idat output supplies the text-mode command without
      # adding a second desktop entry.
      flakida.packages.${system}.default
      flakida.packages.${system}.idat
    ]
    ++ lib.optionals (cfg.enable && cfg.pwn.enable) [
      pkgs.gdb
      pwndbg.packages.${system}.pwndbg
      pkgs.python3Packages.pwntools
      pkgs.binutils
      pkgs.file
      pkgs.strace
      pkgs.ltrace
    ]
    ++ lib.optionals (cfg.enable && cfg.web.enable) [
      # Use only the third-party Burp Suite Pro package; do not add
      # pkgs.burpsuite as a second entry point.
      burpPro.packages.${system}.burpsuitepro
    ]
    ++ lib.optionals (cfg.enable && cfg.network.enable) [
      # The Wireshark GUI comes from programs.wireshark in the NixOS module.
      pkgs.nmap
      pkgs.tcpdump
    ];
}
