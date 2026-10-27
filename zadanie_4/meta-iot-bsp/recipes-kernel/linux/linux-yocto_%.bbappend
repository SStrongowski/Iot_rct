# Opcje kernela dla układu TPM, zależne od maszyny (warstwa BSP).
FILESEXTRAPATHS:prepend := "${THISDIR}/files:"
SRC_URI:append:qemuarm64 = " file://tpm-tis-mmio.cfg"
LINUX_VERSION_EXTENSION:qemuarm64 = "-iot-v3"
