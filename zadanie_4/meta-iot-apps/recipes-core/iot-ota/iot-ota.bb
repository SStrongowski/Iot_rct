SUMMARY = "OTA na urządzeniu: watchdog systemd, instalacja na nieaktywny slot, zatwierdzanie"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = "file://10-watchdog.conf \
           file://iot-update \
           file://iot-boot-ok.service \
	   file://iot.cfg \
	   file://iot-boot-ok \
	   file://swupdate-signing.crt"

# Przepis bez archiwum: źródła to pojedyncze pliki rozpakowane wprost do UNPACKDIR
S = "${UNPACKDIR}"

inherit systemd allarch
SYSTEMD_SERVICE:${PN} = "iot-boot-ok.service"
RDEPENDS:${PN} = "swupdate libubootenv-bin"

do_install() {
    install -d ${D}${systemd_unitdir}/system.conf.d
    install -m 0644 ${UNPACKDIR}/10-watchdog.conf ${D}${systemd_unitdir}/system.conf.d/
    install -d ${D}${bindir}
    install -m 0755 ${UNPACKDIR}/iot-update ${D}${bindir}/
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${UNPACKDIR}/iot-boot-ok.service ${D}${systemd_system_unitdir}/
    install -d ${D}${sysconfdir}/swupdate
    install -m 0644 ${UNPACKDIR}/swupdate-signing.crt ${D}${sysconfdir}/swupdate/
    install -m 0644 ${UNPACKDIR}/iot.cfg ${D}${sysconfdir}/swupdate/
    install -m 0755 ${UNPACKDIR}/iot-boot-ok ${D}${bindir}/
    echo "${IOT_SW_VERSION}" > ${D}${sysconfdir}/iot-sw-version
}
FILES:${PN} = "${systemd_unitdir}/system.conf.d/10-watchdog.conf \
               ${bindir}/iot-update \
               ${systemd_system_unitdir}/iot-boot-ok.service \
	       ${sysconfdir}/swupdate/iot.cfg \
	       ${sysconfdir}/swupdate/swupdate-signing.crt \
	       ${bindir}/iot-boot-ok \
	       ${sysconfdir}/iot-sw-version"
