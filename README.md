# FlashPort

**A native macOS app for flashing Samsung firmware in Download Mode — an Odin alternative for Mac.**

FlashPort imports official Samsung firmware packages (ZIP or extracted folder), maps the BL/AP/CP/CSC images against the device's PIT partition table, and flashes them over USB — with data preservation support, exactly like Odin's HOME_CSC workflow.

![FlashPort main interface](docs/screenshot.png)

*Une version française est disponible plus bas : [Version française](#version-française).*

---

## ⚠️ Disclaimer

Flashing firmware can permanently damage a device if the firmware, model, or region is wrong. **Use only official firmware matching the exact Samsung model (e.g. SM-A137F) and region.** You use this software at your own risk. Never commit or redistribute Samsung firmware files.

## Features

- **Native Odin protocol engine written in Swift** — handshake, PIT read, session management, file transfer sequences. Handles images **larger than 4 GB** (64-bit sizes), which Heimdall 1.4.2 silently truncates.
- **Data-preserving flash** — honors the package's `meta-data/download-list.txt` like Odin does: with HOME_CSC, images such as `misc.bin`, `param.bin`, `md_udc.img` and `userdata.img` are automatically excluded so user data survives the flash.
- **Firmware safety checks** — model code and bootloader binary (rev) validation from archive names, downgrade blocking, duplicate partition detection.
- **Automatic device detection** in Download Mode (Samsung VID `0x04E8`).
- **LZ4 decompression** — native `lz4` CLI when available, pure-Swift fallback decoder otherwise.
- **Optional Heimdall backend** for devices/setups where it works well (see limits below).
- Live log console, session report export, PIT export, flash history.

## Requirements

- macOS 14.6 or later.
- Xcode 16+ to build.
- Optional: [Heimdall](https://glassechidna.com.au/heimdall/) (`brew install heimdall`) for the fast backend.

## Basic workflow

1. Put the Samsung device in Download Mode (Vol Up + Vol Down with USB cable plugged in, then Vol Up).
2. Open FlashPort — the device is detected automatically.
3. Import the full firmware ZIP (e.g. from SamFW/Frija) or an extracted folder.
4. Choose the data mode:
   - **Effacer données** (wipe) — uses CSC, includes `userdata`.
   - **Sans effacement** (preserve data) — uses HOME_CSC and the package's download-list.
5. Flash. The PIT is read automatically when needed; images over 4 GB (`super`) are flashed by the native Swift engine.
6. First boot after a flash can take several minutes.

## Backends and known limits

| Backend | Notes |
|---|---|
| Native Swift engine | Validated end-to-end on real hardware (Galaxy A13 SM-A137F, MediaTek). 64-bit file sizes, long finalization timeouts after large images, single-session flashing. Uses IOUSBHost bulk transfer when macOS allows it, serial fallback otherwise (slow). |
| Heimdall 1.4.2 | Fast, but **truncates files larger than 4 GB** and chained `--resume` sessions are unreliable on recent bootloaders. FlashPort automatically switches to the native engine when needed. |

Heimdall is **not** bundled. FlashPort looks for it in the app bundle, `$PATH`, Homebrew/MacPorts locations, and Heimdall Suite installs.

## Development

Open `FlashPort.xcodeproj` and build the `FlashPort` scheme. Unit tests cover PIT parsing/serialization, Odin packet layout, TAR/`.tar.md5` reading (including GNU base-256 sizes), LZ4 decoding, firmware↔PIT mapping, download-list filtering, and Heimdall command generation.

## License

[MIT](LICENSE). The Odin protocol implementation is based on the publicly documented protocol from the open-source [Heimdall](https://github.com/Benjamin-Dobell/Heimdall) project (MIT).

---

## Version française

**FlashPort est une application macOS native pour flasher des firmwares Samsung en mode Download — une alternative à Odin pour Mac.**

### ⚠️ Avertissement

Flasher un firmware peut endommager définitivement un téléphone si le firmware, le modèle ou la région sont incorrects. **Utilisez uniquement un firmware officiel correspondant exactement au modèle Samsung (ex. SM-A137F) et à la région.** Vous utilisez ce logiciel à vos risques et périls. Ne commitez jamais de fichiers firmware Samsung.

### Fonctionnalités

- **Moteur du protocole Odin natif en Swift** — gère les images de **plus de 4 Go** (tailles 64 bits), que Heimdall 1.4.2 tronque silencieusement.
- **Flash avec conservation des données** — respecte le `meta-data/download-list.txt` du package comme Odin : avec HOME_CSC, `misc.bin`, `param.bin`, `md_udc.img` et `userdata.img` sont exclus automatiquement pour préserver les données.
- **Garde-fous** — vérification du modèle et du binary (anti-downgrade), détection des doublons de partition.
- **Détection automatique** du téléphone en mode Download, décompression LZ4, console de logs, export de rapport et du PIT, historique des flashs.
- **Backend Heimdall optionnel** (non fourni, `brew install heimdall`).

### Utilisation

1. Mettez le téléphone en mode Download (Vol + et Vol − câble branché, puis Vol +).
2. Ouvrez FlashPort — le téléphone est détecté automatiquement.
3. Importez le ZIP firmware complet ou un dossier extrait.
4. Choisissez le mode de données : **Effacer données** (CSC) ou **Sans effacement** (HOME_CSC, données conservées).
5. Flashez. Le PIT est lu automatiquement ; les images de plus de 4 Go (`super`) passent par le moteur Swift natif.
6. Le premier démarrage après flash peut prendre plusieurs minutes.

### Licence

[MIT](LICENSE). L'implémentation du protocole Odin s'appuie sur le protocole documenté par le projet open source [Heimdall](https://github.com/Benjamin-Dobell/Heimdall) (MIT).
