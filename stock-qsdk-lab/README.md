# SBE1V1K QSDK 1.5.3 firmware builder

This directory builds a flashable SBE1V1K firmware from the Spectrum 1.5.3
vendor image while retaining the vendor kernel, board support, Wi-Fi firmware,
NSS/PPE/ECM acceleration and hardware calibration data. The carrier management
plane is replaced with standard OpenWrt-style UCI, netifd, fw3, Dropbear, rpcd,
uhttpd, opkg and LuCI.

The build does not write a router, change U-Boot or repartition eMMC.

## Build

On Apple Silicon macOS with Docker running:

```sh
# Production image (PassWall, Xray and Shadowsocks-Rust preinstalled)
./stock-qsdk-lab/build.sh

# Base image without optional proxy applications
./stock-qsdk-lab/build.sh base
```

Other useful commands:

```sh
./stock-qsdk-lab/build.sh sources          # initialize locked source trees
./stock-qsdk-lab/build.sh sources --check  # read-only source check
./stock-qsdk-lab/build.sh plan             # show component status
./stock-qsdk-lab/build.sh check            # verify cached inputs
./stock-qsdk-lab/build.sh component NAME   # rebuild one component
```

The default release directory is timestamped under `out/releases/`. Use
`release --output DIR` for an explicit new output directory. Existing output is
never overwritten. Full host requirements, optional inputs, build stages and
the hash policy are in [BUILDING.md](BUILDING.md).

## Release files

The `release/` directory contains:

- `*-initramfs-uImage.itb`: the official OpenWrt RAM image, verified against
  the matching upstream `sha256sums`;
- `*-squashfs-factory.bin`: a 64 KiB-aligned root filesystem for the upstream
  factory installation role; it is not a whole-device recovery image;
- `*-squashfs-sysupgrade.bin`: a standard OpenWrt sysupgrade tar containing
  `CONTROL`, `kernel`, `root` and fwtool metadata;
- `compatible-feed/`: QSDK-compatible packages and a standard opkg index;
- `sbe1v1k-qsdk-offline-feed.ipk`: an optional package that installs the
  compatible feed locally on an existing installation;
- `release-artifacts.json` and `SHA256SUMS`.

The sysupgrade uses the SBE1V1K mainline layout. It is intended for both:

1. the official OpenWrt installation flow after booting the verified initramfs;
2. an existing mainline HTTP U-Boot/OpenWrt/QSDK installation that accepts the
   standard SBE1V1K sysupgrade archive.

Layout metadata, p25 FIT size, p27 root filesystem size and protected partition
scope are checked during image creation. A valid tar archive alone is not
considered flash-safe. The operator remains responsible for selecting the
correct device and performing the flash.

## Firmware policy

- Vendor Linux 5.4.213, QCA Wi-Fi/WIFIFW, SSDK, NSS datapath and ECM/PPE are
  retained.
- OpenSync, OVSDB, CUJO and carrier SSH management are not started or exposed.
- LuCI includes the normal network, DHCP/DNS, firewall, package, backup and
  upgrade pages, plus SBE1V1K hardware status and LED pages.
- English and Simplified Chinese are installed using normal LuCI translation
  catalogs.
- The hardware page uses RAM-only temperature/fan history and reads fan
  thresholds from the active policy. Missing IoT data is hidden.
- The default fan policy starts at 75 °C and releases at 70 °C; the vendor high
  temperature protection remains in place.
- Production images preinstall PassWall, Xray, Shadowsocks-Rust and their
  verified dependencies. sing-box remains available only in the compatible
  feed. Proxying is disabled until configured by the administrator.
- No IPK cache or fictitious online package URL is embedded in SquashFS.

## Validation boundary

The build keeps byte locks for vendor/download inputs, reviewed rootfs
promotions and kernel-facing artifacts. Packages that only enter the compatible
feed are selected by manifest and checked by package identity, filename version,
architecture, dependency metadata, generated repository hashes and final
`SHA256SUMS`.

Only the rootfs checks executed by the production build remain in `tests/`.
Historical RAM experiments, device gates, candidate handoffs, screenshots and
duplicate static/unit suites are not part of this tool.

Offline checks do not replace device acceptance. After flashing, verify boot,
LAN/WAN, DNS/DHCP, IPv4/IPv6, all three radios, NSS/PPE/ECM, LuCI, LEDs, fan
control, backup/restore and the recovery path on the target hardware.

Recovery and installation helpers are documented in [recovery/README.md](recovery/README.md).

## Repository hygiene

`deps/`, `cache/`, `work/`, component output directories and `out/` are ignored.
Do not commit downloaded source trees, firmware images, IPKs, router backups,
keys, passwords or developer-specific paths. Third-party Git sources are normal
locked checkouts initialized by `build.sh sources`; no submodules are required.
