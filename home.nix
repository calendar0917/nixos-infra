programs.niri = {
  enable = true;
  settings = {
    prefer-no-csd = true;
    input.keyboard.xkb = {
      layout = "us";
      variant = "intl";
    };
    layout = {
      gaps = 4;
      focus-ring = {
        enable = true;
        width = 2;
        active.color = "#${config.colorScheme.palette.base0D}ff";
        inactive.color = "#${config.colorScheme.palette.base03}ff";
      };
    };
  };
};
