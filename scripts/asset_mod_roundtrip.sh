#!/usr/bin/env bash
# ============================================================================
# 《烽沙》(MOProject) 资产模组闭环脚本 —— 已实测跑通 (2026-10-13)
#
# 流程: 解包(游戏 Paks) → 改(JSON) → 回写(uasset) → 打包(IoStore) → 校验
#
# 依赖:
#   retoc.exe      D:/FengSha_UI_Upgrade/tools/retoc/retoc.exe
#   UAssetGUI.exe  D:/FengSha_UI_Upgrade/tools/UAssetGUI.exe
#   usmap 映射      %LOCALAPPDATA%/UAssetGUI/Mappings/Game.usmap
#                  (且 config.json 里 PreferredMappings = "Game"，注意不带扩展名)
#
# 用法:
#   ./asset_mod_roundtrip.sh extract  "<资产名过滤>"      # 解包到 ./work
#   ./asset_mod_roundtrip.sh tojson   "<uasset 相对路径>"  # uasset -> JSON
#   ./asset_mod_roundtrip.sh fromjson "<uasset 相对路径>"  # JSON -> uasset
#   ./asset_mod_roundtrip.sh pack     "<模组名>"           # 打包成 <模组名>_P.{utoc,ucas,pak}
#   ./asset_mod_roundtrip.sh verify   "<模组名>"           # 校验容器
#   ./asset_mod_roundtrip.sh install  "<模组名>"           # 复制进 ~mods
# ============================================================================
set -e

RT="D:/FengSha_UI_Upgrade/tools/retoc/retoc.exe"
UAG="D:/FengSha_UI_Upgrade/tools/UAssetGUI.exe"
PAKS="D:/STEAM/steamapps/common/mo/MOProject/Content/Paks"
WORK="./work"          # legacy 资产目录（可编辑）
TMPJ="$(pwd)/_edit.json"
VER="UE5_6"
MAP="Game"             # 不带扩展名！

cmd="$1"; shift || true

case "$cmd" in
  extract)
    # INPUT 必须是 .utoc 或含 .utoc 的目录；OUTPUT 是目录（要打包就必须是目录）
    FILTER="${1:-}"
    if [ -n "$FILTER" ]; then
      "$RT" to-legacy "$PAKS" "$WORK" --version "$VER" -f "$FILTER"
    else
      "$RT" to-legacy "$PAKS" "$WORK" --version "$VER"
    fi
    echo "[OK] 解包到 $WORK"
    ;;

  tojson)
    # ⚠️ UAssetGUI 不认 Git Bash 的 /tmp 路径，必须传 Windows 绝对路径
    REL="$1"
    ( cd "$(dirname "$UAG")" && ./UAssetGUI.exe tojson \
        "$(cygpath -w "$WORK/$REL" 2>/dev/null || echo "$WORK/$REL")" \
        "$(cygpath -w "$TMPJ" 2>/dev/null || echo "$TMPJ")" "$VER" "$MAP" )
    echo "[OK] JSON -> $TMPJ  (编辑这个文件里的数值)"
    ;;

  fromjson)
    REL="$1"
    # ⚠️ 官方语法：fromjson <source.json> <destination.uasset> [mappings name]
    #    **没有 engine version 参数**！多传 VER_UE5_6 会被当成 mappings 名，
    #    找不到映射 → 静默失败（exit=0 但文件不写）。
    ( cd "$(dirname "$UAG")" && ./UAssetGUI.exe fromjson \
        "$(cygpath -w "$TMPJ" 2>/dev/null || echo "$TMPJ")" \
        "$(cygpath -w "$WORK/$REL" 2>/dev/null || echo "$WORK/$REL")" "$MAP" )
    echo "[OK] 已回写 $WORK/$REL"
    ;;

  pack)
    NAME="${1:-MyMod}"
    # 打包方向是 to-zen（Legacy -> Zen），产出 .utoc + .ucas + .pak 三件套
    "$RT" to-zen "$WORK" "./${NAME}_P.utoc" --version "$VER"
    echo "[OK] 打包完成:"
    ls -la "./${NAME}_P.utoc" "./${NAME}_P.ucas" "./${NAME}_P.pak" 2>/dev/null || true
    ;;

  verify)
    NAME="${1:-MyMod}"
    "$RT" verify "./${NAME}_P.utoc"
    echo "[OK] 容器合法"
    ;;

  install)
    NAME="${1:-MyMod}"
    mkdir -p "$PAKS/~mods"
    cp "./${NAME}_P.utoc" "./${NAME}_P.ucas" "./${NAME}_P.pak" "$PAKS/~mods/"
    echo "[OK] 已安装到 $PAKS/~mods/"
    ;;

  *)
    echo "用法: $0 {extract|tojson|fromjson|pack|verify|install} [参数]"
    exit 1
    ;;
esac
