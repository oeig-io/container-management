# TODO

- [x] need to make parameter where can chose nixos unstable - currently hard-coded
  - Added NIXOS_IMAGE parameter in launch.sh (defaults to images:nixos/26.05)
  - Configs can override with NIXOS_IMAGE="images:nixos/unstable"
- [x] need new install-opencode
  - [x] uses nixos unstable (via configs/opencode.conf)
  - [x] opencode service runs as 'opencode' user
  - [x] single-phase installation (no ansible needed)
  - [ ] include firefox (deferred - not needed per user)
  - [ ] include everything needed to run x11 forwarding from incus profile (deferred - using web ui instead)
