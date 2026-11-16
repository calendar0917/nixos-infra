{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.my.securityLab;
in
{
  options.my.securityLab = {
    enable = lib.mkEnableOption "the optional security course lab";

    reverse.enable = lib.mkEnableOption "reverse engineering tools (IDA Pro)";
    pwn.enable = lib.mkEnableOption "binary exploitation tools";
    web.enable = lib.mkEnableOption "web security tools (Burp Suite Pro)";
    network.enable = lib.mkEnableOption "network analysis tools";
  };

  config = lib.mkIf cfg.enable {
    # Wireshark is a system package because its dumpcap wrapper needs
    # cap_net_raw/cap_net_admin. That wrapper is the only added network
    # capability; routing, firewall rules and global packet capture remain
    # unchanged. The group list is merged with the host's existing groups.
    programs.wireshark = lib.mkIf cfg.network.enable {
      enable = true;
      package = pkgs.wireshark;
      dumpcap.enable = true;
      usbmon.enable = false;
    };

    users.users.calendar.extraGroups = lib.mkIf cfg.network.enable [
      "wireshark"
    ];
  };
}
