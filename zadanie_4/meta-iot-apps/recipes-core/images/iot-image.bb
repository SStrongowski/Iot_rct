SUMMARY = "Obraz projektu IoT: TPM 2.0 i PKCS#11"
LICENSE = "MIT"

inherit core-image

IMAGE_FEATURES += "ssh-server-openssh"

IMAGE_INSTALL:append = " \
    tpm2-tools \
    tpm2-tss \
    tpm2-openssl \
    tpm2-pkcs11 \
    tpm2-pkcs11-tools \
    opensc \
    libp11 \
    openssl-bin \
    iot-env \
"

# nieskompresowany ext4 dla runqemu/QEMU (zapis zmian między startami)
IMAGE_FSTYPES:append = " ext4"
#QB_DEFAULT_FSTYPE = "ext4"

# narzędzia TEE tylko na płytkach z OP-TEE (deklaracja w MACHINE_FEATURES, warstwa BSP)
IMAGE_INSTALL:append = " ${@bb.utils.contains('MACHINE_FEATURES', 'optee', 'optee-client optee-test optee-os-ta', '', d)}"
