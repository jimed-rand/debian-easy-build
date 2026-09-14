# Build Hooks (Modloader)

Drop executable `.sh` scripts into these directories to customize the build
pipeline - similar to how game modloaders (Minecraft Forge, GTA SA CLEO)
discover and run mods from a folder.

## Hook Directories

| Directory      | Runs on       | When                                              |
|----------------|---------------|----------------------------------------------------|
| `pre-chroot/`  | Host machine  | After debootstrap, **before** entering the chroot  |
| `chroot/`      | Inside chroot | During `install_pkg`, **after** packages are installed and customized |

## How It Works

1. Place your script in the appropriate directory (`pre-chroot/` or `chroot/`).
2. Make it executable: `chmod +x hooks/pre-chroot/my-hook.sh`.
3. Scripts are discovered and executed in **sorted filename order** (like mod
   load order). Use numeric prefixes to control ordering:
   ```
   hooks/
     pre-chroot/
       00-copy-skel-files.sh
       10-add-custom-repo.sh
     chroot/
       00-install-extra-packages.sh
       50-configure-services.sh
   ```
4. Each hook receives the full set of `TARGET_*` environment variables, so it
   can inspect the current build configuration.
5. A failing hook (non-zero exit) **aborts the build** - just like a broken mod
   crashes the game. Guard optional operations with `|| true` if you want them
   to be non-fatal.

## Pre-Chroot Hooks

These run on the **host** with access to the workspace. Useful for:
- Copying files into the chroot tree (e.g. populate `/etc/skel`).
- Adding custom APT repository keys.
- Patching configuration files before chroot entry.

Available extra variable:
- `WORKSPACE_CHROOT` - absolute path to the chroot root on the host.

Example (`hooks/pre-chroot/00-copy-skel.sh`):
```bash
#!/bin/bash
# Copy custom user skeleton files into the chroot.
cp -a /path/to/my-skel/. "$WORKSPACE_CHROOT/etc/skel/"
echo "=====> [hook] Copied custom skel files"
```

## Chroot Hooks

These run **inside the chroot** as root. Useful for:
- Installing additional packages (`apt-get install -y ...`).
- Enabling/disabling systemd services.
- Writing configuration files.

Example (`hooks/chroot/00-install-extras.sh`):
```bash
#!/bin/bash
# Install htop and neofetch inside the live image.
apt-get install -y htop neofetch
echo "=====> [hook] Installed htop and neofetch"
```

## Tips

- Keep hooks idempotent - they may run again if you re-run a build stage.
- Non-executable files and files not ending in `.sh` are ignored.
- The hooks directory can be overridden with `--hooks-dir=PATH`.
