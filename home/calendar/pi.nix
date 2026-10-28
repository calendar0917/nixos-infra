{ pkgs, ... }:

let
  # Keep the web UI on the version that was actually validated in this
  # migration. Do not silently follow `@latest` again. This is a pinned npx
  # entry point, not a fully packaged offline application: npx may still fetch
  # the package from the npm registry on first use.
  piWebVersion = "0.12.2";
in
{
  home.packages = [
    (pkgs.writeShellApplication {
      name = "pi-web-pinned";
      runtimeInputs = [ pkgs.nodejs_22 ];
      text = ''
        # Preserve the Arch Pi shell policy for this wrapper only: no update
        # check and no telemetry. Arguments are passed through unchanged.
        export PI_SKIP_VERSION_CHECK=1
        export PI_TELEMETRY=0
        export PI_WEB_SKIP_VERSION_CHECK=1

        exec npx --yes @agegr/pi-web@${piWebVersion} "$@"
      '';
    })
  ];
}
