{ pkgs, ... }:

{
  # The main machine shares the existing 1 GiB ESP with Arch. Do not write
  # EFI NVRAM: the existing "Linux Boot Manager" entry already points at
  # /EFI/systemd/systemd-bootx64.efi on this ESP. nixos-install updates the
  # files on the ESP, but the firmware boot order stays under Arch control.
  boot.loader.efi.canTouchEfiVariables = false;

  # Three generations keep the ESP comfortably below its free space budget.
  # Do not enable NixOS UKIs or boot counting for the first deployment.
  boot.loader.systemd-boot = {
    enable = true;
    configurationLimit = 3;
  };
  boot.loader.timeout = 5;

  # The NixOS builder rewrites loader.conf on every install/rebuild and writes
  # `default nixos-*` (or `preferred ...`). Without this hook NixOS becomes the
  # default entry. The hook only edits the `default`/`preferred` lines of
  # loader.conf: it never creates, renames or deletes a boot entry, and it never
  # touches EFI/Linux or loader/entries. Arch's UKI stays the default entry.
  #
  # Caveat: this also overrides a deliberate manual `default` change made later
  # in the systemd-boot menu. If you ever want NixOS as the default, remove this
  # extraInstallCommands block first, then set the default; otherwise the next
  # rebuild will switch it back to Arch.
  #
  # arch-linux-lts.efi is the entry id reported by `bootctl list` for the
  # auto-discovered Type #2 UKI at /boot/EFI/Linux/arch-linux-lts.efi. If Arch
  # ever renames the UKI, update this hook and re-check `bootctl list`.
  boot.loader.systemd-boot.extraInstallCommands = ''
    uki=/boot/EFI/Linux/arch-linux-lts.efi
    conf=/boot/loader/loader.conf
    if [ -f "$uki" ] && [ -f "$conf" ]; then
      # Drop only the default/preferred lines; keep timeout, console-mode,
      # editor and anything else systemd-boot or the admin put there.
      ${pkgs.gnused}/bin/sed -i -e '/^default[[:space:]]/d' -e '/^preferred[[:space:]]/d' "$conf"
      printf 'default arch-linux-lts.efi\n' >> "$conf"
      # Fail loudly rather than silently booting NixOS: exactly one default line
      # and it must name the Arch UKI.
      if [ "$(grep -c '^default[[:space:]]' "$conf")" -ne 1 ]; then
        echo "error: $conf does not have exactly one default line" >&2
        exit 1
      fi
      grep -qx 'default arch-linux-lts.efi' "$conf" || {
        echo "error: failed to set Arch as the default boot entry" >&2
        exit 1
      }
      ${pkgs.coreutils}/bin/sync
      echo "loader.conf: Arch UKI is the default entry"
    else
      # Fail instead of silently leaving NixOS as the default. A missing Arch
      # UKI means Arch may not boot at all, so stop here and let the operator
      # inspect /boot before rebooting. Disable this block only after deciding
      # that Arch no longer needs to stay the default entry.
      echo "ERROR: Arch UKI or loader.conf missing under /boot." >&2
      echo "ERROR: refusing to leave NixOS as the default boot entry." >&2
      echo "ERROR: inspect /boot/EFI/Linux and /boot/loader, restore from the" >&2
      echo "ERROR: ESP backup, then re-run the bootloader step." >&2
      exit 1
    fi
  '';
}
