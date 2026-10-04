# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).


## [Unreleased]
 - **Breaking: safer defaults.** The app now defaults to sharing only `share`, `media` and `backup`, with access limited to Home Assistant's own network (`auto`). **If you never changed the app's options, these defaults apply when you update:** `config`, `ssl`, `addons`/`local_apps` and `addon_configs`/`app_configs` stop being shared, and clients outside Home Assistant's subnet (VPN, other VLANs) are refused. Add them back in the options if you need them. If you saved your options before, they are kept.
 - New `auto` value for `authorized_ips`: Home Assistant's own network subnet, worked out at each start (from the Supervisor, or the host's routing table). It can be combined with other entries. If it can't be worked out, the app refuses to start rather than guess.
 - Option names and descriptions now appear on the app's Configuration tab.
 - The app now has an icon and logo in Home Assistant. Thanks to @andremmfaria for designing them in PR #2.
 - Follows Home Assistant's rename of add-ons to apps, as the official Samba app does: the `addons` and `addon_configs` folders are now `local_apps` and `app_configs`. Saved settings are renamed automatically. Clients can still mount `/addons` and `/addon_configs`, but these paths are deprecated; switch to `/local_apps` and `/app_configs`. `/config` is unchanged. Uses the current Supervisor folder mappings (`homeassistant_config`, `local_apps`, `all_app_configs`). Thanks to @andremmfaria for raising the mapping change in PR #2.
 - **Remount may be needed:** these legacy paths are now served by new exports, so a client that has `/addons` or `/addon_configs` mounted when you update may report a "stale file handle". Unmount and mount it again (ideally at `/local_apps` or `/app_configs`). Other mounts are unaffected.
 - Rebuilt on Debian trixie with nfs-ganesha 9.14 from trixie-backports (was 4.3 on bookworm). Thanks to @morgaroth for the upgrade in PR #4.
 - Fixes "Remote I/O error" when NFS 4.1/4.2 clients check the share right after writing to it.
 - nfs-ganesha 9.14 is rebuilt with an upstream fix (commit 6c076b4ea9) for a bug that set a file's group to `root` (0), or failed with "Invalid argument", when a client changed a file's group or owner (for example `chown` or `rsync -a`).
 - Fewer privileges: the app no longer needs SYS_ADMIN, and it now runs under its own AppArmor profile (previously AppArmor was disabled). The security rating improves from 2 to 4.
 - The app now requests the SYS_RESOURCE capability so Ganesha can register as an IO flusher, which avoids stalls under memory pressure. If the capability is unavailable it still starts. SYS_RESOURCE doesn't affect the rating.
 - Dropped armhf, armv7 and i386 (no longer supported by Home Assistant since 2025.12).
 - New optional `log_level` setting (default `WARN`) for troubleshooting. Debug levels also print the generated ganesha.conf.
 - The log now always starts with the app and NFS-Ganesha versions, so a pasted log shows exactly what is running.
 - Ganesha now logs straight to the app log, so the reason for a startup failure is no longer lost. The app exits with Ganesha's exit code when it stops, so crashes show as errors.
 - Quieter startup: at `WARN` and below, the app hides the ~45 lines NFS-Ganesha prints about log-level changes at every start.
 - Stopping the app now shuts NFS-Ganesha down cleanly, instead of it being force-killed after 10 seconds.
 - Documentation: support links now point to the Home Assistant Community thread (GitHub Discussions isn't enabled), plus small fixes (PR #8).

## [1.2.1] - 2026-09-30
 - Security fix - An empty `export_folders` list exported the container's root directory (`/`) read-write to authorized clients. The app now refuses to start and logs why when there are no folders to share, and empty folder names are ignored.
 - Security fix - Export folder names are now checked against the supported list (config, ssl, addons, addon_configs, backup, share, media); anything else is skipped with a warning.
 - An empty `authorized_ips` list produced an invalid configuration. The app now refuses to start with a clear message, and blank entries are ignored.
 - If none of the selected folders exist, the app now refuses to start instead of running with nothing shared.
 - Internal: configuration generation moved to `gen-config.sh`, with automated tests and CI. The generated configuration is unchanged for valid options, apart from the "Starting D-Bus..." log line now appearing after the "Exporting" lines.

## [1.2.0] - 2026-03-15
 - Removed NFSv3 support. The addon is now NFSv4-only. NFSv3 was non-functional due to a conflict with the rpcbind service already running on the HAOS host.

## [1.1.0] - 2026-03-13
 - Security fix - Previously all exports were published RW regardless of client IPs.  This has now been fixed to a default deny configuation.

## [1.0.1] - 2026-03-04
 - Fixed missing addon_configs export

## [1.0.0] - 2026-02-08
 - Initial Release

### Added
- Initial release
- NFSv3 and NFSv4 support
- IP-based access control
- Automatic export of HA directories
