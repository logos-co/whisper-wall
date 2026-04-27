{
  description = "WhisperWall Basecamp UI plugin — Qt6 C++ + Rust FFI";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, rust-overlay, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [ rust-overlay.overlays.default ];
        };

        rustToolchain = pkgs.rust-bin.stable.latest.default;

        rustPlatform = pkgs.makeRustPlatform {
          cargo = rustToolchain;
          rustc = rustToolchain;
        };

        # ── ZK circuit artifacts (needed by logos-blockchain-pol build.rs) ─────
        # Fetched from the official GitHub release — fully hermetic.
        logosCiruits = pkgs.fetchurl {
          url = "https://github.com/logos-blockchain/logos-blockchain-circuits/releases/download/v0.4.2/logos-blockchain-circuits-v0.4.2-linux-x86_64.tar.gz";
          sha256 = "13c5gkfsa70kca0nwffbsis2difmspyk8aqmlzhq12mhr3x1y4z9";
        };

        circuitsDir = pkgs.runCommand "logos-blockchain-circuits" {} ''
          mkdir -p $out
          tar -xzf ${logosCiruits} -C $out --strip-components=1
        '';

        # ── LEZ source (for nssa build.rs artifacts) ──────────────────────────
        # nssa/build.rs reads artifacts/program_methods/*.bin relative to its
        # CARGO_MANIFEST_DIR. The cargoLock fetcher already pulled this git source
        # (same NAR hash as amm_core-0.1.0 outputHash), so this is cache-only.
        lezSrc = pkgs.fetchgit {
          url = "https://github.com/logos-blockchain/logos-execution-zone.git";
          rev = "35d8df0d031315219f94d1546ceb862b0e5b208f";
          hash = "sha256-j0DzDvH88IUIReYi6N4FD6+mTIJOklQjaa9qjw4yHEg=";
        };

        # ── Rust FFI cdylib ────────────────────────────────────────────────────
        ffi = rustPlatform.buildRustPackage {
          pname = "whisper-wall-ffi";
          version = "0.1.0";
          src = ./ffi;

          cargoLock = {
            lockFile = ./ffi/Cargo.lock;
            outputHashes = {
              # LEZ (nssa, wallet, sequencer_service_rpc, …)
              "amm_core-0.1.0"                          = "sha256-j0DzDvH88IUIReYi6N4FD6+mTIJOklQjaa9qjw4yHEg=";
              # Espresso jellyfish (tag jf-crhf-v0.1.1)
              "jf-crhf-0.1.1"                           = "sha256-TUm91XROmUfqwFqkDmQEKyT9cOo1ZgAbuTDyEfe6ltg=";
              # Espresso jellyfish (rev dc166cf)
              "jf-poseidon2-0.1.0"                      = "sha256-QeCjgZXO7lFzF2Gzm2f8XI08djm5jyKI6D8U0jNTPB8=";
              # logos-blockchain
              "logos-blockchain-blend-crypto-0.1.2"     = "sha256-ypgXXvAUR4WbXGaOhoPy9AqTyYjqtIUye/Uyr1RF030=";
              # Overwatch
              "overwatch-0.1.0"                         = "sha256-L7R1GdhRNNsymYe3RVyYLAmd6x1YY08TBJp4hG4/YwE=";
            };
          };

          # logos-blockchain-pol build.rs requires ZK circuit artifacts.
          LOGOS_BLOCKCHAIN_CIRCUITS = "${circuitsDir}";

          # nssa build.rs reads ../artifacts/program_methods/*.bin relative to
          # its CARGO_MANIFEST_DIR (cargo-vendor-dir/nssa-0.1.0/).
          preBuild = ''
            ln -sf "${lezSrc}/artifacts" ../cargo-vendor-dir/artifacts
          '';

          # cdylib — no tests to run
          doCheck = false;
        };

        # ── Qt6 C++ plugin ─────────────────────────────────────────────────────
        plugin = pkgs.stdenv.mkDerivation {
          pname = "whisper-wall-plugin";
          version = "0.1.0";
          src = ./.;

          nativeBuildInputs = [
            pkgs.cmake
            pkgs.ninja
            pkgs.pkg-config
            pkgs.qt6.wrapQtAppsHook
          ];

          buildInputs = with pkgs.qt6; [
            qtbase
            qtdeclarative
          ];

          cmakeFlags = [
            # Point cmake at the nix-built FFI library — skips the manual
            # `cargo build --release` step that the cmake else-branch would do.
            "-DWHISPER_WALL_FFI_LIB_DIR=${ffi}/lib"
          ];

          installPhase = ''
            runHook preInstall
            cmake --install .
            # cmake install puts libs in $out/lib; add metadata and QML alongside.
            cp ${./manifest.json} $out/manifest.json
            cp ${./metadata.json} $out/metadata.json
            cp -r ${./qml} $out/qml
            runHook postInstall
          '';
        };

        # ── Install helper ─────────────────────────────────────────────────────
        # `nix run .#install` copies the built plugin into the Basecamp dev dir.
        installScript = pkgs.writeShellScriptBin "install-whisper-wall-plugin" ''
          PLUGIN_DIR="$HOME/.local/share/Logos/LogosBasecampDev/plugins/whisper_wall"
          mkdir -p "$PLUGIN_DIR"
          cp -f ${plugin}/lib/libwhisper_wall_plugin.so  "$PLUGIN_DIR/"
          cp -f ${plugin}/lib/libwhisper_wall_ffi.so     "$PLUGIN_DIR/"
          cp -f ${plugin}/manifest.json                  "$PLUGIN_DIR/"
          cp -f ${plugin}/metadata.json                  "$PLUGIN_DIR/"
          echo "Installed to $PLUGIN_DIR"
        '';

      in {
        packages = {
          default = plugin;
          ffi     = ffi;
          install = installScript;
        };

        # Development shell with Qt6 + Rust on PATH for cmake iteration.
        devShells.default = pkgs.mkShell {
          nativeBuildInputs = [
            rustToolchain
            pkgs.cmake pkgs.ninja pkgs.pkg-config
            pkgs.qt6.wrapQtAppsHook
          ];
          buildInputs = with pkgs.qt6; [ qtbase qtdeclarative ];
          shellHook = ''
            echo "whisper-wall UI dev shell"
            echo "  cmake, ninja, Qt6, Rust all on PATH"
            echo "  Build FFI:    cargo build --release (in ffi/)"
            echo "  Build plugin: cmake -B build -GNinja && cmake --build build"
          '';
        };
      });
}
