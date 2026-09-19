#!/usr/bin/env python3
"""Host-runnable source and compatibility gate for the 2026 core candidates."""

from __future__ import annotations

import re
import shutil
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parent
SOURCES = ROOT / "sources"
OVERLAY = ROOT / "package-overlay"


def fail(message: str) -> None:
    raise SystemExit(f"FAIL: {message}")


def run(*args: str, cwd: Path | None = None) -> str:
    proc = subprocess.run(
        args,
        cwd=cwd,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if proc.returncode:
        fail(f"{' '.join(args)}: {proc.stderr.strip()}")
    return proc.stdout


def require_text(path: Path, required: list[str], forbidden: list[str] | None = None) -> str:
    text = path.read_text(encoding="utf-8")
    try:
        label = path.relative_to(ROOT)
    except ValueError:
        label = path
    for token in required:
        if token not in text:
            fail(f"{label} lacks required token {token!r}")
    for token in forbidden or []:
        if token in text:
            fail(f"{label} retains forbidden token {token!r}")
    return text


def require_ancestors(name: str, commits: list[str]) -> None:
    repo = SOURCES / name
    head = run("git", "rev-parse", "HEAD", cwd=repo).strip()
    for commit in commits:
        proc = subprocess.run(
            ["git", "merge-base", "--is-ancestor", commit, head],
            cwd=repo,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        if proc.returncode:
            fail(f"{name} HEAD {head} does not contain security commit {commit}")


def struct_body(text: str, name: str) -> str:
    match = re.search(rf"struct {re.escape(name)} \{{.*?\n\}};", text, re.S)
    if not match:
        fail(f"cannot find struct {name}")
    return match.group(0)


def patched_tree(name: str, package: str, tmp: Path) -> Path:
    target = tmp / name
    shutil.copytree(SOURCES / name, target, ignore=shutil.ignore_patterns(".git"))
    patch_dir = OVERLAY / package / "patches"
    for patch in sorted(patch_dir.glob("*.patch")):
        with patch.open("rb") as stream:
            proc = subprocess.run(
                ["patch", "-p1", "--fuzz=0", "--batch"],
                cwd=target,
                stdin=stream,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
            )
        if proc.returncode:
            fail(f"{patch.name} does not apply exactly:\n{proc.stdout.decode(errors='replace')}")
    return target


def main() -> None:
    run(str(ROOT / "verify-sources.sh"))

    require_ancestors(
        "uhttpd",
        [
            "c7294e7037a9e6f8fb4b9084d31cb8e98bd7b5f9",
            "ae015e099986ceace44975cb69629841a2d58d37",
            "b78f518478794e16ba3568fc1258e40bf3e8eb3b",
            "7b1bec45826bd78c8afc993435bdc0f1df2fe399",
            "f6c2fcfa539de49ddf6de8f805110c8804602e98",
            "4f307a2156f3919c61fc20765acd4026c095c30d",
            "0910904b75a320570720eaf5bf0de250d91cb3bd",
            "893fed8577d7400d8ab008362d7865a4c37c5ed2",
            "daa5078b959b2a9f9c435705014836c64a410ea6",
            "f682ccabee9ed5f39dd3b0aaf96228975eeb478d",
            "ced7b15c346741982fe317cd2d9de0895e6c64a9",
            "add5389470f0f5534a1b7ef79f69e98c95a5ba82",
            "2c869c094c25e1b6b7c1ba786f22280a6c153447",
            "b33ca5d377189f0fa7f6ee1b325ec08078a64c91",
            "6fadf0da50509a510ac4f85d2adb70a83de2e1fc",
            "1b624f8f814ed568608d756512892416e0431d77",
            "3aa7e1c7678281220470e24784bcdcfb71bda6cf",
        ],
    )
    require_text(
        SOURCES / "uhttpd/client.c",
        [
            "num_content_length > 1",
            "num_content_length > 0 && num_transfer_encoding > 0",
            'if (!strcasecmp(val, "chunked"))',
            "UH_LIMIT_HEADER_COUNT",
            "UH_LIMIT_HEADER_BYTES",
            "if (!uh_is_tchar(*name))",
            "if (uh_is_ctl(*p))",
            "if (p == buf)",
            "r->connection_close = true;",
            "CHUNKED_TRAILER",
        ],
    )
    require_text(
        SOURCES / "uhttpd/ubus.c",
        ["remaining declared Content-Length bytes", "cl->request.connection_close = true;"],
    )
    require_text(
        SOURCES / "uhttpd/utils.c",
        ["i + 2 >= slen", "(len + 3) >= blen"],
    )
    require_text(
        SOURCES / "uhttpd/auth.c",
        ["uh_pass_compare", "realm->pass[0] != '$'", "req->realm = realm"],
    )
    require_text(
        OVERLAY / "sbe-uhttpd2026-candidate/Makefile",
        [
            "-DTLS_SUPPORT=ON",
            "-DUBUS_SUPPORT=ON",
            "-DLUA_SUPPORT=OFF",
            "-DUCODE_SUPPORT=OFF",
            "+libustream-openssl",
            "SBE_USTREAM_SSL_ABI_20150806",
        ],
    )

    require_ancestors(
        "rpcd",
        [
            "e37ed9d814699098eb7e26c8b33c054840782dfb",
            "79c8087c8e8eb8933980fa6fc584703526388446",
            "f5ffec54d7c74051286f9f6bca533271bd655c0b",
            "0de6668115593f2d316070573d12c29409c89078",
            "af5d6f431186bcd1847e9d3210652b09dbc90ce5",
            "26dba5206e1721efb217f6e7bafa27cd225bb698",
            "fb0302dc0e51e8e052609408f9c2a01b9337b510",
            "680705e4b76df705f083972b164b5917b283556b",
            "ab6549a99c7cc96eb4639aabe7066b898d9c1407",
        ],
    )
    new_header = (SOURCES / "rpcd/include/rpcd/plugin.h").read_text(encoding="utf-8")
    old_header = run(
        "git",
        "show",
        "67c8a3fda26e441d3ec4a19f50ac72eca8deb14b:include/rpcd/plugin.h",
        cwd=SOURCES / "rpcd",
    )
    for abi_struct in ("rpc_daemon_ops", "rpc_plugin"):
        if struct_body(new_header, abi_struct) != struct_body(old_header, abi_struct):
            fail(f"rpcd {abi_struct} ABI changed from the QSDK 2020 baseline")
    require_text(
        SOURCES / "rpcd/file.c",
        [
            "rpc_check_symlink_access",
            "realpath(*path, resolved)",
            "rpc_file_access(sid, resolved, perm)",
        ],
    )
    require_text(
        OVERLAY / "sbe-rpcd2026-candidate/Makefile",
        [
            "Package/sbe-rpcd2026-mod-iwinfo-candidate/extra_provides",
            "printf '%s\\n' libiwinfo.so;",
            "+libiwinfo",
        ],
    )

    require_ancestors(
        "odhcpd",
        [
            "68f382690bfaec56d5b1f31c3c31c48bcb642e3a",
            "03dacc23356b5789842b9d1bba0200fd005e35f3",
            "26b122007030ebf192376aff8f98d428b25e2a93",
            "0320032ae313452f3c8cb8725c621dd06c36dc03",
            "c6792bac3905d4bf726d914e9994f6d4b98c5b57",
            "d329a15413387027453644cd363dca06ade28328",
            "1782f3f2aad21cd7971798c898355a12a9611304",
            "5b1e3befb0b23f7b7506fb6209aed3aa9e04a6f7",
            "f2275efc72a87a95f971f159babcbadc5d241d42",
            "cc04882b3fac7643921a194ab65650274a69b2d6",
            "0eade3d4b7a37106f6498f4ce952ecd6ec1b932d",
            "d89caa59c00516d5b5803ed87a86204e4c992799",
            "ee0a11f40fa48302482fd6e85458e26d48de6e3a",
            "ed38cffa927d5fd450d20bfd3f7fb8d8e8fff301",
        ],
    )
    require_text(
        SOURCES / "odhcpd/src/dhcpv6.c",
        [
            "depth >= DHCPV6_HOP_COUNT_LIMIT",
            "olen >= sizeof(uint16_t)",
            "newlen < 0 || newlen > UINT16_MAX",
        ],
    )
    require_text(
        SOURCES / "odhcpd/src/ndp.c",
        ["ip6->ip6_hlim != 255", "req->nd_ns_hdr.icmp6_code != 0"],
    )
    require_text(
        SOURCES / "odhcpd/src/statefiles.c",
        ["statefiles_escape_hostname", '"\\\\x%02x"'],
    )
    require_text(
        OVERLAY / "sbe-odhcpd2026-ipv6only-candidate/Makefile",
        ["-DUBUS=1", "-DDHCPV4_SUPPORT=0"],
    )

    require_ancestors(
        "ppp",
        [
            "4b02040f4838237ecd08852c77acd2c89c32f392",
            "0bf7647f1d8c6e42ff1cc1cedae7b01b1642d3dc",
            "cc8b00c96646f858fbd4e2699077701c72ef9e1c",
            "1baf2ac29e4456f095c4ebe15230881201ce4ffb",
            "0d7b472f86d731665eb2048756643fa2b55cfadb",
            "2587a678e61e94b6366f1a3be020644668a97000",
        ],
    )
    require_text(
        OVERLAY / "sbe-ppp254-candidate/Makefile",
        [
            "--disable-microsoft-extensions",
            "--disable-eaptls",
            "--disable-peap",
            "--without-openssl",
            "--without-pam",
            "--without-atm",
            "--without-pcap",
            "--disable-multilink",
            "--with-plugin-dir=/usr/lib/pppd/2.5.4",
            "rp-pppoe.so",
        ],
    )

    with tempfile.TemporaryDirectory(prefix="sbe-core-userland-gate.") as temp:
        tmp = Path(temp)
        uhttpd = patched_tree("uhttpd", "sbe-uhttpd2026-candidate", tmp)
        require_text(
            uhttpd / "tls.c",
            [
                "#ifdef SBE_USTREAM_SSL_ABI_20150806",
                "Explicit cipher lists require a newer ustream-ssl ABI",
                "return -EOPNOTSUPP;",
            ],
        )
        rpcd = patched_tree("rpcd", "sbe-rpcd2026-candidate", tmp)
        require_text(
            rpcd / "sys.c",
            ["/usr/lib/opkg/status", '"packagelist"', '"password_set"', '"reboot"'],
            ["firmware.bin", "sysupgrade", "jffs2reset", '"factory"', '"upgrade_'],
        )
        require_text(
            rpcd / "session.c",
            ["uloop_timeout_remaining(&ses->t)"],
            ["uloop_timeout_remaining64"],
        )
        require_text(
            rpcd / "iwinfo.c",
            ["struct iwinfo_assoclist_entry", "rpc_iwinfo_api_init"],
            ["struct iwinfo_scanlist_entry_v2"],
        )
        require_text(
            rpcd / "CMakeLists.txt",
            [
                "IF(SBE_FACTORY_IWINFO_ABI)",
                "SET(iwinfo -Wl,--no-as-needed iwinfo -Wl,--as-needed)",
            ],
        )
        odhcpd = patched_tree("odhcpd", "sbe-odhcpd2026-ipv6only-candidate", tmp)
        require_text(
            odhcpd / "src/statefiles.c",
            ["statefiles_json_from_fd", "st.st_size > 1024 * 1024"],
            [
                "json_object_from_fd",
                "json_object_to_fd",
                "json_object_new_array_ext",
                "json_object_new_uint64",
            ],
        )
        require_text(
            odhcpd / "src/config.c",
            ["reload_pipe", "uloop_fd_add(&reload_fd, ULOOP_READ)", "signal(SIGHUP, signal_reload)"],
            ["uloop_signal_add"],
        )
        require_text(
            odhcpd / "src/odhcpd.h",
            ["fmt, ##__VA_ARGS__"],
            ["__VA_OPT__"],
        )
        ppp = patched_tree("ppp", "sbe-ppp254-candidate", tmp)
        require_text(ppp / "Makefile.am", ["SUBDIRS = pppd"], ["chat pppd pppstats pppdump"])
        require_text(
            ppp / "pppd/plugins/Makefile.am",
            ["SUBDIRS = pppoe", "pppd_plugin_LTLIBRARIES ="],
            ["SUBDIRS = pppoe pppoatm", "minconn.la", "passwordfd.la", "winbind.la"],
        )

    print("PASS: security ancestry, parser hardening, plugin ABI and minimal-feature gates.")
    print("BLOCKED: executable/chroot checks and PD/RA/PPPoE hardware RAM gates remain.")


if __name__ == "__main__":
    main()
