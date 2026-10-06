# Ruby HyperOpt Kernel —【实验性内核 / Experimental】

> ⚠️ **实验性内核（Experimental Kernel）**
> 面向 **Redmi Note 12 Pro 5G（代号 `ruby`，MediaTek MT6877 / 天玑1080）**。
> 本内核为**实验性质**，**未经真机完整验证**，基于社区公开源码二次构建与优化。
> 刷机有风险（仅限 `boot.img`，可用原厂 `boot.img` 回刷），**请自行备份、风险自负**。
> 请勿用于生产/主力机长期使用。

**策略：B —— HyperMoon 安全源 + 中量深度优化**
（HyperOS 环境/账号问题由你在用户层解决，本内核不再处理；目标是"能开机 + 更多优化"）

- **内核源**：HyperMoon（已验证可在 HyperOS 开机，vanilla 基础，风险最低）
- **优化**：BBR/FQ 网络栈、WireGuard、ZRAM 压缩算法、**LZ4KD 移植**（源自 MoonWake）
- **Root**：KernelSU + SUSFS（沿用 HyperMoon 原配置）
- **打包**：AnyKernel3 HOS 分支（`DXRN-MoonWake/AnyKernel3` → `hyper`）

> 构建骨架复用已验证的 ruby 内核 CI；工具链 = AOSP clang r530567(14)；KSU 注入 = DPR-MoonWake/KernelSU-Unified(setup.sh susfs)。

---

## 一、本次纳入的优化（`scripts/prepare.sh`）

会生成 `arch/arm64/configs/vendor/opt.config`：

| 类别 | 配置 |
|---|---|
| 网络拥塞控制 | `CONFIG_TCP_CONG_BBR=y`，默认 `bbr` |
| 队列调度 | `NET_SCH_FQ / FQ_CODEL / CODEL / PIE` |
| VPN | `CONFIG_WIREGUARD=y` |
| ZRAM | `ZRAM / ZRAM_WRITEBACK`，压缩算法 `LZ4 / LZ4HC / ZSTD / DEFLATE` |
| **LZ4KD（移植）** | `CRYPTO_LZ4K / CRYPTO_LZ4KD` + `LZ4K/LZ4KD_COMPRESS/DECOMPRESS` |

**LZ4KD 移植**（自动化，见 `prepare.sh`）：从 MoonWake 拉取 4 个源文件并改动 4 处：
- 新增 `crypto/lz4k.c`、`crypto/lz4kd.c`、`include/linux/lz4k.h`、`include/linux/lz4kd.h`
- `lib/Kconfig`：加 `LZ4K_COMPRESS/DECOMPRESS`、`LZ4KD_COMPRESS/DECOMPRESS`
- `crypto/Kconfig`：加 `CRYPTO_LZ4K`、`CRYPTO_LZ4KD`
- `crypto/Makefile`：加两行 obj
- `drivers/block/zram/zcomp.c`：把 `lz4k`/`lz4kd` 注册进可用的压缩算法列表（刷后可用内核管理器切换）

### 为什么没有 MGLRU / SLMK
- **MGLRU**：HyperMoon 树里没有，手工移植要改 **25 个文件**（`mm/vmscan.c` 等），无真机验证极易翻车 → 未纳入。
- **SLMK**：其 `slmk.config` 会 `CONFIG_MEMCG=n`、`CONFIG_PSI=n`，**HOS 很可能依赖 MEMCG**，是 MoonWake 在 HOS 不开机的头号嫌疑 → 未纳入。

---

## 二、使用方法（GitHub Actions）

1. 新建 GitHub 仓库，把本目录推上去：
   ```
   ruby-kernel-ci/
   ├── .github/workflows/build.yml
   ├── configs/release/ruby.json
   └── scripts/prepare.sh
   ```
2. Actions → **Build MoonWake Kernel** → **Run workflow**：
   - `config_type` = `release`
   - `config_file` = `ruby.json`
   - `kernel_branch` 留空、`full_dump` = `false`
3. 构建完成，在本次 run 的 **Artifacts** 下载 `Ruby-HyperOpt-KSU-*`（就是 AnyKernel3 的 zip）。

### 如果构建失败
最可能是 **LZ4KD 移植**引起的编译错误。把 `scripts/prepare.sh` 开头的
`ENABLE_LZ4KD="${ENABLE_LZ4KD:-true}"` 改为 `false`，重跑即可（其余优化不受影响）。

---

## 三、刷机（OrangeFox）

1. **先备份你当前 HyperOS 的原厂 `boot.img`**（救砖）。
2. 橙狐 → 安装下载的 AnyKernel3 zip → 滑刷 → 重启。
3. 建议在系统初始设置完成后再刷内核。
4. 救砖：`fastboot flash boot <原厂boot.img>`

刷入后可在内核管理器里把 ZRAM 压缩算法切到 **lz4kd**（同 MoonWake 用法）。

---

## 四、风险与边界

- **本仓库未经真机验证**（沙箱无法刷机）。风险仅限 `boot.img`，刷坏可用原厂 `boot.img` 回刷，不会真砖。
- 采用"HyperMoon 安全源"，开机率是三个方案里最高的；但任何自定义内核都有不开机概率。
- HyperOS 的账号/环境检测属用户层问题，本内核不处理（按你的要求）。

---

## 五、溯源

- HyperMoon 源码：https://github.com/DXRN-MoonWake/hypermoon_kernel_xiaomi_ruby (main)
- 优化来源：https://github.com/rodrig20/moonwake_kernel_xiaomi_ruby (moon)
- CI 骨架：https://github.com/rodrig20/KernelAction_moonwake_kernel_xiaomi_ruby
- 工具链：https://gitlab.com/DR-KernelArchive/clang/r530567 (14.0)
- KernelSU 注入：https://github.com/DPR-MoonWake/KernelSU-Unified (setup.sh susfs)
- AnyKernel3：https://github.com/DXRN-MoonWake/AnyKernel3 (branch: hyper)