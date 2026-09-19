# 构建原厂 QSDK 1.5.3 固件

本目录是一条独立的原厂 QSDK 构建路线。仓库根目录的主线 OpenWrt 构建脚本不参与
这里的固件装配。

## 常用命令

主机需要 Apple Silicon macOS、Python 3.10+、Git、curl 和正在运行的 Docker。
组件在 Linux ARM64 容器中交叉编译；首次完整构建建议预留至少 80 GiB 空间。

```sh
# 日常生产版：预装已验证的 PassWall、Xray、Shadowsocks-Rust 及依赖
./stock-qsdk-lab/build.sh

# 不预装可选代理应用的基础版
./stock-qsdk-lab/build.sh base

# 只下载或核对锁定源码
./stock-qsdk-lab/build.sh sources
./stock-qsdk-lab/build.sh sources --check

# 只读检查，不下载、不调用 Docker
./stock-qsdk-lab/build.sh plan
./stock-qsdk-lab/build.sh check

# 重新构建一个组件
./stock-qsdk-lab/build.sh component odhcp6c
```

默认输出到带 UTC 时间的
`stock-qsdk-lab/out/releases/sbe1v1k-qsdk-1.5.3-<profile>-<time>/`。
已有目录不会被覆盖。需要稳定路径时使用：

```sh
./stock-qsdk-lab/build.sh release \
  --output stock-qsdk-lab/out/releases/my-release
```

`init.sh` 仅为旧调用者保留，等价于 `build.sh sources`。通常不要直接运行
`tools/`、各组件目录或 `docker/assemble-rootfs.sh`。

## 可选输入

```sh
./stock-qsdk-lab/build.sh release \
  --qsdk-source-root /path/to/verified-qsdk \
  --builder-image your-builder:tag \
  --vendor-simg /path/to/vendor.simg \
  --initramfs /path/to/openwrt-initramfs.itb \
  --initramfs-sums /path/to/matching-sha256sums \
  --output stock-qsdk-lab/out/releases/local-test
```

- `--vendor-simg` 必须匹配 `sources/stock-1.5.3.json` 的版本、大小和 SHA-256。
- 本地 initramfs 必须和同批 OpenWrt `sha256sums` 一起提供。
- 指定 Docker 镜像时，实际 image ID 仍会写入构建记录。
- `--qsdk-source-root` 也可用 `QSDK_SOURCE_ROOT` 设置。

macOS 默认把 QSDK 放在区分大小写的 APFS sparsebundle：
`work/qsdk-sources.sparsebundle`，挂载点为 `deps/qsdk-spf12.2-locked`。
初始化不会 reset、清理或覆盖已有源码。

正式发布默认要求 `stock-qsdk-lab` 源码已提交。开发中需要验证未提交修改时，可临时设置
`SBE_ALLOW_DIRTY_SOURCE=1`；生成的根文件系统清单和 `release-artifacts.json` 会明确记录
`source_tree_dirty=true` 及差异摘要 SHA-256，不能冒充干净发布。

## 构建流程

`build.sh` 依次完成：

1. 下载并验证原厂 1.5.3 SIMG，提取 p25 FIT、p27 SquashFS 与无线固件。
2. 按 `sources/dependencies.json` 和 QSDK source lock 初始化源码。
3. 准备容器、工具链、用户态 headers 和组件输入。
4. 按 `sources/build-stages.json` 构建缺失组件。
5. 生成标准兼容软件源，验证 IPK 元数据和依赖。
6. 装配根文件系统，运行离线测试，生成 initramfs、factory、sysupgrade、
   `release-artifacts.json` 与 `SHA256SUMS`。

组件缓存会复用，但构建过程不会自动修改版本清单，也不会搜索工作区中“最新”的
同名产物。共享 QSDK 有排他锁，不要并行手工运行另一条 make。

## 哈希策略

哈希只保留在能建立安全边界的位置，避免同一中间文件在多处维护硬编码值。

| 对象 | 处理方式 | 原因 |
| --- | --- | --- |
| 原厂 SIMG、上游 initramfs、下载源码 | 版本清单固定 SHA-256 | 防止来源漂移或下载损坏 |
| 原厂根文件系统替换项、内核模块、内核插件 | 固定 SHA-256/ABI 门禁 | 错配可能导致无法启动或内核故障 |
| 仅进入兼容源的用户态 IPK | 清单选包，检查包名、版本、架构、依赖 | 允许按配方正常重建，不重复维护中间字节锁 |
| 兼容软件源和最终镜像 | 构建时生成索引哈希、物料记录和 `SHA256SUMS` | 绑定实际发布内容，便于验收和分发 |

作为已审查根文件系统替换项的用户态组件仍由 component profile 固定字节身份；
只有“仅进入兼容源”的副本取消重复锁。因此不再维护
`feed/native-feed-artifacts.sha256`。这不表示取消校验：
`stage_native_feed.py` 解包并验证每个 IPK，装配器再次核对记录中的 SHA-256，最终
发行目录再生成完整校验和。原厂输入、内核 ABI 和刷机布局门禁没有放宽。

## 输出和边界

`release/` 包含：

- 经上游校验的 `*-initramfs-uImage.itb`；
- 64 KiB 对齐的 `*-squashfs-factory.bin`；
- 标准 sysupgrade tar；
- `compatible-feed/` 和可选离线源包；
- `release-artifacts.json`、`SHA256SUMS`、来源与测试记录。

生产 profile 预装应用，但不把 IPK 缓存放进 SquashFS；代理默认关闭，sing-box
仍不预装。基础 profile 只保留系统必须包。两者使用相同的 mainline 分区布局、
硬件信息页、LED 页和中英文界面。

构建脚本不会 SSH 到设备、修改 U-Boot/GPT 或刷机。格式与离线测试通过只说明
产物达到真机验收入口；两条启动链仍需由操作者分别验证引导、升级、Wi-Fi/NSS、
网络、LuCI 和恢复路径。

## 故障排查

日志位于 `work/build-logs/<UTC-time>/`，`stages.json` 记录每个阶段结果。失败后：

1. 查看报错给出的阶段日志；
2. 保留不匹配的缓存用于调查，不要直接改 lock；
3. 修正配方或源码后运行 `build.sh component <name>`；
4. 再运行 `build.sh check`，最后重新发布到新目录。

低层兼容选项仍可直接传给 `build.sh`，但仅用于开发排查，例如
`--assemble-only`、`--components-only`、`--stage` 和旧的 `--with-passwall`；日常构建
应使用上面的子命令。
