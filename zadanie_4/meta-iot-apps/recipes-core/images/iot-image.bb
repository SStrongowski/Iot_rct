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
"

# nieskompresowany ext4 dla runqemu/QEMU (zapis zmian między startami)
IMAGE_FSTYPES:append = " ext4"
QB_DEFAULT_FSTYPE = "ext4"
