#!/bin/bash
# Uruchamia obraz iot-image w QEMU z wirtualnym TPM 2.0 (swtpm).
# Stan TPM w TPM_DIR przetrwa restart płytki (jak prawdziwy układ).
set -eo pipefail

FSTYPE="${FSTYPE:-}"
# zmienne dla iot-qemuarm64
#SETUP_DIR="${SETUP_DIR:-$HOME/yocto/bitbake-builds/iot-qemuarm64}"
#TPM_DIR="${TPM_DIR:-$HOME/yocto/swtpm-state}"

# zmienne  dla  iot-qemuarm64-secureboot
SETUP_DIR="${SETUP_DIR:-$HOME/yocto/bitbake-builds/iot-qemuarm64-secureboot}"
TPM_DIR="${TPM_DIR:-$HOME/yocto/swtpm-secureboot}"

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
