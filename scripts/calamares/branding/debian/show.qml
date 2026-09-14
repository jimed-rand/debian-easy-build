import QtQuick 2.0;
import calamares.slideshow 1.0;

Presentation
{
    id: presentation

    function nextSlide() {
        presentation.goToNextSlide();
    }

    Timer {
        id: advanceTimer
        interval: 8000
        running: presentation.activatedInCalamares
        repeat: true
        onTriggered: nextSlide()
    }

    Slide
    {
        centeredText: qsTr( "Welcome to Debian GNU/Linux.\n\nYour installation is in progress.\n\nNotice: This ISO was built using Debian Easy Build, an unofficial community tool, and is not an official Debian Project release." )
    }

    Slide
    {
        centeredText: qsTr( "Unofficial Build Notice:\n\nThis media was generated with unofficial tooling. Software packages originate directly from official Debian mirrors, but this installer image is independently assembled." )
    }

    Slide
    {
        centeredText: qsTr( "Debian GNU/Linux provides a universal operating system built on free software principles, with official non-free firmware included for broad hardware compatibility." )
    }

    Slide
    {
        centeredText: qsTr( "The desktop environment on this installation was built using standard Debian tasksel metapackages." )
    }

    Slide
    {
        centeredText: qsTr( "Snapd is blocked by APT pinning policy to ensure a pure distribution package baseline. Native APT packages and Flatpak are supported." )
    }

    Slide
    {
        centeredText: qsTr( "Flatpak integration is pre-configured with Flathub, providing access to an extensive ecosystem of sandboxed applications." )
    }

    Slide
    {
        centeredText: qsTr( "Multimedia Support:\n\nIf deb-multimedia was enabled at build time, extended codecs, libraries, and multimedia utilities are pre-configured." )
    }

    Slide
    {
        centeredText: qsTr( "Server services: If SSH server or Cockpit web administration were selected, their services are disabled by default for live security and can be enabled with systemctl on your installed system." )
    }

    Slide
    {
        centeredText: qsTr( "The official Debian Linux kernel is installed with Debian firmware packages covering wireless, graphics, and audio hardware." )
    }

    Slide
    {
        centeredText: qsTr( "After copying the system, the installer removes live-session packages so the installed system remains clean." )
    }

    Slide
    {
        centeredText: qsTr( "Erase-disk installs use a GPT layout that boots both UEFI and legacy BIOS: a 1 MiB BIOS-boot partition, a 512 MiB EFI system partition, 4 GiB of swap, and the rest as root." )
    }

    Slide
    {
        centeredText: qsTr( "Full-disk encryption with LUKS2 is supported directly from the partitioning step with an unencrypted boot partition for GRUB." )
    }

    Slide
    {
        centeredText: qsTr( "Hybrid boot: the same image boots on UEFI firmware and legacy BIOS through GRUB only, without Syslinux or Isolinux." )
    }

    Slide
    {
        centeredText: qsTr( "When installation finishes, you will be prompted to restart. Remove the installation medium so the computer boots from the new disk." )
    }

    function onActivate() {
        presentation.currentSlide = 0;
    }

    function onLeave() {
    }
}
