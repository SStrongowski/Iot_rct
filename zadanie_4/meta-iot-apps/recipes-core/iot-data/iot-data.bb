SUMMARY = "Zaszyfrowana partycja danych (LUKS + TPM2), polityka TPM z /persist"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = "file://crypttab \
	   file://data.mount \
	   file://persist.conf \
	   file://iot-data-pcrlock.conf"

S = "${UNPACKDIR}"

inherit allarch systemd

SYSTEMD_SERVICE:${PN} = "data.mount"
SYSTEMD_AUTO_ENABLE = "enable"

do_install() {
    install -d ${D}${sysconfdir} ${D}${systemd_system_unitdir} ${D}/data
    install -m 0644 ${UNPACKDIR}/crypttab   ${D}${sysconfdir}/crypttab
    install -m 0644 ${UNPACKDIR}/data.mount ${D}${systemd_system_unitdir}/data.mount
    install -d ${D}${sysconfdir}/systemd/system/systemd-cryptsetup@data.service.d
    install -m 0644 ${UNPACKDIR}/persist.conf ${D}${sysconfdir}/systemd/system/systemd-cryptsetup@data.service.d/
    install -d ${D}${nonarch_libdir}/tmpfiles.d
    install -m 0644 ${UNPACKDIR}/iot-data-pcrlock.conf ${D}${nonarch_libdir}/tmpfiles.d/
}

FILES:${PN} = "${sysconfdir}/crypttab \
	       ${systemd_system_unitdir}/data.mount \
	       /data \
	       ${sysconfdir}/systemd/system/systemd-cryptsetup@data.service.d/persist.conf \
	       ${nonarch_libdir}/tmpfiles.d/iot-data-pcrlock.conf \"
RDEPENDS:${PN} = "systemd-crypt cryptsetup"
