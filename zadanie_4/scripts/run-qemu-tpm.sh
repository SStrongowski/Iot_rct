#!/bin/bash
# Uruchamia obraz iot-image w QEMU z wirtualnym TPM 2.0 (swtpm).
# Stan TPM w TPM_DIR przetrwa restart płytki (jak prawdziwy układ).
set -eo pipefail

#FSTYPE="${FSTYPE:-}"
# zmienne dla iot-qemuarm64
#SETUP_DIR="${SETUP_DIR:-$HOME/yocto/bitbake-builds/iot-qemuarm64}"
#TPM_DIR="${TPM_DIR:-$HOME/yocto/swtpm-state}"

# zmienne  dla  iot-qemuarm64-secureboot
SETUP_DIR="${SETUP_DIR:-$HOME/yocto/bitbake-builds/iot-qemuarm64-secureboot}"
TPM_DIR="${TPM_DIR:-$HOME/yocto/swtpm-secureboot}"

# Dysk urządzenia: osobna kopia (jak prawdziwy nośnik płytki), build go nie nadpisuje.
# Dowiązanie w deploy przestawiane na kopię przed każdym startem; nowy dysk = rm tego pliku.
DEPLOY="$SETUP_DIR/build/tmp/deploy/images/iot-qemuarm64-secureboot"
LINK="$DEPLOY/iot-image-iot-qemuarm64-secureboot.rootfs.wic.qcow2"
DEVICE_DISK="${DEVICE_DISK:-$HOME/yocto/device/iot-image-device.wic.qcow2}"
if [ ! -f "$DEVICE_DISK" ]; then
    NEWEST=$(ls -t "$DEPLOY"/iot-image-iot-qemuarm64-secureboot.rootfs-*.wic.qcow2 | head -n 1)
    mkdir -p "$(dirname "$DEVICE_DISK")"
    cp "$NEWEST" "$DEVICE_DISK"
    echo "== nowy dysk urządzenia: $DEVICE_DISK (z $(basename "$NEWEST"))"
fi
ln -sfn "$DEVICE_DISK" "$LINK"
echo "== dysk urządzenia: $DEVICE_DISK"

mkdir -p "$TPM_DIR"

# zatrzymaj ewentualny poprzedni swtpm dla tego katalogu
pkill -f "swtpm socket.*${TPM_DIR}" || true
sleep 1

# swtpm: emulator układu TPM 2.0, komunikacja przez gniazdo unixowe
swtpm socket --tpm2 \
    --tpmstate dir="$TPM_DIR" \
    --ctrl type=unixio,path="$TPM_DIR/swtpm-sock" \
    --log file="$TPM_DIR/swtpm.log",level=20 \
    --daemon
sleep 1

# środowisko BitBake (runqemu)
source "$SETUP_DIR/build/init-build-env" > /dev/null

# urządzenie TPM na płytce: backend "emulator" (swtpm) + interfejs TIS
runqemu iot-image $FSTYPE nographic slirp qemuparams="\
-chardev socket,id=chrtpm,path=$TPM_DIR/swtpm-sock \
-tpmdev emulator,id=tpm0,chardev=chrtpm \
-device tpm-tis-device,tpmdev=tpm0"
