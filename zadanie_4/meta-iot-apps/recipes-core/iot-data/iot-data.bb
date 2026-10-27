SUMMARY = "Konfiguracja zaszyfrowanej partycji danych (LUKS + TPM2)"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = "file://crypttab file://data.mount"
S = "${UNPACKDIR}"

inherit allarch systemd

SYSTEMD_SERVICE:${PN} = "data.mount"
SYSTEMD_AUTO_ENABLE = "enable"

do_install() {
    install -d ${D}${sysconfdir} ${D}${systemd_system_unitdir} ${D}/data
    install -m 0644 ${UNPACKDIR}/crypttab   ${D}${sysconfdir}/crypttab
    install -m 0644 ${UNPACKDIR}/data.mount ${D}${systemd_system_unitdir}/data.mount
}

FILES:${PN} = "${sysconfdir}/crypttab ${systemd_system_unitdir}/data.mount /data"
RDEPENDS:${PN} = "systemd-crypt cryptsetup"
