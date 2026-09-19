#!/usr/bin/env python3
"""Static source/recipe policy for the isolated diagnostics candidates."""

from __future__ import annotations

import pathlib
import re
import sys
import hashlib


BUILD_DIR = pathlib.Path(__file__).resolve().parent

RECIPES = {
    "mtr": BUILD_DIR
    / "package-overlay/sbe-mtr096-root-cli-candidate/Makefile",
    "htop": BUILD_DIR / "package-overlay/sbe-htop353-candidate/Makefile",
    "nano": BUILD_DIR / "package-overlay/sbe-nano92-daily-candidate/Makefile",
}

REQUIRED_FLAGS = {
    "mtr": {
        "--without-gtk",
        "--without-jansson",
        "--without-ipinfo",
        "--disable-braille",
        "--disable-bash-completion",
    },
    "htop": {
        "--disable-pcp",
        "--enable-unicode",
        "--enable-affinity",
        "--disable-backtrace",
        "--with-libunwind=no",
        "--disable-demangling",
        "--disable-hwloc",
        "--disable-capabilities",
        "--disable-delayacct",
        "--disable-sensors",
    },
    "nano": {
        "--disable-nls",
        "--enable-utf8",
        "--enable-help",
        "--enable-linenumbers",
        "--enable-browser",
        "--enable-color",
        "--enable-comment",
        "--enable-justify",
        "--enable-mouse",
        "--enable-multibuffer",
        "--enable-nanorc",
        "--enable-operatingdir",
        "--enable-tabcomp",
        "--enable-wordcomp",
        "--enable-wrapping",
        "--disable-extra",
        "--disable-formatter",
        "--disable-histories",
        "--disable-libmagic",
        "--disable-linter",
        "--disable-speller",
    },
}

EXPECTED_PAYLOADS = {
    "mtr": {"/usr/sbin/mtr", "/usr/sbin/mtr-packet"},
    "htop": {"/usr/bin/htop"},
    "nano": {"/usr/bin/nano"},
}

OFFICIAL_SOURCE_URLS = {
    "mtr": "https://www.bitwizard.nl/mtr/files",
    "htop": "https://github.com/htop-dev/htop/releases/download/3.5.3",
    "nano": "https://www.nano-editor.org/dist/v9",
}

OFFICIAL_ARCHIVES = {
    "mtr": "mtr-0.96.tar.gz",
    "htop": "htop-3.5.3.tar.xz",
    "nano": "nano-9.2.tar.xz",
}

EXPECTED_AUXILIARY_FILES = {
    "mtr": {},
    "htop": {
        "patches/010-lock-release-version.patch":
            "c80eb69ea1b5b7dff65804ac91b67d986a42b889828bfc54a88d0f39c7e796f0",
    },
    "nano": {},
}


def fail(message: str) -> None:
    raise SystemExit(f"ERROR: {message}")


def recipe_payloads(text: str) -> set[str]:
    payloads: set[str] = set()
    for line in text.splitlines():
        if not any(macro in line for macro in ("$(INSTALL_BIN)", "$(INSTALL_DATA)", "$(INSTALL_CONF)")):
            continue
        payloads.update(re.findall(r"\$\(1\)(/(?:usr|sbin|bin)/[^\s]+)", line))
    return payloads


def inspect_recipe(name: str, path: pathlib.Path) -> None:
    if not path.is_file():
        fail(f"missing {name} package recipe: {path}")
    text = path.read_text(encoding="utf-8")

    for flag in REQUIRED_FLAGS[name]:
        if flag not in text:
            fail(f"{name} recipe lacks locked feature policy {flag}")
    configure_ac = (BUILD_DIR / "sources" / name / "configure.ac").read_text(
        encoding="utf-8"
    )
    declared_options = {
        (kind.lower(), option)
        for kind, option in re.findall(
            r"AC_ARG_(ENABLE|WITH)\(\s*\[?([A-Za-z0-9_-]+)", configure_ac
        )
    }
    for flag in REQUIRED_FLAGS[name]:
        match = re.match(r"--(enable|disable|with|without)-([^=]+)", flag)
        if not match:
            fail(f"cannot interpret locked {name} configure flag {flag}")
        # --disable-nls is supplied by gettext's generated configure macros,
        # not by a literal AC_ARG_ENABLE in nano's configure.ac.
        if name == "nano" and flag == "--disable-nls":
            continue
        family = "enable" if match.group(1) in {"enable", "disable"} else "with"
        if (family, match.group(2)) not in declared_options:
            fail(f"{name} upstream no longer declares configure option {flag}")
    if f"PKG_SOURCE_URL:={OFFICIAL_SOURCE_URLS[name]}" not in text:
        fail(f"{name} recipe does not name its official source origin")
    if f"PKG_SOURCE:={OFFICIAL_ARCHIVES[name]}" not in text:
        fail(f"{name} recipe does not lock its official archive filename")
    if f"  SOURCE:={OFFICIAL_ARCHIVES[name]}" not in text:
        fail(f"{name} IPK metadata does not name the official archive")
    if "DEPENDS:=+libncurses" not in text:
        fail(f"{name} recipe is not bound to the reviewed ncurses ABI")
    if "-fstack-protector-strong" not in text or "-z,now,-z,relro,-z,noexecstack" not in text:
        fail(f"{name} recipe lacks the candidate hardening flags")
    if re.search(r"^define Package/.+/(?:preinst|postinst|prerm|postrm)$", text, re.M):
        fail(f"{name} recipe must not execute package lifecycle hooks")
    if re.search(r"^define Package/.+/conffiles$", text, re.M):
        fail(f"{name} recipe unexpectedly installs configuration state")
    if re.search(r"(?:^|\s)(?:curl|wget|git clone)(?:\s|$)", text, re.M):
        fail(f"{name} recipe contains a build-time network command")
    if re.search(r"BEGIN [A-Z0-9 ]*PRIVATE KEY", text):
        fail(f"{name} recipe contains private-key material")
    if any(marker in text.lower() for marker in ("api_key", "apikey", "password=")):
        fail(f"{name} recipe contains a credential field")

    payloads = recipe_payloads(text)
    if payloads != EXPECTED_PAYLOADS[name]:
        fail(f"{name} recipe payload differs from policy: {sorted(payloads)}")

    overlay_dir = path.parent
    extra_files = {
        item.relative_to(overlay_dir).as_posix(): hashlib.sha256(item.read_bytes()).hexdigest()
        for item in overlay_dir.rglob("*")
        if item.is_file() and item != path
    }
    if extra_files != EXPECTED_AUXILIARY_FILES[name]:
        fail(f"{name} overlay auxiliary files differ from policy: {extra_files}")

    if name == "mtr":
        if re.search(r"--(?:with|without)-libasan", text):
            fail(
                "mtr recipe must omit the broken upstream libasan option; "
                "v0.96 enables sanitizers even for --without-libasan"
            )
        if re.search(r"^PKG_INSTALL\s*:=", text, re.M):
            fail("mtr must bypass upstream's privileged install hook")
        if "$(PKG_INSTALL_DIR)" in text:
            fail("mtr must copy only unprivileged build-tree executables")
        if "chmod 0700 $(1)/usr/sbin/mtr $(1)/usr/sbin/mtr-packet" not in text:
            fail("mtr and mtr-packet must be root-only mode 0700")
        commands = "\n".join(
            line for line in text.splitlines() if not line.lstrip().startswith("#")
        )
        if re.search(r"\bsetcap\b|cap_net_raw|chmod\s+(?:u\+s|[0-7]*[46][0-7][0-7])", commands):
            fail("mtr recipe attempts setuid or file-capability installation")


def scan_private_material() -> None:
    marker = re.compile(rb"-----BEGIN (?:[A-Z0-9 ]+ )?PRIVATE KEY-----")
    for source_name in ("mtr", "htop", "nano"):
        root = BUILD_DIR / "sources" / source_name
        if not (root / ".git").is_dir():
            fail(f"missing official {source_name} source clone")
        if not (root / "configure.ac").is_file():
            fail(f"{source_name} release worktree is not checked out")
        for path in root.rglob("*"):
            if not path.is_file() or ".git" in path.parts:
                continue
            try:
                data = path.read_bytes()
            except OSError as exc:
                fail(f"cannot inspect {path}: {exc}")
            if marker.search(data):
                fail(f"upstream source contains private-key material: {path}")


def main() -> int:
    for name, path in RECIPES.items():
        inspect_recipe(name, path)
    scan_private_material()

    mtr_makefile = (BUILD_DIR / "sources/mtr/Makefile.am").read_text(
        encoding="utf-8"
    )
    if "setcap cap_net_raw+ep" not in mtr_makefile or "chmod u+s" not in mtr_makefile:
        fail("mtr upstream privileged install hook changed; review bypass again")

    print(
        "PASS: official-source recipes have exact reviewed payloads, no credential "
        "state, no build-time fetches, and root-only non-setuid mtr policy."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
