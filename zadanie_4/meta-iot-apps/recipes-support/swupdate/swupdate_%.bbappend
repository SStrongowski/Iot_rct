FILESEXTRAPATHS:prepend := "${THISDIR}/files:"
SRC_URI += "file://iot-swupdate.cfg"

# Demon SWUpdate niepotrzebny: aktualizacje tylko z wiersza poleceń (iot-update)
SYSTEMD_AUTO_ENABLE = "disable"
