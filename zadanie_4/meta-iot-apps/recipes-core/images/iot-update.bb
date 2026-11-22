SUMMARY = "Aktualizacja OTA: obraz systemu dla slotu A/B"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = "file://sw-description"

inherit swupdate

# Obraz systemu pakowany do .swu
IMAGE_DEPENDS = "iot-image"
SWUPDATE_IMAGES = "iot-image"
SWUPDATE_IMAGES_FSTYPES[iot-image] = ".rootfs.ext4.gz"
