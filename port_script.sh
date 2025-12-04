#!/bin/bash

# $1 = Папка с распакованной Base (Alioth)
# $2 = Папка с распакованной Port (Donor)
BASE_DIR=$1
PORT_DIR=$2
WORK_DIR=$(pwd)/working

mkdir -p $WORK_DIR/vendor_base
mkdir -p $WORK_DIR/vendor_port
mkdir -p $WORK_DIR/system_port
mkdir -p $WORK_DIR/product_port

echo "=== НАЧАЛО ПОРТИРОВАНИЯ (ALGORITHM FROM VIDEO) ==="

# ---------------------------------------------
# 1. ЗАМЕНА ОБРАЗОВ (Cross-Port Logic)
# ---------------------------------------------
echo "[1/6] Замена основных образов..."
# Удаляем system, product, system_ext из базы
rm -f "$BASE_DIR/system.img" "$BASE_DIR/product.img" "$BASE_DIR/system_ext.img" "$BASE_DIR/mi_ext.img"

# Копируем их из порта
cp "$PORT_DIR/system.img" "$BASE_DIR/"
cp "$PORT_DIR/product.img" "$BASE_DIR/"
cp "$PORT_DIR/system_ext.img" "$BASE_DIR/"
# mi_ext часто вызывает проблемы, лучше не копировать если не уверен, но в видео его распаковывают.
if [ -f "$PORT_DIR/mi_ext.img" ]; then
    cp "$PORT_DIR/mi_ext.img" "$BASE_DIR/"
fi

# ---------------------------------------------
# 2. РАСПАКОВКА ДЛЯ ПАТЧИНГА
# ---------------------------------------------
echo "[2/6] Распаковка образов для патчинга..."

# Функция распаковки (поддерживает erofs и ext4 через 7z)
extract_img() {
    img_file=$1
    out_dir=$2
    echo "Extracting $img_file to $out_dir..."
    # Пробуем как EROFS
    extract.erofs -i "$img_file" -x -o "$out_dir" 2>/dev/null
    if [ -z "$(ls -A $out_dir)" ]; then
        # Если пусто, пробуем как EXT4 через 7zip
        7z x "$img_file" -o"$out_dir" > /dev/null
    fi
}

extract_img "$BASE_DIR/vendor.img" "$WORK_DIR/vendor_base"
extract_img "$PORT_DIR/vendor.img" "$WORK_DIR/vendor_port"
# Нам нужно распаковать System и Product порта для деблоата и фиксов
extract_img "$PORT_DIR/system.img" "$WORK_DIR/system_port"
extract_img "$PORT_DIR/product.img" "$WORK_DIR/product_port"

# ---------------------------------------------
# 3. PATCHING VENDOR (Как в видео)
# ---------------------------------------------
echo "[3/6] Патчинг Vendor..."

# A. Копирование Selinux contexts
if [ -f "$WORK_DIR/vendor_port/etc/selinux/vendor_property_contexts" ]; then
    cp "$WORK_DIR/vendor_port/etc/selinux/vendor_property_contexts" "$WORK_DIR/vendor_base/etc/selinux/"
    echo " -> Copied vendor_property_contexts"
fi

# B. Копирование Overlays (Критично для яркости и рамок)
if [ -d "$WORK_DIR/vendor_port/overlay" ]; then
    cp -r "$WORK_DIR/vendor_port/overlay/"* "$WORK_DIR/vendor_base/overlay/"
    echo " -> Copied Overlays"
fi

# C. Правка build.prop в Vendor (Fingerprint fix, etc)
# В видео меняют ro.apex.updatable и отключают persist.sys.binary.xml
VENDOR_PROP="$WORK_DIR/vendor_base/build.prop"

# Добавляем или меняем строки
echo " -> Patching Vendor build.prop..."
if grep -q "ro.apex.updatable" "$VENDOR_PROP"; then
    sed -i 's/ro.apex.updatable=.*/ro.apex.updatable=true/' "$VENDOR_PROP"
else
    echo "ro.apex.updatable=true" >> "$VENDOR_PROP"
fi

if grep -q "persist.sys.binary.xml" "$VENDOR_PROP"; then
    sed -i 's/persist.sys.binary.xml=.*/persist.sys.binary.xml=false/' "$VENDOR_PROP"
else
    echo "persist.sys.binary.xml=false" >> "$VENDOR_PROP"
fi

# ---------------------------------------------
# 4. PATCHING SYSTEM (Build.prop)
# ---------------------------------------------
echo "[4/6] Патчинг System..."
SYSTEM_PROP="$WORK_DIR/system_port/system/build.prop"

# Если файла нет в system/build.prop, он может быть в корне system
if [ ! -f "$SYSTEM_PROP" ]; then SYSTEM_PROP="$WORK_DIR/system_port/build.prop"; fi

echo " -> Patching System build.prop..."
# Дублируем фиксы из видео
if grep -q "ro.apex.updatable" "$SYSTEM_PROP"; then
    sed -i 's/ro.apex.updatable=.*/ro.apex.updatable=true/' "$SYSTEM_PROP"
else
    echo "ro.apex.updatable=true" >> "$SYSTEM_PROP"
fi

# ---------------------------------------------
# 5. DEBLOAT (Удаление мусора как в видео)
# ---------------------------------------------
echo "[5/6] Debloating (Удаление тяжелых приложений)..."

# Список папок для удаления (из видео и опыта для уменьшения размера)
DEBLOAT_DIRS=(
    "app/MiuiVideo"
    "app/MiuiVideoPlayer"
    "app/MiuiGallery"
    "priv-app/MiuiGallery"
    "app/MSA"
    "priv-app/MSA"
    "app/MiuiDaemon"
    "priv-app/MiuiDaemon"
    "app/HybridAccessory"
    "data-app/*" # Удаляем предустановленный мусор
)

for target in "${DEBLOAT_DIRS[@]}"; do
    rm -rf "$WORK_DIR/product_port/product/$target"
    rm -rf "$WORK_DIR/system_port/system/$target"
    # Также проверяем корень, если структура другая
    rm -rf "$WORK_DIR/product_port/$target"
    rm -rf "$WORK_DIR/system_port/$target"
done
echo " -> Debloat complete."

# ---------------------------------------------
# 6. REPACKING (Сборка образов обратно)
# ---------------------------------------------
echo "[6/6] Сборка образов (Repack)..."

# Установка конфигурации FS (важно для EROFS)
# Мы используем упрощенный repack, так как на GHA сложно сохранить оригинальные fs_config контексты без root.
# Для простого порта часто достаточно стандартных прав.

# Repack Vendor
mkfs.erofs -zlz4hc "$BASE_DIR/vendor.img" "$WORK_DIR/vendor_base"
echo " -> Vendor repacked."

# Repack System
# System обычно лежит внутри папки system при распаковке
if [ -d "$WORK_DIR/system_port/system" ]; then
    mkfs.erofs -zlz4hc "$BASE_DIR/system.img" "$WORK_DIR/system_port/system"
else
    mkfs.erofs -zlz4hc "$BASE_DIR/system.img" "$WORK_DIR/system_port"
fi
echo " -> System repacked."

# Repack Product
if [ -d "$WORK_DIR/product_port/product" ]; then
    mkfs.erofs -zlz4hc "$BASE_DIR/product.img" "$WORK_DIR/product_port/product"
else
    mkfs.erofs -zlz4hc "$BASE_DIR/product.img" "$WORK_DIR/product_port"
fi
echo " -> Product repacked."

# Очистка рабочей папки
rm -rf "$WORK_DIR"

echo "=== ПОРТИРОВАНИЕ ЗАВЕРШЕНО ==="
