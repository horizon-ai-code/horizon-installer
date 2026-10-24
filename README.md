# Horizon AI Installer

Standalone interactive installer for Horizon AI. Users do not need the source
repository, a compose file, or Docker Compose.

## Contents

- `INSTALL.txt` - instructions for installing the prebuilt images
- `BUILD-FROM-SOURCE.txt` - instructions for building from source
- `linux/install.sh` - Linux installer
- `windows/install.cmd` - Windows double-click launcher
- `windows/install.ps1` - Windows PowerShell installer

## Requirements

- Docker Engine or Docker Desktop running Linux containers
- Internet access for the first installation
- Optional GPU mode: NVIDIA GPU with 4 GB+ VRAM and Docker GPU support

## Quick start

Linux:

```bash
bash linux/install.sh
```

Windows:

Double-click `windows/install.cmd`, or run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\windows\install.ps1
```

The installer detects Docker and the GPU, recommends CPU or GPU mode, pulls the
prebuilt images from GHCR, starts the containers, and opens:

```text
http://localhost:3000
```

## Build from source

See `BUILD-FROM-SOURCE.txt` for the full clone, model download, Docker build,
and container run instructions.

## Notes

- The installer uses direct `docker run` commands, not Docker Compose.
- Existing Horizon containers are recreated during updates.
- The Docker data volume is preserved.
- Installer logs are written to the user profile, not the installation media.
