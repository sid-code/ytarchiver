{
  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";
  outputs = {
    self,
    nixpkgs,
    ...
  }: let
    supportedSystems = ["x86_64-linux"];
    forAllSystems = f:
      nixpkgs.lib.genAttrs supportedSystems (system:
        f system (import nixpkgs {inherit system;}));

    defaultIfNull = v: d:
      if v == null
      then d
      else v;
  in {
    packages = forAllSystems (
      system: pkgs: rec {
        ytarchiver = pkgs.writeShellApplication {
          name = "ytarchiver";
          text = ''
            channel="$1"
            savepath="$2"
            mkdir -p "$savepath"
            yt-dlp "https://www.youtube.com/$channel" \
              --download-archive "$savepath/archive" \
              -o "$savepath/"'%(title)s.%(ext)s'
          '';
          runtimeInputs = with pkgs; [yt-dlp];
        };
        default = ytarchiver;
      }
    );

    nixosModules.default = {
      config,
      lib,
      pkgs,
      ...
    }: let
      cfg = config.services.ytarchiver;
      inherit (lib) mkOption mkEnableOption mkIf types;
      inherit (lib.attrsets) mapAttrsToList mapAttrs';
    in {
      options = {
        services.ytarchiver = {
          enable = mkEnableOption "YouTube archiver";

          program = mkOption {
            default = self.packages.x86_64-linux.default;
            type = types.package;
          };

          archivePath = mkOption {
            type = types.str;
            description = "The path to the archive.";
          };
          group = mkOption {
            type = types.nullOr types.str;
            description = ''
              The optional group to whom the archive belongs, defaults to root.
            '';
            default = null;
          };

          channels = mkOption {
            type = types.attrsOf (types.submodule {
              options = {
                cronSpec = mkOption {
                  type = types.str;
                  description = ''
                    The cron spec that describes when the channel should be archived.
                  '';
                  example = "*-*-* 00:00";
                  default = "*-*-* 00:00";
                };
                outputDirName = mkOption {
                  type = types.nullOr types.str;
                  description = ''
                    An alternate name for the directory in which this channel's videos will be archived.
                  '';
                  default = null;
                };
              };
            });
            default = {};
          };
        };
      };
      config = mkIf cfg.enable {
        systemd.targets.ytarchiver-archive-initialized = {
          description = "Archive directory is initialized.";
          wants = ["ytarchiver-init-archive.service"];
        };
        systemd.timers =
          mapAttrs' (
            name: chcfg: {
              name = "ytarchiver-timer-${name}";
              value = {
                wantedBy = ["timers.target"];
                wants = ["ytarchiver-archive-initialized.target"];
                timerConfig = {
                  OnCalendar = chcfg.cronSpec;
                  Unit = "ytarchiver-archive-${name}.service";
                };
              };
            }
          )
          cfg.channels;
        systemd.services =
          {
            ytarchiver-init-archive = {
              after = ["multi-user.target"];
              serviceConfig = {
                Type = "oneshot";
                ExecStart = "${pkgs.writeShellApplication {
                  name = "init-archive";
                  text = ''
                    mkdir -p ${cfg.archivePath}

                    # SetGID to make sure everything inside belongs to the group.
                    chmod g+s ${cfg.archivePath}

                    ${
                      if cfg.group != null
                      then "chgrp ${cfg.group} ${cfg.archivePath}"
                      else ""
                    }
                  '';

                  runtimeInputs = with pkgs; [coreutils];
                }}/bin/init-archive";
              };
            };
          }
          // (mapAttrs' (name: chcfg: let
              downloadPath =
                cfg.archivePath
                + "/"
                + (defaultIfNull chcfg.outputDirName name);
            in {
              name = "ytarchiver-archive-${name}";
              value = {
                wants = ["network.target" "ytarchiver-archive-initialized.target"];
                serviceConfig = {
                  Type = "oneshot";
                  ExecStart = "${
                    pkgs.writeShellScript "launcher"
                    ''
                      ${cfg.program}/bin/ytarchiver "${name}" "${downloadPath}"
                    ''
                  }";
                };
              };
            })
            cfg.channels);
      };
    };
  };
}
