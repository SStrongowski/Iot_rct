SUMMARY = "Montowanie partycji startowej FAT w /boot/firmware"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = "file://boot-firmware.mount"
inherit systemd allarch

SYSTEMD_SERVICE:${PN} = "boot-firmware.mount"

do_install() {
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${UNPACKDIR}/boot-firmware.mount ${D}${systemd_system_unitdir}/
}
FILES:${PN} += "${systemd_system_unitdir}/boot-firmware.mount"
