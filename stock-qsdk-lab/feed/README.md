# Compatible opkg feed

The firmware keeps the native QSDK opkg implementation and LuCI package page.
The release provides a bounded repository of packages built for this firmware;
it is not interchangeable with arbitrary OpenWrt snapshot feeds because the
libc, library and kernel ABIs differ.

## Package policy

- Prefer unmodified upstream applications where the QSDK ABI allows it.
- Keep board or compatibility changes in normal IPKs, not post-install copies.
- Preinstall only system requirements and the production profile's selected
  applications.
- Deliver other compatible packages in `compatible-feed/`.
- Do not embed an IPK cache or invent an online source URL.
- Never publish a kernel package unless its vermagic and module ABI match the
  retained vendor kernel.

`native-feed-inputs.tsv` is the single list for copied native packages. Each
entry declares the package, installation policy, input type and build output.
During staging, every IPK is unpacked and checked so its control `Package`,
`Version` and `Architecture` agree with the manifest and filename. Dependencies
and the actual SHA-256 are written to `Native-Packages.tsv`.

The old `native-feed-artifacts.sha256` duplicate table is intentionally absent.
Reviewed packages promoted into the rootfs remain protected by the component
profile; kernel-facing extensions retain their independent ABI/hash locks. The
repository index, package inventory and final release checksums bind the actual
delivered bytes.

## Production and base profiles

`build.sh` selects the production profile. Packages marked `manual` or `auto`
are installed in the rootfs, including PassWall, its Simplified Chinese catalog,
Xray, Shadowsocks-Rust and required helpers. sing-box is not preinstalled.

`build.sh base` installs only the required native network package from this
list. Both profiles publish the same compatible repository separately and use
the `external` feed policy, so SquashFS contains no `.ipk` cache.

## Build and verify a feed

The release builder performs these steps automatically. For a standalone check:

```sh
tmp=/tmp/sbe-feed
python3 feed/stage_native_feed.py --lab . --output "$tmp/input"
sh feed/build-feed.sh --input "$tmp/input" --output "$tmp/repository"
sh feed/verify-feed.sh --feed "$tmp/repository"
```

`build-feed.sh` creates the standard `Packages`, compressed index and checksum
inventory. Optional `--private-key` and `--public-key` arguments add a usign
signature. A production online repository needs a real HTTPS location and a
managed signing key; neither is fabricated by the firmware build.

## Offline repository package

The release also contains `sbe1v1k-qsdk-offline-feed.ipk`. Installing it through
LuCI copies the compatible repository to writable storage and adds a normal
`file://` opkg source. Removing that package removes the local repository but
does not uninstall applications previously installed from it.
