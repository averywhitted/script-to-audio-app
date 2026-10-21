#!/bin/sh
# Run cargo against a local crate mirror. Needed on the sandboxed dev Mac, where Rust-built binaries (cargo,
# rustup) cannot resolve DNS. Build the mirror with scripts/local_crate_mirror.py, then:
#   MIRROR=<mirror-dir> ./cargo-offline.sh build --release
MIRROR="${MIRROR:?set MIRROR to the directory made by scripts/local_crate_mirror.py}"
exec "$HOME/.cargo/bin/cargo" "$@" --offline \
  --config 'source.crates-io.replace-with="local-mirror"' \
  --config "source.local-mirror.local-registry=\"$MIRROR\""
