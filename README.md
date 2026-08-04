# UFI003 Alpine Image Builder

面向 Qualcomm MSM8916 `UFI003_MB`（lk2nd 设备族 `zhihe,various`）的 Alpine Linux 镜像构建与安全刷机工具。

本分支把内核、DTB、模块、固件和 GPT 作为一套不可拆分的 UFI003 配置发布。不要把其他 OpenStick 型号或参考包里的 `boot`、GPT、DTB 单独混入本产物。

## 功能

- Alpine Linux 3.24 + OpenRC。
- 与仓库预置 UFI003 5.15 内核匹配的 boot、模块和固件。
- 系统内包含 Android platform-tools，可直接运行 `fastboot --version`。
- `sudo reboot-fastboot` 通过 `misc` 分区请求下一次启动进入 fastboot。
- USB 同时提供 NCM 和 RNDIS，两端口桥接到 `usbbr0`，共享地址为 `192.168.5.1/24`。
- Dropbear SSH、Wi-Fi 热点、首次启动自动扩展 ext4 rootfs。
- 构建后强制检查 GPT 双表及 CRC、boot/rootfs PARTUUID、Android boot 头、稀疏镜像结构和 SHA-256。

> [!IMPORTANT]
> 软件检查可以阻止已知的不匹配或损坏产物，但没有任何离线构建能承诺所有硬件变体 100% 启动。发布前仍应在一台可恢复的 UFI003_MB 上完成本文末尾的硬件验收；首次测试必须保留完整 EDL 备份。

## 构建

推荐 Ubuntu 24.04 x86_64，仓库需要完整子模块：

```sh
git clone -b alpine --recurse-submodules https://github.com/wcwq99/UFI003-Alpine.git
cd UFI003-Alpine
sudo ./build.sh
```

也可以在 GitHub Actions 中手动运行 `Build` 工作流。本地和 CI 都会先运行契约测试，只有最终验证器通过才生成 `files/SHA256SUMS` 并发布刷机包。

关键构建步骤为：

```sh
sudo scripts/install_deps.sh
sudo scripts/build_hyp_aboot.sh
sudo scripts/extract_fw.sh
sudo scripts/alpine_rootfs.sh
sudo scripts/build_images.sh
sudo python3 scripts/validate_artifacts.py files --write-manifest
```

成功的 `files/` 至少包含：

```text
gpt_both0.bin  hyp.mbn  rpm.mbn  sbl1.mbn  tz.mbn
aboot.mbn      lk2nd.img
boot.bin       alpine_rootfs.bin
SHA256SUMS     flash-alpine.ps1  flash-alpine.bat
```

`aboot.mbn` 是本次构建生成并签名的 lk1st；刷机流程不会再使用旧的 `aboot.bin`。

## 刷机前准备

1. 确认主板为 UFI003_MB。其他 MSM8916 棒子不能因为 SoC 相同就使用这套 GPT/boot。
2. 使用 EDL 保存完整 eMMC 镜像，例如 `edl rf ufi003-original.bin`，并把备份复制到另一块磁盘。
3. Windows 安装 Android platform-tools，保证 `fastboot.exe` 在 `PATH`，或把它放到刷机包目录。
4. 只连接一台 fastboot 设备。刷机脚本检测到零台或多台都会停止。
5. 不要修改或删除 `SHA256SUMS`；任何必需文件缺失或哈希不一致都会停止。

如果设备还没有可用的 fastboot，需要先在 EDL 中写入本构建生成的 lk1st，再清空 boot 让它进入 fastboot：

```sh
edl w aboot aboot.mbn
edl e boot
edl reset
```

这一步依赖设备可用的 EDL 恢复通道。先完成整盘备份。

## Windows 安全刷机

### 已使用本项目分区布局：仅更新系统（推荐）

双击 `flash-alpine.bat`，或运行：

```powershell
.\flash-alpine.ps1
```

默认 `SystemOnly` 模式只写 `boot` 和 `rootfs`，不会改 GPT、低级固件或校准分区。

### 首次安装：完整刷机

```powershell
.\flash-alpine.ps1 -Mode Full -ConfirmFullFlash
```

完整模式执行以下顺序：

1. 校验全部镜像 SHA-256，并确认恰好一台 fastboot 设备。
2. 临时从 `boot` 启动 `lk2nd.img`。
3. 备份 `cdt`、`sec`、`fsc`、`fsg`、`modemst1`、`modemst2` 到 `backups/<时间>/`。
4. 只有六个备份全部非空后才允许写 GPT。
5. 写入匹配的 GPT、低级固件、boot 和 rootfs，再恢复校准分区。

任一校准备份失败时，脚本会在写 GPT 之前停止，并保留设备的维护 fastboot 状态和已取得的备份。不要绕过 `-ConfirmFullFlash`，也不要手工跳过校准恢复。

常用参数：

```powershell
# 指定刷机包与 fastboot.exe
.\flash-alpine.ps1 -BundleDirectory D:\ufi003 -FastbootPath D:\platform-tools\fastboot.exe

# 完成后暂不重启
.\flash-alpine.ps1 -NoReboot
```

## 启动与网络

首次启动会生成设备唯一的 machine-id 和 SSH host key，并尝试扩展 rootfs。请等待约 2 分钟再连接。

| 项目 | 值 |
| --- | --- |
| 普通用户 | `user` |
| 初始密码 | `openstick` |
| root | 已锁定，使用 `sudo` |
| USB 地址 | `192.168.5.1/24` |
| SSH | `ssh user@192.168.5.1` |
| Wi-Fi SSID | `Openstick` |
| Wi-Fi 密码 | `openstick` |

USB gadget 同时创建 NCM 与 RNDIS，以兼容 Linux/macOS 和 Windows；NetworkManager 将两个接口加入同一个 `usbbr0`，只由桥持有地址和共享/NAT 配置。

镜像没有伪装 ADB 功能：Alpine 的 `android-tools` 提供 `fastboot`/`adb` 客户端，但不提供可服务 FunctionFS gadget 的 `adbd`。暴露一个没有守护进程的 ADB FunctionFS 会导致整个 USB gadget 无法绑定，所以发布配置明确只启用可工作的 NCM/RNDIS 网络共享。

## 硬件验收清单

每次改变 boot、GPT、内核、模块或 USB 配置后，发布前至少检查：

```sh
# 串口应出现正常 login 提示，登录后执行
uname -a
fastboot --version
ip address show usbbr0
rc-service openstick-usb status
rc-service networkmanager status

# 验证下一次启动进入 bootloader fastboot
sudo reboot-fastboot
```

主机侧随后应能看到唯一设备：

```sh
fastboot devices
```

再刷一次 `SystemOnly` 并确认能够重新启动、通过 `192.168.5.1` SSH 登录。只有完成这组真机测试的具体构建产物，才应标记为已验证可刷、可启动。
