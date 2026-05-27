hardware.graphics = {
  enable = true;
  enable32Bit = true;
};
 
virtualisation.docker.enable = true;
users.users.calendar.extraGroups = [ "docker" ];
 
security.rtkit.enable = true;
services.pipewire = {
  enable = true;
  alsa.enable = true;
  alsa.support32Bit = true;
  pulse.enable = true;
};

services.mihomo = {
    enable = true;
    configFile = ./clash.yaml;
  };
 
xdg.portal = {
  enable = true;
  xdgOpenUsePortal = true;
  config.common.default = "*";
  extraPortals = [ pkgs.xdg-desktop-portal-gtk ];
};
