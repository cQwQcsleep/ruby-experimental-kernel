#!/usr/bin/env bash
#
# prepare.sh —— 在 defconfig 之前，对 HyperMoon 内核源码树做“中量深度优化”注入
# 由 GitHub Actions 在“内核源码根目录”内执行。
#
# 优化内容：
#   1) 网络：BBR 拥塞控制 + FQ/FQ_CODEL/CODEL/PIE 队列（主线符号，安全）
#   2) WireGuard 内置
#   3) ZRAM 常用压缩算法（lz4 / lz4hc / zstd / deflate）
#   4) 【移植】LZ4K / LZ4KD 压缩算法（来自 MoonWake，用于 ZRAM，可由内核管理器切换）
#      —— 需要拷贝 4 个源文件 + 修改 4 处 Kconfig/Makefile/zcomp.c
#
# 开关（可用 env 覆盖，或改这里）：
#   ENABLE_LZ4KD=true|false   是否移植 LZ4KD（默认 true；若 CI 构建失败可设为 false 重跑）
#
set -eu

ENABLE_LZ4KD="${ENABLE_LZ4KD:-true}"
MW_RAW="https://raw.githubusercontent.com/rodrig20/moonwake_kernel_xiaomi_ruby/moon"

CFG_DIR="arch/arm64/configs/vendor"

if [ ! -d "arch/arm64/configs" ]; then
  echo "[prepare][ERROR] 不在内核源码根目录（找不到 arch/arm64/configs）" >&2
  exit 1
fi

echo "[prepare] pwd=$(pwd)  ENABLE_LZ4KD=$ENABLE_LZ4KD"
mkdir -p "$CFG_DIR"

# ---------------------------------------------------------------- 1) opt.config
{
  echo "# ==== network: BBR + FQ ===="
  echo "CONFIG_TCP_CONG_BBR=y"
  echo 'CONFIG_DEFAULT_TCP_CONG="bbr"'
  echo "CONFIG_NET_SCH_FQ=y"
  echo "CONFIG_NET_SCH_FQ_CODEL=y"
  echo "CONFIG_NET_SCH_CODEL=y"
  echo "CONFIG_NET_SCH_PIE=y"
  echo "# ==== wireguard ===="
  echo "CONFIG_WIREGUARD=y"
  echo "# ==== zram / compressors ===="
  echo "CONFIG_ZRAM=y"
  echo "CONFIG_ZRAM_WRITEBACK=y"
  echo "CONFIG_CRYPTO_LZ4=y"
  echo "CONFIG_CRYPTO_LZ4HC=y"
  echo "CONFIG_CRYPTO_ZSTD=y"
  echo "CONFIG_CRYPTO_DEFLATE=y"
  if [ "$ENABLE_LZ4KD" = "true" ]; then
    echo "# ==== LZ4K / LZ4KD (ported from MoonWake) ===="
    echo "CONFIG_CRYPTO_LZ4K=y"
    echo "CONFIG_CRYPTO_LZ4KD=y"
    echo "CONFIG_LZ4K_COMPRESS=y"
    echo "CONFIG_LZ4K_DECOMPRESS=y"
    echo "CONFIG_LZ4KD_COMPRESS=y"
    echo "CONFIG_LZ4KD_DECOMPRESS=y"
  fi
} > "$CFG_DIR/opt.config"
echo "[prepare] wrote $CFG_DIR/opt.config"

# ---------------------------------------------------------------- 2) LZ4KD 移植
if [ "$ENABLE_LZ4KD" = "true" ]; then
  echo "[prepare] downloading LZ4K/LZ4KD sources from MoonWake..."
  curl -LSs "$MW_RAW/crypto/lz4k.c"         -o crypto/lz4k.c
  curl -LSs "$MW_RAW/crypto/lz4kd.c"        -o crypto/lz4kd.c
  curl -LSs "$MW_RAW/include/linux/lz4k.h"  -o include/linux/lz4k.h
  curl -LSs "$MW_RAW/include/linux/lz4kd.h" -o include/linux/lz4kd.h

  echo "[prepare] patching Kconfig / Makefile / zcomp.c ..."
  python3 - <<'PY'
import io

def read(p):
    with io.open(p, encoding='utf-8') as f:
        return f.read()

def write(p, s):
    with io.open(p, 'w', encoding='utf-8') as f:
        f.write(s)

def insert_before(path, anchor, block, guard):
    s = read(path)
    if guard in s:
        print("[prepare] %s already patched" % path)
        return
    if anchor not in s:
        print("[prepare][WARN] anchor not found in %s" % path)
        return
    s = s.replace(anchor, block + anchor, 1)
    write(path, s)
    print("[prepare] patched %s" % path)

# --- lib/Kconfig ---
block_lib = (
    "config LZ4K_COMPRESS\n\ttristate\n\n"
    "config LZ4K_DECOMPRESS\n\ttristate\n\n"
    "config LZ4KD_COMPRESS\n\ttristate\n\n"
    "config LZ4KD_DECOMPRESS\n\ttristate\n\n"
)
insert_before('lib/Kconfig', 'config ZSTD_COMPRESS', block_lib, 'LZ4KD_COMPRESS')

# --- crypto/Kconfig ---
block_crypto = (
    "config CRYPTO_LZ4K\n"
    "\ttristate \"LZ4K\"\n"
    "\tselect CRYPTO_ALGAPI\n"
    "\tselect CRYPTO_ACOMP2\n"
    "\tselect LZ4K_COMPRESS\n"
    "\tselect LZ4K_DECOMPRESS\n"
    "\thelp\n"
    "\t  LZ4K compression algorithm\n\n"
    "config CRYPTO_LZ4KD\n"
    "\ttristate \"LZ4KD\"\n"
    "\tselect CRYPTO_ALGAPI\n"
    "\tselect CRYPTO_ACOMP2\n"
    "\tselect LZ4KD_COMPRESS\n"
    "\tselect LZ4KD_DECOMPRESS\n"
    "\thelp\n"
    "\t  LZ4KD compression algorithm\n\n"
)
insert_before('crypto/Kconfig', 'config CRYPTO_ZSTD', block_crypto, 'CRYPTO_LZ4KD')

# --- crypto/Makefile ---
s = read('crypto/Makefile')
if 'lz4k.o' not in s:
    old = 'obj-$(CONFIG_CRYPTO_LZ4HC) += lz4hc.o'
    new = old + '\nobj-$(CONFIG_CRYPTO_LZ4K) += lz4k.o\nobj-$(CONFIG_CRYPTO_LZ4KD) += lz4kd.o'
    if old in s:
        write('crypto/Makefile', s.replace(old, new, 1))
        print('[prepare] patched crypto/Makefile')
    else:
        print('[prepare][WARN] crypto/Makefile anchor not found')
else:
    print('[prepare] crypto/Makefile already patched')

# --- drivers/block/zram/zcomp.c (backends[] 列表) ---
s = read('drivers/block/zram/zcomp.c')
if '"lz4kd"' not in s:
    add = (
        '#if IS_ENABLED(CONFIG_CRYPTO_LZ4K)\n\t"lz4k",\n#endif\n'
        '#if IS_ENABLED(CONFIG_CRYPTO_LZ4KD)\n\t"lz4kd",\n#endif\n'
    )
    idx = s.find('\tNULL\n};')
    if idx == -1:
        idx = s.find('NULL\n};')
    if idx == -1:
        print('[prepare][WARN] zcomp.c NULL anchor not found')
    else:
        write('drivers/block/zram/zcomp.c', s[:idx] + add + s[idx:])
        print('[prepare] patched zcomp.c')
else:
    print('[prepare] zcomp.c already patched')
PY
else
  echo "[prepare] 跳过 LZ4KD 移植（ENABLE_LZ4KD=$ENABLE_LZ4KD）"
fi

echo "[prepare] done"