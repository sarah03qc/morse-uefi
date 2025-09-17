#  UEFI x64: flujo completo con soporte USB
#  - crea disco con ESP (imagen o USB físico)
#  - compila y enlaza BOOTX64.EFI
#  - copia a \EFI\BOOT
#  - arranca con QEMU + OVMF o USB físico
#  - incorpora audio QEMU

# rutas de proyecto
SRC_DIR      := src
OUT_DIR      := build
IMG_DIR      := img
MNT_DIR      := mnt

# configuración de modo: image (default) o usb
TARGET_MODE  ?= image

# imagen "USB" virtual para QEMU
DISK_IMAGE   := $(abspath $(IMG_DIR)/disk.vhd)
DISK_SIZE    := 512M

# USB físico (solo para TARGET_MODE=usb)
USB_DEVICE   ?= /dev/sdX

# nombre estándar en la ESP
EFI_NAME     := BOOTX64.EFI

# fuentes/artefactos
ASM_SRC      := $(SRC_DIR)/morse.asm
OBJ_FILE     := $(OUT_DIR)/morse.obj
EFI_FILE     := $(OUT_DIR)/$(EFI_NAME)
OVMF_VARS    := $(OUT_DIR)/OVMF_VARS.fd

# herramientas
NASM := nasm
LINK := lld-link
QEMU := qemu-system-x86_64

# audio QEMU
AUDIO_BACKEND ?= pa
AUDIO_ID      := ad0
QEMU_AUDIO    := -audiodev $(AUDIO_BACKEND),id=$(AUDIO_ID)
QEMU_PCSPK    := -machine pcspk-audiodev=$(AUDIO_ID)

# flags
NASMFLAGS    := -f win64
LDFLAGS      := -subsystem:efi_application -entry:morseMain

# OVMF: se autodetecta, pero se puede sobreescribir por línea de comando
OVMF_CODE    ?= $(shell find /usr/share -name "OVMF_CODE*.fd"  | head -n 1)
OVMF_VARS_SRC?= $(shell find /usr/share -name "OVMF_VARS*.fd"  | head -n 1)

.PHONY: all setup-disk create-partitions format-partitions mount-efi \
        remount compile execute cleanup clean info help \
        setup-usb install-usb usb-all run-usb

# FLUJO PRINCIPAL 
# flujo inicial completo (modo imagen por defecto)
all: 
ifeq ($(TARGET_MODE),image)
	@$(MAKE) setup-disk create-partitions format-partitions mount-efi
else
	@echo "Para modo USB usa: make usb-all TARGET_MODE=usb USB_DEVICE=/dev/sdX"
endif

# MODO IMAGEN (original) 
# crear archivo de disco + asociar loop
setup-disk:
ifeq ($(TARGET_MODE),image)
	@echo "==> creando $(DISK_IMAGE) de $(DISK_SIZE)"
	@mkdir -p "$(IMG_DIR)"
	fallocate -l "$(DISK_SIZE)" "$(DISK_IMAGE)"
	@echo "==> asociando loop device"
	sudo losetup -fP "$(DISK_IMAGE)"
	@echo "loop actual:"
	@losetup -a | grep "$(DISK_IMAGE)" || true
else
	@echo "setup-disk solo funciona en TARGET_MODE=image"
	@exit 1
endif

# particiones GPT: p1=ESP (FAT32 100MiB), p2=FAT32 resto
create-partitions:
ifeq ($(TARGET_MODE),image)
	@echo "==> particionando (GPT + ESP)"
	$(eval LOOP := $(shell losetup -j "$(DISK_IMAGE)" | head -n1 | cut -d: -f1))
	@if [ -z "$(LOOP)" ]; then echo "No hay loop para $(DISK_IMAGE)"; exit 1; fi
	sudo parted "$(LOOP)" --script mklabel gpt
	sudo parted "$(LOOP)" --script mkpart EFI fat32 1MiB 101MiB
	sudo parted "$(LOOP)" --script set 1 esp on
	sudo parted "$(LOOP)" --script mkpart primary fat32 101MiB 100%
else
	@echo "create-partitions solo funciona en TARGET_MODE=image"
	@exit 1
endif

# formatear p1 y p2
format-partitions:
ifeq ($(TARGET_MODE),image)
	@echo "==> formateando p1/p2"
	$(eval LOOP := $(shell losetup -j "$(DISK_IMAGE)" | head -n1 | cut -d: -f1))
	@if [ -z "$(LOOP)" ]; then echo "No hay loop para $(DISK_IMAGE)"; exit 1; fi
	sudo mkfs.vfat -F32 "$(LOOP)p1"
	sudo mkfs.vfat -F32 "$(LOOP)p2"
else
	@echo "format-partitions solo funciona en TARGET_MODE=image"
	@exit 1
endif

# montar la ESP en mnt y crear \EFI\BOOT
mount-efi:
ifeq ($(TARGET_MODE),image)
	@echo "==> montando ESP en $(MNT_DIR)"
	$(eval LOOP := $(shell losetup -j "$(DISK_IMAGE)" | head -n1 | cut -d: -f1))
	@if [ -z "$(LOOP)" ]; then echo "No hay loop para $(DISK_IMAGE)"; exit 1; fi
	sudo mkdir -p "$(MNT_DIR)"
	sudo mount "$(LOOP)p1" "$(MNT_DIR)"
	sudo mkdir -p "$(MNT_DIR)/EFI/BOOT"
else
	@echo "mount-efi solo funciona en TARGET_MODE=image"
	@exit 1
endif

# volver a montar si se perdió el mount (solo imagen)
remount:
ifeq ($(TARGET_MODE),image)
	@echo "==> remontando ESP"
	$(eval LOOP := $(shell losetup -j "$(DISK_IMAGE)" | head -n1 | cut -d: -f1))
	@if [ -z "$(LOOP)" ]; then sudo losetup -fP "$(DISK_IMAGE)"; fi
	$(eval LOOP := $(shell losetup -j "$(DISK_IMAGE)" | head -n1 | cut -d: -f1))
	@if mountpoint -q "$(MNT_DIR)"; then sudo umount "$(MNT_DIR)"; fi
	sudo mkdir -p "$(MNT_DIR)"
	sudo mount "$(LOOP)p1" "$(MNT_DIR)"
	@echo "ESP -> $(MNT_DIR)"
else
	@echo "remount solo funciona en TARGET_MODE=image"
	@exit 1
endif

# MODO USB
# preparar USB: particionar y formatear
setup-usb:
ifeq ($(TARGET_MODE),usb)
	@if [ -z "$(USB_DEVICE)" ] || [ "$(USB_DEVICE)" = "/dev/sdX" ]; then \
		echo " ADVERTENCIA: especificar el USB real con USB_DEVICE=/dev/sdX"; \
		echo "   Ejemplo: make setup-usb TARGET_MODE=usb USB_DEVICE=/dev/sdb"; \
		exit 1; \
	fi
	@echo "==> Preparando USB en $(USB_DEVICE)"
	@echo "ESTO BORRARA TODO EL CONTENIDO DE $(USB_DEVICE)"
	@read -p "¿Continuar? (y/N): " confirm && [ "$$confirm" = "y" ]
	# desmontar particiones existentes
	-sudo umount $(USB_DEVICE)* 2>/dev/null || true
	sudo sync
	# crear tabla de particiones GPT
	sudo parted "$(USB_DEVICE)" --script mklabel gpt
	sudo parted "$(USB_DEVICE)" --script mkpart EFI fat32 1MiB 101MiB
	sudo parted "$(USB_DEVICE)" --script set 1 esp on
	sudo parted "$(USB_DEVICE)" --script mkpart primary fat32 101MiB 100%
	# formatear particiones
	sudo mkfs.vfat -F32 "$(USB_DEVICE)1"
	sudo mkfs.vfat -F32 "$(USB_DEVICE)2"
	@echo "==> USB preparado correctamente"
else
	@echo "Este target es solo para TARGET_MODE=usb"
	@exit 1
endif

# instalar en USB (compilar y copiar)
install-usb: $(EFI_FILE)
ifeq ($(TARGET_MODE),usb)
	@if [ -z "$(USB_DEVICE)" ] || [ "$(USB_DEVICE)" = "/dev/sdX" ]; then \
		echo "⚠️  Debes especificar USB_DEVICE=/dev/sdX"; \
		exit 1; \
	fi
	@echo "==> Instalando en USB $(USB_DEVICE)"
	# Montar la partición EFI
	sudo mkdir -p "$(MNT_DIR)"
	sudo mount "$(USB_DEVICE)1" "$(MNT_DIR)"
	# Crear estructura y copiar EFI
	sudo mkdir -p "$(MNT_DIR)/EFI/BOOT"
	sudo cp "$(EFI_FILE)" "$(MNT_DIR)/EFI/BOOT/$(EFI_NAME)"
	# Desmontar
	sudo umount "$(MNT_DIR)"
	sudo sync
	@echo "==> Instalación completada en USB"
else
	@echo "Este target es solo para TARGET_MODE=usb"
	@exit 1
endif

# flujo completo para USB
usb-all: setup-usb install-usb
	@echo "==> USB listo para bootear"

# COMPILACION 
# compilar y copiar a \EFI\BOOT\BOOTX64.EFI
compile: $(EFI_FILE)
ifeq ($(TARGET_MODE),image)
	@if ! mountpoint -q "$(MNT_DIR)"; then \
	  echo "La ESP no está montada en $(MNT_DIR). Ejecuta 'make remount' primero."; \
	  exit 1; \
	fi
	@echo "==> copiando $(EFI_FILE) -> $(MNT_DIR)/EFI/BOOT/$(EFI_NAME)"
	sudo cp "$(EFI_FILE)" "$(MNT_DIR)/EFI/BOOT/$(EFI_NAME)"
else
	@echo "Para USB usar: make install-usb TARGET_MODE=usb USB_DEVICE=/dev/sdX"
endif

# reglas de build
$(EFI_FILE): $(OBJ_FILE)
	@mkdir -p "$(OUT_DIR)"
	$(LINK) $(LDFLAGS) -out:"$@" "$(OBJ_FILE)"

$(OBJ_FILE): $(ASM_SRC)
	@mkdir -p "$(OUT_DIR)"
	$(NASM) $(NASMFLAGS) "$<" -o "$@"

#EJECUCION
# arrancar en QEMU (solo para imagenes)
execute:
ifeq ($(TARGET_MODE),image)
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
	  $(QEMU_AUDIO) $(QEMU_PCSPK) \
	  -drive if=pflash,format=raw,readonly=on,file="$(OVMF_CODE)" \
	  -drive if=pflash,format=raw,file="$(OVMF_VARS)" \
	  -drive file="$(DISK_IMAGE)",format=raw
else
	@echo "==> 'make execute' solo funciona en modo imagen"
	@echo "    Para USB, bootea físicamente desde $(USB_DEVICE)"
endif

# alias para run (compatibilidad)
run: execute

# UTILIDADES 
# desmontar/soltar loop
cleanup:
ifeq ($(TARGET_MODE),image)
	- sudo umount "$(MNT_DIR)" 2>/dev/null || true
	$(eval LOOP := $(shell losetup -j "$(DISK_IMAGE)" | head -n1 | cut -d: -f1))
	@if [ -n "$(LOOP)" ]; then sudo losetup -d "$(LOOP)"; fi
	@echo "cleanup imagen ok"
else
	- sudo umount "$(MNT_DIR)" 2>/dev/null || true
	- sudo rmdir "$(MNT_DIR)" 2>/dev/null || true
	@echo "cleanup USB ok"
endif

# limpieza completa (incluye imagen)
clean: cleanup
	rm -rf "$(OUT_DIR)" "$(IMG_DIR)"
	- sudo rmdir "$(MNT_DIR)" 2>/dev/null || true

# info de estado útil
info:
	@echo "Estado actual "
	@echo "TARGET_MODE: $(TARGET_MODE)"
ifeq ($(TARGET_MODE),image)
	@echo "DISK_IMAGE: $(DISK_IMAGE)"
	@losetup -j "$(DISK_IMAGE)" || echo "sin loop"
	@if [ -f "$(DISK_IMAGE)" ]; then sudo fdisk -l "$(DISK_IMAGE)" 2>/dev/null || true; fi
	@echo "ESP montada?: " && (mountpoint -q "$(MNT_DIR)" && echo "sí" || echo "no")
else
	@echo "USB_DEVICE: $(USB_DEVICE)"
	@if [ -n "$(USB_DEVICE)" ] && [ "$(USB_DEVICE)" != "/dev/sdX" ]; then \
		echo "Particiones USB:"; \
		sudo fdisk -l "$(USB_DEVICE)" 2>/dev/null | grep "^$(USB_DEVICE)" || echo "No se pudo leer"; \
	fi
	@echo "Montaje: $$(mountpoint -q "$(MNT_DIR)" 2>/dev/null && echo "$(MNT_DIR) montado" || echo "nada montado")"
endif
	@echo "EFI_FILE: $(EFI_FILE)  [$$( [ -f "$(EFI_FILE)" ] && echo OK || echo MISSING )]"
	@echo "OVMF_CODE: $(OVMF_CODE)"
	@echo "OVMF_VARS_SRC: $(OVMF_VARS_SRC)"

help:
	@echo "Makefile UEFI x64 - Soporte Imagen y USB"
	@echo ""
	@echo "MODO IMAGEN (por defecto):"
	@echo "  make all                    -> crear imagen + particiona + formatea + monta"
	@echo "  make remount               -> vuelve a montar la ESP"
	@echo "  make compile               -> build + copia a \\EFI\\BOOT\\$(EFI_NAME)"
	@echo "  make execute / run         -> arranca QEMU con OVMF"
	@echo ""
	@echo "MODO USB:"
	@echo "  make setup-usb TARGET_MODE=usb USB_DEVICE=/dev/sdX"
	@echo "                             -> particionar y formatear USB"
	@echo "  make install-usb TARGET_MODE=usb USB_DEVICE=/dev/sdX"
	@echo "                             -> compilar e instalar en USB"
	@echo "  make usb-all TARGET_MODE=usb USB_DEVICE=/dev/sdX"
	@echo "                             -> hacer todo para USB de una vez"
	@echo ""
	@echo "UTILIDADES:"
	@echo "  make info                  -> mostrar estado actual"
	@echo "  make cleanup / clean       -> desmonta / borra artefactos"
	@echo ""
	@echo "EJEMPLOS DE USO:"
	@echo "  # Flujo imagen (QEMU)"
	@echo "  make all && make compile && make execute"
	@echo ""
	@echo "  # Flujo USB (hardware real)"
	@echo "  lsblk  # identificar la USB"
	@echo "  make usb-all TARGET_MODE=usb USB_DEVICE=/dev/sdb"
	@echo "OPCIONES DE AUDIO:"
	@echo "  make execute AUDIO_BACKEND=pa     # PulseAudio (default)"
	@echo "  make execute AUDIO_BACKEND=alsa   # ALSA"
