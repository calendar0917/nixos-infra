{ pkgs, ... }:

let
  # Keep the web UI on the version that was actually validated in this
  # migration. Do not silently follow `@latest` again.
  piWebVersion = "0.12.2";
in
{
  home.packages = [
    (pkgs.writeShellApplication {
      name = "pi-web-pinned";
      runtimeInputs = [ pkgs.nodejs_22 ];
      text = ''
        exec npx --yes @agegr/pi-web@${piWebVersion} "$@"
      '';
    })
  ];

  # Preserve the Arch Pi shell policy: no update check and no telemetry.
  home.sessionVariables = {
    PI_SKIP_VERSION_CHECK = "1";
    PI_TELEMETRY = "0";
    PI_WEB_SKIP_VERSION_CHECK = "1";
  };
}
