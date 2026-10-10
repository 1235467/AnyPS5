{
  description = "AnyPS5 development shells";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      stripRPath = ''
        export NIX_DONT_SET_RPATH=1

        read -r -a __ldflags <<< "''${NIX_LDFLAGS:-}"
        __kept=()
        __skip=0
        __pending=0
        for __flag in "''${__ldflags[@]}"; do
          if [ "$__skip" = 1 ]; then
            __skip=0
            continue
          fi
          if [ "$__flag" = "-rpath" ]; then
            __skip=1
            continue
          fi
          if [ "$__pending" = 1 ]; then
            __pending=0
            if [ -d "$__flag" ]; then
              __rstripped+=("-rpath-link" "$__flag")
            fi
          fi
          if [ "$__flag" = "-L" ]; then
            __pending=1
          fi
          case "$__flag" in
            -L/*)
              if [ -d "''${__flag:2}" ]; then
                __rstripped+=("-rpath-link" "''${__flag:2}")
              fi
              ;;
          esac
          __kept+=("$__flag")
        done
        export NIX_LDFLAGS="''${__kept[*]} ''${__rstripped[*]}"
        unset __ldflags __kept __rstripped __skip __pending __flag
      '';

      glibcAll =
        pkgs:
        pkgs.symlinkJoin {
          name = "glibc-static-dynamic";
          paths = [
            pkgs.glibc
            pkgs.glibc.dev
            pkgs.glibc.static
          ];
        };

      x11Libs =
        pkgs:
        with pkgs;
        [
          libx11
          libxext
          libxcursor
          libxrandr
          libxi
          libxfixes
          libxinerama
          libxscrnsaver
          libxxf86vm
          libxcb
        ];

      runtimeLibs =
        pkgs:
        (x11Libs pkgs)
        ++ (with pkgs; [
          vulkan-loader
          mesa
          alsa-lib
          udev
        ]);

      relinkerShell = pkgs: pkgs.mkShell {
        name = "anyps5-relinker";

        packages = with pkgs; [
          cmake
          ninja
          gcc
          binutils
          git
          python3
        ];

        hardeningDisable = [ "format" "fortify" "fortify3" ];

        LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath [ pkgs.gcc.cc.lib ];

        shellHook = ''
          ${stripRPath}

          export NIX_LDFLAGS="-L${glibcAll pkgs}/lib -rpath-link ${glibcAll pkgs}/lib -rpath-link ${pkgs.gcc.cc.lib}/lib ''${NIX_LDFLAGS:-}"

          echo "AnyPS5 relinker-only shell"
          echo "  cmake -S . -B build-relinker -G Ninja -DCMAKE_BUILD_TYPE=Release -DANYPS5_RELINKER_ONLY=ON -DBUILD_TESTING=ON"
          echo "  cmake --build build-relinker --parallel"
          echo "  ctest --test-dir build-relinker --output-on-failure"
        '';
      };
    in
    {
      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          name = "anyps5";

          packages = with pkgs; [
            cmake
            ninja
            gcc
            binutils
            git
            pkg-config
            python3
            ccache
            cacert
          ] ++ (runtimeLibs pkgs);

          hardeningDisable = [ "format" "fortify" "fortify3" ];

          SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
          LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath ((runtimeLibs pkgs) ++ [ pkgs.gcc.cc.lib ]);

          shellHook = ''
            ${stripRPath}

            export NIX_LDFLAGS="-L${glibcAll pkgs}/lib -rpath-link ${glibcAll pkgs}/lib -rpath-link ${pkgs.gcc.cc.lib}/lib ''${NIX_LDFLAGS:-}"

            if [ -z "''${VK_ICD_FILENAMES:-}''${VK_DRIVER_FILES:-}" ] \
               && ! ls /run/opengl-driver/share/vulkan/icd.d/*.json >/dev/null 2>&1 \
               && ! ls /usr/share/vulkan/icd.d/*.json >/dev/null 2>&1; then
              export VK_DRIVER_FILES="${pkgs.mesa}/share/vulkan/icd.d/lvp_icd.x86_64.json"
            fi

            echo "AnyPS5 full-build shell"
            echo "  git submodule update --init --recursive"
            echo "  cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=ON"
            echo "  cmake --build build --parallel && cmake --build build --target libs --parallel"
            echo "  ctest --test-dir build --output-on-failure"
          '';
        };

        relinker = relinkerShell pkgs;
      });
    };
}
