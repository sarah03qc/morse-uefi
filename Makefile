#  UEFI x64: flujo completo
#  - crea disco con ESP
#  - compila y enlaza BOOTX64.EFI
#  - copia a \EFI\BOOT
#  - arranca con QEMU + OVMF
# - ahora incorpora audio QEMU

# rutas de proyecto
SRC_DIR      := src
OUT_DIR      := build
IMG_DIR      := img
MNT_DIR      := mnt

# imagen "USB"
DISK_IMAGE   := $(abspath $(IMG_DIR)/disk.vhd)
DISK_SIZE    := 512M

# nombre estandar en la ESP
EFI_NAME     := BOOTX64.EFI

# fuentes/artefactos
ASM_SRC      := $(SRC_DIR)/morse.asm
OBJ_FILE     := $(OUT_DIR)/morse.obj
EFI_FILE     := $(OUT_DIR)/$(EFI_NAME)
OVMF_VARS    := $(OUT_DIR)/OVMF_VARS.fd

# herramientas
NASM := nasm
LINK := lld-link
QEMU  := qemu-system-x86_64

# audio QEMU
AUDIO_BACKEND ?= pa
AUDIO_ID      := ad0
QEMU_AUDIO    := -audiodev $(AUDIO_BACKEND),id=$(AUDIO_ID)
QEMU_PCSPK    := -machine pcspk-audiodev=$(AUDIO_ID)

# flags
NASMFLAGS    := -f win64
LDFLAGS      := -subsystem:efi_application -entry:morseMain

# OVMF: se autodetecta, pero se puede sobreescribir por linea de comando
OVMF_CODE    ?= $(shell find /usr/share -name "OVMF_CODE*.fd"  | head -n 1)
OVMF_VARS_SRC?= $(shell find /usr/share -name "OVMF_VARS*.fd"  | head -n 1)

.PHONY: all setup-disk create-partitions format-partitions mount-efi \
        remount compile execute cleanup clean info help

# flujo inicial completo
all: setup-disk create-partitions format-partitions mount-efi

# crear archivo de disco + asociar loop
setup-disk:
	@echo "==> creando $(DISK_IMAGE) de $(DISK_SIZE)"
	@mkdir -p "$(IMG_DIR)"
	fallocate -l "$(DISK_SIZE)" "$(DISK_IMAGE)"
	@echo "==> asociando loop device"
	sudo losetup -fP "$(DISK_IMAGE)"
	@echo "loop actual:"
	@losetup -a | grep "$(DISK_IMAGE)" || true

# particiones GPT: p1=ESP (FAT32 100MiB), p2=FAT32 resto
create-partitions:
	@echo "==> particionando (GPT + ESP)"
	$(eval LOOP := $(shell losetup -j "$(DISK_IMAGE)" | head -n1 | cut -d: -f1))
	@if [ -z "$(LOOP)" ]; then echo "No hay loop para $(DISK_IMAGE)"; exit 1; fi
	sudo parted "$(LOOP)" --script mklabel gpt
	sudo parted "$(LOOP)" --script mkpart EFI fat32 1MiB 101MiB
	sudo parted "$(LOOP)" --script set 1 esp on
	sudo parted "$(LOOP)" --script mkpart primary fat32 101MiB 100%

# formatear p1 y p2
format-partitions:
	@echo "==> formateando p1/p2"
	$(eval LOOP := $(shell losetup -j "$(DISK_IMAGE)" | head -n1 | cut -d: -f1))
	@if [ -z "$(LOOP)" ]; then echo "No hay loop para $(DISK_IMAGE)"; exit 1; fi
	sudo mkfs.vfat -F32 "$(LOOP)p1"
	sudo mkfs.vfat -F32 "$(LOOP)p2"

# montar la ESP en mnt y crear \EFI\BOOT
mount-efi:
	@echo "==> montando ESP en $(MNT_DIR)"
	$(eval LOOP := $(shell losetup -j "$(DISK_IMAGE)" | head -n1 | cut -d: -f1))
	@if [ -z "$(LOOP)" ]; then echo "No hay loop para $(DISK_IMAGE)"; exit 1; fi
	sudo mkdir -p "$(MNT_DIR)"
	sudo mount "$(LOOP)p1" "$(MNT_DIR)"
	sudo mkdir -p "$(MNT_DIR)/EFI/BOOT"

# volver a montar si se perdio el mount
remount:
	@echo "==> remontando ESP"
	$(eval LOOP := $(shell losetup -j "$(DISK_IMAGE)" | head -n1 | cut -d: -f1))
	@if [ -z "$(LOOP)" ]; then sudo losetup -fP "$(DISK_IMAGE)"; fi
	$(eval LOOP := $(shell losetup -j "$(DISK_IMAGE)" | head -n1 | cut -d: -f1))
	@if mountpoint -q "$(MNT_DIR)"; then sudo umount "$(MNT_DIR)"; fi
	sudo mkdir -p "$(MNT_DIR)"
	sudo mount "$(LOOP)p1" "$(MNT_DIR)"
	@echo "ESP -> $(MNT_DIR)"

# compilar y copiar a \EFI\BOOT\BOOTX64.EFI
compile: $(EFI_FILE)
	@if ! mountpoint -q "$(MNT_DIR)"; then \
	  echo "La ESP no está montada en $(MNT_DIR). Ejecuta 'make remount' primero."; \
	  exit 1; \
	fi
	@echo "==> copiando $(EFI_FILE) -> $(MNT_DIR)/EFI/BOOT/$(EFI_NAME)"
	sudo cp "$(EFI_FILE)" "$(MNT_DIR)/EFI/BOOT/$(EFI_NAME)"

# reglas de build
$(EFI_FILE): $(OBJ_FILE)
	@mkdir -p "$(OUT_DIR)"
	$(LINK) $(LDFLAGS) -out:"$@" "$(OBJ_FILE)"

$(OBJ_FILE): $(ASM_SRC)
	@mkdir -p "$(OUT_DIR)"
	$(NASM) $(NASMFLAGS) "$<" -o "$@"

# arrancar en QEMU
execute:
	@echo "==> preparando ejecución"
	- sudo umount "$(MNT_DIR)" 2>/dev/null || true
	$(eval LOOP := $(shell losetup -j "$(DISK_IMAGE)" | head -n1 | cut -d: -f1))
	@if [ -n "$(LOOP)" ]; then sudo losetup -d "$(LOOP)"; fi
	@if [ -z "$(OVMF_CODE)" ] || [ ! -f "$(OVMF_CODE)" ]; then \
	  echo "No encontré OVMF_CODE. Instala 'ovmf' o pásalo por línea de comando."; \
	  exit 1; \
	fi
	@if [ ! -f "$(OVMF_VARS)" ]; then mkdir -p "$(OUT_DIR)"; cp "$(OVMF_VARS_SRC)" "$(OVMF_VARS)"; fi
	@echo "OVMF_CODE: $(OVMF_CODE)"
	@echo "OVMF_VARS: $(OVMF_VARS)"
	$(QEMU) -m 512M -cpu qemu64 \
	  -drive if=pflash,format=raw,readonly=on,file="$(OVMF_CODE)" \
	  -drive if=pflash,format=raw,file="$(OVMF_VARS)" \
	  -drive file="$(DISK_IMAGE)",format=raw
	  $(QEMU) -m 512M -cpu qemu64 \
	  $(QEMU_AUDIO) $(QEMU_PCSPK) \
	  -drive if=pflash,format=raw,readonly=on,file="$(OVMF_CODE)" \
	  -drive if=pflash,format=raw,file="$(OVMF_VARS)" \
	  -drive file="$(DISK_IMAGE)",format=raw

# desmontar/soltar loop
cleanup:
	- sudo umount "$(MNT_DIR)" 2>/dev/null || true
	$(eval LOOP := $(shell losetup -j "$(DISK_IMAGE)" | head -n1 | cut -d: -f1))
	@if [ -n "$(LOOP)" ]; then sudo losetup -d "$(LOOP)"; fi
	@echo "ok"

# limpieza completa (incluye imagen)
clean: cleanup
	rm -rf "$(OUT_DIR)" "$(IMG_DIR)"
	- sudo rmdir "$(MNT_DIR)" 2>/dev/null || true

# info de estado util
info:
	@echo "DISK_IMAGE: $(DISK_IMAGE)"
	@losetup -j "$(DISK_IMAGE)" || echo "sin loop"
	@if [ -f "$(DISK_IMAGE)" ]; then sudo fdisk -l "$(DISK_IMAGE)" 2>/dev/null || true; fi
	@echo "ESP montada?: " && (mountpoint -q "$(MNT_DIR)" && echo "sí" || echo "no")
	@echo "EFI_FILE: $(EFI_FILE)  [$$( [ -f "$(EFI_FILE)" ] && echo OK || echo MISSING )]"
	@echo "OVMF_CODE: $(OVMF_CODE)"
	@echo "OVMF_VARS_SRC: $(OVMF_VARS_SRC)"

help:
	@echo "Targets:"
	@echo "  all                -> crea imagen + particiona + formatea + monta"
	@echo "  remount            -> vuelve a montar la ESP"
	@echo "  compile            -> build + copia a \\EFI\\BOOT\\$(EFI_NAME)"
	@echo "  execute            -> arranca QEMU con OVMF"
	@echo "  cleanup / clean    -> desmonta / borra artefactos"
	@echo "Tips:"
	@echo "  make remount compile execute"
	@echo "  make execute OVMF_CODE=/ruta/OVMF_CODE_4M.fd OVMF_VARS_SRC=/ruta/OVMF_VARS_4M.fd"
