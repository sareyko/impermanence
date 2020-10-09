{ pkgs, config, lib, ... }:

with lib;
let
  cfg = config.home.persistence;

  persistentStoragePaths = attrNames cfg;

  inherit (pkgs.callPackage ./lib.nix { }) splitPath dirListToPath concatPaths sanitizeName;
in
{
  options = {

    home.persistence = mkOption {
      default = { };
      type = with types; attrsOf (
        submodule {
          options =
            {
              directories = mkOption {
                type = with types; listOf str;
                default = [ ];
              };

              files = mkOption {
                type = with types; listOf str;
                default = [ ];
              };

              removePrefixDirectory = mkOption {
                type = types.bool;
                default = false;
              };
            };
        }
      );
    };

  };

  config = {
    home.file =
      let
        link = file:
          pkgs.runCommand
            "${sanitizeName file}"
            { }
            "ln -s '${file}' $out";

        mkLinkNameValuePair = persistentStoragePath: file: {
          name =
            if cfg.${persistentStoragePath}.removePrefixDirectory then
              dirListToPath (tail (splitPath [ file ]))
            else
              file;
          value = { source = link (concatPaths [ persistentStoragePath file ]); };
        };

        mkLinksToPersistentStorage = persistentStoragePath:
          listToAttrs (map
            (mkLinkNameValuePair persistentStoragePath)
            (cfg.${persistentStoragePath}.files)
          );
      in
      foldl' recursiveUpdate { } (map mkLinksToPersistentStorage persistentStoragePaths);

    systemd.user.services =
      let
        mkBindMountService = persistentStoragePath: dir:
          let
            mountDir =
              if cfg.${persistentStoragePath}.removePrefixDirectory then
                dirListToPath (tail (splitPath [ dir ]))
              else
                dir;
            targetDir = escapeShellArg (concatPaths [ persistentStoragePath dir ]);
            mountPoint = escapeShellArg (concatPaths [ config.home.homeDirectory mountDir ]);
            name = "bindMount-${sanitizeName targetDir}";
            startScript = pkgs.writeShellScript name ''
              set -eu
              if ! mount | grep -F ${mountPoint}' ' && ! mount | grep -F ${mountPoint}/; then
                  bindfs -f --no-allow-other ${targetDir} ${mountPoint}
              else
                  echo "There is already an active mount at or below ${mountPoint}!" >&2
                  exit 1
              fi
            '';
            stopScript = pkgs.writeShellScript "unmount-${name}" ''
              set -eu
              triesLeft=6
              while (( triesLeft > 0 )); do
                  if fusermount -u ${mountPoint}; then
                      exit 0
                  else
                      (( triesLeft-- ))
                      if (( triesLeft == 0 )); then
                          echo "Couldn't perform regular unmount of ${mountPoint}. Attempting lazy unmount."
                          fusermount -uz ${mountPoint}
                      else
                          sleep 5
                      fi
                  fi
              done
            '';
          in
          {
            inherit name;
            value = {
              Unit = {
                Description = "Bind mount ${targetDir} at ${mountPoint}";

                # Don't restart the unit, it could corrupt data and
                # crash programs currently reading from the mount.
                X-RestartIfChanged = false;
              };

              Install.WantedBy = [ "default.target" ];

              Service = {
                ExecStart = "${startScript}";
                ExecStop = "${stopScript}";
                Environment = "PATH=${makeBinPath (with pkgs; [ coreutils utillinux gnugrep bindfs ])}:/run/wrappers/bin";
              };
            };
          };

        mkBindMountServicesForPath = persistentStoragePath:
          listToAttrs (map
            (mkBindMountService persistentStoragePath)
            cfg.${persistentStoragePath}.directories
          );
      in
      builtins.foldl'
        recursiveUpdate
        { }
        (map mkBindMountServicesForPath persistentStoragePaths);

    home.activation =
      let
        dag = config.lib.dag;

        mkBindMount = persistentStoragePath: dir:
          let
            mountDir =
              if cfg.${persistentStoragePath}.removePrefixDirectory then
                dirListToPath (tail (splitPath [ dir ]))
              else
                dir;
            targetDir = escapeShellArg (concatPaths [ persistentStoragePath dir ]);
            mountPoint = escapeShellArg (concatPaths [ config.home.homeDirectory mountDir ]);
            mount = "${pkgs.utillinux}/bin/mount";
            bindfs = "${pkgs.bindfs}/bin/bindfs";
            systemctl = "XDG_RUNTIME_DIR=\${XDG_RUNTIME_DIR:-/run/user/$(id -u)} ${config.systemd.user.systemctlPath}";
          in
          ''
            if [[ ! -e ${targetDir} ]]; then
                mkdir -p ${targetDir}
            fi
            if [[ ! -e ${mountPoint} ]]; then
                mkdir -p ${mountPoint}
            fi
            if ${mount} | grep -F ${mountPoint}' ' >/dev/null; then
                if ! ${mount} | grep -F ${mountPoint}' ' | grep -F ${targetDir} >/dev/null; then
                    # The target directory changed, so we need to remount
                    echo "remounting ${mountPoint}"
                    ${systemctl} --user stop bindMount-${sanitizeName targetDir}
                    ${bindfs} --no-allow-other ${targetDir} ${mountPoint}
                    mountedPaths[${mountPoint}]=1
                fi
            elif ${mount} | grep -F ${mountPoint}/ >/dev/null; then
                echo "Something is mounted below ${mountPoint}, not creating bind mount to ${targetDir}" >&2
            else
                ${bindfs} --no-allow-other ${targetDir} ${mountPoint}
                mountedPaths[${mountPoint}]=1
            fi
          '';

        mkBindMountsForPath = persistentStoragePath:
          concatMapStrings
            (mkBindMount persistentStoragePath)
            cfg.${persistentStoragePath}.directories;

        mkUnmount = persistentStoragePath: dir:
          let
            mountDir =
              if cfg.${persistentStoragePath}.removePrefixDirectory then
                dirListToPath (tail (splitPath [ dir ]))
              else
                dir;
            mountPoint = escapeShellArg (concatPaths [ config.home.homeDirectory mountDir ]);
          in
          ''
            if [[ -n ''${mountedPaths[${mountPoint}]+x} ]]; then
                triesLeft=3
                while (( triesLeft > 0 )); do
                    if fusermount -u ${mountPoint}; then
                        break
                    else
                        (( triesLeft-- ))
                        if (( triesLeft == 0 )); then
                            echo "Couldn't perform regular unmount of ${mountPoint}. Attempting lazy unmount."
                            fusermount -uz ${mountPoint} || true
                        else
                            sleep 1
                        fi
                    fi
                done
            fi
          '';

        mkUnmountsForPath = persistentStoragePath:
          concatMapStrings
            (mkUnmount persistentStoragePath)
            cfg.${persistentStoragePath}.directories;

      in
      mkIf (any (path: cfg.${path}.directories != [ ]) persistentStoragePaths) {
        createAndMountPersistentStoragePaths =
          dag.entryBefore
            [ "writeBoundary" ]
            ''
              declare -A mountedPaths
              ${(concatMapStrings mkBindMountsForPath persistentStoragePaths)}
            '';

        unmountPersistentStoragePaths =
          dag.entryBefore
            [ "createAndMountPersistentStoragePaths" ]
            ''
              unmountBindMounts() {
              ${concatMapStrings mkUnmountsForPath persistentStoragePaths}
              }

              # Run the unmount function on error to clean up stray
              # bind mounts
              trap "unmountBindMounts" ERR
            '';

        runUnmountPersistentStoragePaths =
          dag.entryBefore
            [ "reloadSystemD" ]
            ''
              unmountBindMounts
            '';
      };
  };

}
