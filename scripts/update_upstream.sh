#!/usr/bin/env bash
# 上游同步器：把仓库里「vendored」（随仓库走的）补丁/脚本刷到上游最新，并打印
# 所有外部组件的当前版本。
#
# 用法:
#   scripts/update_upstream.sh            # 刷新 vendored 文件 + 打印版本表
#   scripts/update_upstream.sh --check    # 只比对不写；有漂移退出码 1
#
# vendored（会被写入仓库）:
#   kernel_patches/net_enhance/0001-net-tcp-backport-BBRv3-to-android14-6.1.patch
#   security_patch/*（CVE-2026-43499 / 53163 修复链）
#   scripts/finasu_compat/extract_manager_cert.py
#   scripts/ksu_post_setup.sh
#
# 运行时拉取（不 vendored，构建时 clone 分支 HEAD，天然跟随最新）:
#   myflavor/ReKernel-X@main            -> LKM 源码
#   LyraVoid/FinaSU@master              -> 驱动
#   gitlab simonpunk/susfs4ksu@gki-*    -> finasu 用的 SUSFS 新代次补丁
#   cctv18/susfs4oki@oki-*              -> 其它变体用的 SUSFS 旧代次补丁
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$HERE"

MODE="${1:-refresh}"
TOKEN="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
HAVE_CURL=0
command -v curl >/dev/null 2>&1 && HAVE_CURL=1

auth() { [ -n "$TOKEN" ] && printf 'Authorization: token %s' "$TOKEN"; }

# get <url> <out>  —— 走 curl，带重试。
# 注意不要用 --retry-all-errors：鉴权失败也会被重试 5 次，一个 401 能拖掉好几分钟。
# 也不要把 token 发给 raw.githubusercontent.com —— 那个域名不带鉴权也能取公开仓库，
# 带上反而在某些网络下被代理拦成 401。
get() {
  local url="$1" out="$2"
  if [ "$HAVE_CURL" = 1 ]; then
    case "$url" in
      https://api.github.com/*)
        if [ -n "$TOKEN" ]; then
          curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 20 --max-time 120 \
            -H "$(auth)" "$url" -o "$out"
        else
          curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 20 --max-time 120 \
            "$url" -o "$out"
        fi
        ;;
      *)
        curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 20 --max-time 120 \
          "$url" -o "$out"
        ;;
    esac
  else
    wget -q --tries=3 --timeout=120 "$url" -O "$out"
  fi
}

# gh_raw <owner/repo> <branch> <path> <out>
gh_raw() {
  get "https://raw.githubusercontent.com/$1/$2/$3" "$4" 2>/dev/null && return 0
  # raw.githubusercontent 在某些网络下 TLS 失败，退 API + raw accept
  if [ -n "$TOKEN" ]; then
    get "https://api.github.com/repos/$1/contents/$3?ref=$2" "$4" 2>/dev/null && return 0
    # get() 不带 Accept: raw，这里补一次
    curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 20 --max-time 120 \
      -H "$(auth)" -H "Accept: application/vnd.github.raw" \
      "https://api.github.com/repos/$1/contents/$3?ref=$2" -o "$4"
  else
    return 1
  fi
}

# gh_head <owner/repo> <branch> —— 输出短 sha
gh_head() {
  local out
  out="$(curl -fsSL --retry 3 --connect-timeout 20 --max-time 60 ${TOKEN:+-H "$(auth)"} \
        "https://api.github.com/repos/$1/commits/$2" 2>/dev/null)"
  printf '%s' "$out" | python3 -c 'import json,sys
try:
    d=json.load(sys.stdin)
except Exception:
    print("?"); raise SystemExit
print(d.get("sha","?")[:10])' 2>/dev/null || echo "?"
}

# gitlab_head <project> <branch>
gitlab_head() {
  local out
  out="$(curl -fsSL --retry 3 --connect-timeout 20 --max-time 60 \
        "https://gitlab.com/api/v4/projects/$(python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=''))" "$1")/repository/branches/$2" 2>/dev/null)"
  printf '%s' "$out" | python3 -c 'import json,sys
try:
    d=json.load(sys.stdin)
except Exception:
    print("?"); raise SystemExit
print(d.get("commit",{}).get("id","?")[:10])' 2>/dev/null || echo "?"
}

# ---------------------------------------------------------------- vendored 清单
BBR_FILE="0001-net-tcp-backport-BBRv3-to-android14-6.1.patch"
BBR_DEST="kernel_patches/net_enhance/$BBR_FILE"
SEC_FILES="apply_cve_2026_43499.sh
cve-2026-43499-guards.patch
cve-2026-43499-rtmutex-5.10.patch
cve-2026-43499-rtmutex-5.15.patch
cve-2026-43499-rtmutex-6.1-6.6.patch
cve-2026-43499-rtmutex-6.12.patch
scoped_guard_cleanup.h
scoped_guard_compiler_clang.txt
scoped_guard_compiler_cleanup.txt
scoped_guard_spinlock_guards.txt"

TMP="$(mktemp -d 2>/dev/null || echo ./.upstream_tmp)"
mkdir -p "$TMP"
trap 'rm -rf "$TMP" 2>/dev/null || true' EXIT

STALE=0
say() { printf '%s\n' "$*"; }

refresh_one() {  # <src repo> <branch> <path> <dest> <mode:exec|plain>
  local repo="$1" br="$2" path="$3" dest="$4" kind="$5"
  local tmp="$TMP/$(echo "$path" | tr '/' '_')"
  if ! gh_raw "$repo" "$br" "$path" "$tmp"; then
    say "  !! 拉取失败: $repo@$br:$path"
    STALE=1
    return 1
  fi
  if [ ! -s "$tmp" ]; then
    say "  !! 空文件: $repo@$br:$path"
    STALE=1
    return 1
  fi
  # 行尾统一成 LF：仓库里 .gitattributes 是 eol=lf，写进去 CRLF 会让 GitHub 端变成整文件改动
  python3 - "$tmp" <<'PY'
import io, sys
p = sys.argv[1]
b = io.open(p, 'rb').read().replace(b'\r\n', b'\n')
io.open(p, 'wb').write(b)
PY
  if [ "$kind" = "exec" ]; then chmod +x "$tmp"; fi
  if ! cmp -s "$tmp" "$dest"; then
    say "  -> 更新 $dest"
    [ "$MODE" != "--check" ] && cp "$tmp" "$dest"
    STALE=1
  fi
  return 0
}

say "== vendored 补丁/脚本"
refresh_one WildKernels/kernel_patches main "common/bbrv3/$BBR_FILE" "$BBR_DEST" plain
for f in $SEC_FILES; do
  kind=plain
  case "$f" in *.sh) kind=exec ;; esac
  refresh_one LxyaoX/AnyKernel3 main "security_patch/$f" "security_patch/$f" "$kind"
done
refresh_one LxyaoX/AnyKernel3 main "scripts/finasu_compat/extract_manager_cert.py" \
  "scripts/finasu_compat/extract_manager_cert.py" exec
refresh_one LxyaoX/AnyKernel3 main "scripts/ksu_post_setup.sh" "scripts/ksu_post_setup.sh" exec

# 69_hide_stuff.patch 也是 vendored（构建时从本仓库 raw 取）
refresh_one cctv18/oppo_oplus_realme_sm8650 main "other_patch/69_hide_stuff.patch" \
  "other_patch/69_hide_stuff.patch" plain

say ""
say "== 运行时组件（构建时 clone 分支 HEAD）"
printf '  %-34s %s\n' "myflavor/ReKernel-X@main"        "$(gh_head myflavor/ReKernel-X main)"
printf '  %-34s %s\n' "LyraVoid/FinaSU@master"          "$(gh_head LyraVoid/FinaSU master)"
printf '  %-34s %s\n' "LxyaoX/AnyKernel3@main"          "$(gh_head LxyaoX/AnyKernel3 main)"
printf '  %-34s %s\n' "WildKernels/kernel_patches@main" "$(gh_head WildKernels/kernel_patches main)"
printf '  %-34s %s\n' "cctv18/susfs4oki@oki-android14-6.1" "$(gh_head cctv18/susfs4oki oki-android14-6.1)"
printf '  %-34s %s\n' "gitlab simonpunk/susfs4ksu@gki-android14-6.1" "$(gitlab_head simonpunk/susfs4ksu gki-android14-6.1)"

# ---------------------------------------------------------------- zram 补丁版本
# 这三个补丁都带内核侧适配，不能简单按上游 tag 覆盖：
#   lz4  -> 去掉了 malloc/stdio，加了 wrkmem 参数、EXPORT_SYMBOL、arm64 汇编解压入口
#   zstd -> 裁剪成 decompress-only + 内核内存接口
#   lz4kd-> 三方补丁，按内核小版本分目录（other/zram/zram_patch/<kver>/）
say ""
say "== zram 相关补丁"
ZRAM_DIR="$HERE/zram_patch"
if [ -d "$ZRAM_DIR" ]; then
  VERS="$(python3 "$HERE/scripts/zram_patch_versions.py" "$ZRAM_DIR")"
  LZ4_CUR="$(printf '%s\n' "$VERS" | awk 'NR==1{print $1}')"
  ZSTD_CUR="$(printf '%s\n' "$VERS" | awk 'NR==2{print $1}')"
  LZ4_UP="$(curl -fsSL --retry 3 --connect-timeout 20 --max-time 60 ${TOKEN:+-H "$(auth)"} \
    "https://api.github.com/repos/lz4/lz4/releases/latest" 2>/dev/null | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("tag_name","?").lstrip("v"))
except Exception: print("?")')"
  ZSTD_UP="$(curl -fsSL --retry 3 --connect-timeout 20 --max-time 60 ${TOKEN:+-H "$(auth)"} \
    "https://api.github.com/repositories/29759715/releases/latest" 2>/dev/null | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("tag_name","?").lstrip("v"))
except Exception: print("?")')"
  printf '  %-10s 补丁 %-8s 上游最新 %-8s\n' "lz4"  "${LZ4_CUR:-?}"  "${LZ4_UP:-?}"
  printf '  %-10s 补丁 %-8s 上游最新 %-8s\n' "zstd" "${ZSTD_CUR:-?}" "${ZSTD_UP:-?}"
  printf '  %-10s 构建时 clone %-8s\n' "lz4kd" "SukiSU-Nova/SukiSU_patch@main"
  if [ -n "$LZ4_UP" ] && [ "$LZ4_UP" != "?" ] && [ "$LZ4_CUR" != "$LZ4_UP" ]; then
    say "  注意: lz4 上游已到 $LZ4_UP，本地补丁是 $LZ4_CUR；这个补丁带内核侧适配"
    say "        （wrkmem / EXPORT_SYMBOL / arm64 汇编入口），换版本要重做适配再替换"
    if [ "${ZRAM_STRICT:-0}" = "1" ]; then STALE=1; fi
  fi
else
  say "  （当前目录没有 zram_patch/，跳过）"
fi

say ""
if [ "$MODE" = "--check" ] && [ "$STALE" = 1 ]; then
  say "有上游漂移（上面标 -> 的文件）：跑 scripts/update_upstream.sh 刷新后再提交"
  exit 1
fi
say "vendored 文件已是最新"
