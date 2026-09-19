# SBE1V1K 原厂系统一键刷入 QSDK

本目录提供从原厂 Reset 恢复入口开始，到启动官方 OpenWrt RAMFS，再永久刷入本
项目 QSDK 固件的单脚本流程。无需第二台路由器、Warehouse 模式或 UART。

## 准备

Mac 安装依赖：

```sh
brew install dnsmasq u-boot-tools dtc
```

用下面的命令找到直连路由器的 USB/Thunderbolt 有线接口，例如 `en7`：

```sh
networksetup -listallhardwareports
```

电脑有线口连接 SBE1V1K 的 2.5G LAN 口，不要连接 WAN。电脑的其他网络不要占用
`192.168.1.0/24`。

## 刷机

将固件 URL 占位符替换为公开发布的完整 QSDK sysupgrade 地址：

```sh
cd /path/to/SBE1V1K
./stock-qsdk-lab/recovery/flash-sbe1v1k-from-stock-macos.sh en7 \
  https://github.com/yangzhg/SBE1V1K/releases/download/sbe1v1k-qsdk-1.5.3/sbe1v1k-qsdk-1.5.3-squashfs-sysupgrade.bin
```

完整镜像包含本项目增加的 QSDK 5.4 内核模块、PassWall、Xray 和 Shadowsocks；
Sing-box 不预装。发布服务器提供 SHA-256 时可以同时指定：

```sh
SBE_FIRMWARE_SHA256='sha256-from-release-page' \
  ./stock-qsdk-lab/recovery/flash-sbe1v1k-from-stock-macos.sh en7 \
  https://github.com/yangzhg/SBE1V1K/releases/download/sbe1v1k-qsdk-1.5.3/sbe1v1k-qsdk-1.5.3-squashfs-sysupgrade.bin
```

脚本显示 `DHCP/TFTP is ready` 后：

1. 路由器断电五秒。
2. 按住 Reset 并接通电源。
3. 继续按住约 12 秒后松开。

其余流程自动完成：下载并校验官方 OpenWrt initramfs、准备 DHCP option 43/TFTP、
等待 RAMFS、确认设备和分区布局、停止 TFTP、设置 mainline 启动环境、清空配置执行
一次 `sysupgrade`，最后等待新固件从 p27 和持久 overlay 启动。

出现 `Starting sysupgrade` 后不要断电。成功时终端会显示：

```text
SUCCESS: SBE1V1K is running the installed QSDK firmware at https://192.168.1.1/
```

新系统默认 root 密码为空，应先通过 SSH 执行 `passwd`，再连接 WAN。

## 写入范围

脚本更新 p17 的启动环境，并由 OpenWrt 官方 sysupgrade 平台代码写入 p25、p27，
同时重置 p29 overlay。它不会替换 U-Boot，也不会写 GPT、eMMC boot0/boot1、
p18/p19 或 p40 HTTP recovery chainloader。

如果流程在 `Starting sysupgrade` 之前失败，可以按终端留下的临时目录查看日志，
修正有线接口、网段或 URL 后重新执行。
