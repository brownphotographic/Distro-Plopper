```
 ____  _     _               ____  _
|  _ \(_)___| |_ _ __ ___  |  _ \| | ___  _ __  _ __   ___ _ __
| | | | / __| __| '__/ _ \ | |_) | |/ _ \| '_ \| '_ \ / _ \ '__|
| |_| | \__ \ |_| | | (_) ||  __/| | (_) | |_) | |_) |  __/ |
|____/|_|___/\__|_|  \___/ |_|   |_|\___/| .__/| .__/ \___|_|
                                          |_|   |_|
```

**Export your whole Linux setup. Plop it onto a new distro.**

A rather useful, vibe coded, distro-hopping migration tool.

If it doesn't work, blame Claude.

---
## Disclaimer

> This script is provided as-is, **unsupported and unmaintained**. No warranty is given. No support is offered. You run this entirely at your own risk. The author accepts zero responsibility for data loss, system damage, corrupted configs, existential dread, or any other outcome resulting from use of this script.
>
> This is a hobby tool. Test it. Read what it does before you run it. Back up your data independently before doing anything irreversible.

---

## What it does

distro-plopper scans your current system and bundles everything into a portable export — then restores it on a fresh install with an interactive TUI (or plain text fallback).

**Export captures:**
- Package lists — pacman/apt/dnf/zypper explicit installs, AUR/foreign packages, Flatpak apps, AppImages, pip/pipx/npm globals
- App configs — `~/.config`, home dotfiles, `~/.local/share`
- Browser profiles (Firefox, Chrome, Brave, LibreWolf, and more)
- GNOME settings (dconf dump + extensions)
- SSH config and known_hosts (private keys intentionally excluded)
- User fonts
- Steam config and userdata (game files excluded)
- CUPS printer queues and PPDs
- TurboPrint config, ICC profiles, and license key
- DisplayCAL / ArgyllCMS ICC profiles and autostart loader
- NFS exports and fstab mount entries
- Systemd enabled services
- Hardware notes (GPU, loaded modules)
- Docker inventory (images/volumes/containers — no data)
- Crontab

**Import restores** all of the above in the right order — packages first, then configs — with interactive prompts at each stage.

---

## Requirements

- `bash`
- `whiptail` (recommended — provides the interactive menus; the script offers to install it if missing and falls back to plain text prompts without it)
- `pv` (optional — shows progress during archive/extract; falls back to a spinner without it)
- Root / `sudo` access for system-level restores (CUPS, TurboPrint, fonts to `/usr/share`)

---

## Usage

```bash
# Export this system
bash distro-plopper.sh --export

# Export to a specific location
bash distro-plopper.sh --export --output /mnt/usb/my-backup

# Export dry run — scan and report only, copy nothing
bash distro-plopper.sh --export --dry-run

# Import from a bundle directory
bash distro-plopper.sh --import --bundle ~/distro-plopper-20250101_120000

# Import from a .tar.gz archive
bash distro-plopper.sh --import --bundle ~/distro-plopper-20250101_120000.tar.gz

# Import dry run — show what would be done
bash distro-plopper.sh --import --bundle ~/bundle --dry-run
```

Run without arguments to get the interactive mode selector.

### Export options
| Flag | Description |
|------|-------------|
| `--dry-run` | Scan and report only, copy nothing |
| `--skip-browsers` | Skip browser profile backup |
| `--skip-flatpak-data` | Skip `~/.var/app` data |
| `--skip-steam` | Skip all Steam data |
| `--output DIR` | Output directory (default: `~/distro-plopper-TIMESTAMP`) |

### Import options
| Flag | Description |
|------|-------------|
| `--bundle PATH` | Path to export bundle dir or `.tar.gz` archive (required) |
| `--output DIR` | Directory for import log (default: same dir as bundle) |
| `--no-packages` | Skip package installation |
| `--no-configs` | Skip config/dotfile restore |
| `--no-gnome` | Skip GNOME/dconf restore |
| `--no-flatpak` | Skip Flatpak data restore |
| `--no-browsers` | Skip browser profile restore |
| `--no-fonts` | Skip font restore |
| `--no-ssh` | Skip SSH config restore |
| `--no-steam` | Skip Steam config restore |
| `--dry-run` | Show what would be done, do nothing |

---

## FAQ

### How is this different from just restoring a backup of my home folder?

Honest answer — for the config side, it's not dramatically different. If you have a full home folder backup, you already have everything in `~/.config`, `~/.local/share`, dotfiles, fonts, browser profiles, and Flatpak data. That covers probably 80% of what distro-plopper captures.

Where distro-plopper adds value:

- **Package reinstallation** — a home folder backup contains no package lists. distro-plopper saves your exact pacman/dnf/apt explicit installs, AUR packages, Flatpak app IDs, and pip/npm globals, and on import it actually installs them in the right order before dropping configs. Without the packages reinstalled first, restoring configs to a bare system is meaningless — the apps aren't there to read them.
- **System-level files** — a home folder backup misses everything outside `~`: `/etc/cups/`, `/etc/turboprint/`, `/etc/fstab` NFS entries, `/etc/pacman.conf` custom repos, GRUB params. These need root to access and live entirely outside your home.
- **Ordering and automation** — a home folder backup is just files. distro-plopper installs packages first, then drops configs, then handles TurboPrint, CUPS, and DisplayCAL in the right sequence with checks along the way. Doing that manually from a backup is tedious and error-prone.

The honest limitation — if you already keep a good home folder backup (Timeshift, rsync, Restic, Borg), distro-plopper's config capture is largely redundant. Its real value is the package list + reinstall automation + system files + ordering logic. Think of it less as a backup tool and more as a migration assistant — it knows what order to do things in on a fresh distro, which a raw file restore doesn't.

---

MIT License — Copyright (c) 2025 Rob Brown
