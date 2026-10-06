# Changelog

## [2.0.0] - YYYY-MM-DD

This release marks a fairly major overhaul of the NFS Ganesha app. The base has been rebuilt on Debian trixie with nfs-ganesha 9.14 from trixie-backports (plus an additional backported commit), which fixes a number of NFS-level bugs. The configuration has been overhauled and brought up to current Home Assistant standards, including the share names. And I now publish the app as prebuilt images for supported platforms, so installs and updates should be quicker.

On the downside, this also means that support for armhf, armv7 and i386 has been dropped.

A large amount of development has also gone into automated testing and builds, which should streamline future releases.

### Breaking changes
 - **Dropped support for armhf, armv7 and i386** as these are no longer supported by Home Assistant (since 2025.12).
 - **Supervisor 2026.07.1 or later required.** The Supervisor normally updates itself automatically; check under Settings → System → Updates if you've held it back.
 - **Safer defaults.** For new installations, the app only shares `share`, `media` and `backup` by default, and only with clients on Home Assistant's own network (`auto`). **If you never changed and saved the app's configuration options, these defaults will apply when you update:**
   - `config`, `ssl`, `addons`/`local_apps` and `addon_configs`/`app_configs` stop being shared, and
   - clients outside Home Assistant's subnet (e.g. VPN, other VLANs) are refused. Add them back in the options if you need them.
   - Again, this only applies if you never changed and saved the app's settings.
 - **Because of these changes, Home Assistant won't install this update automatically,** even with auto-update on. You will need to trigger the update manually once you've read these notes.
 - **Remount may be needed.** Each shared folder now has a fixed export id, so adding or removing other folders no longer breaks existing mounts. Updating may change a folder's id once, and a client that has `/addons` or `/addon_configs` mounted, or any folder of an install that didn't share all seven 1.2.x folders, may report a "stale file handle". Unmount the share (on the client) and mount it again to resolve.
 - **`authorized_ips` entries are now syntax checked.** An entry that isn't an IP address, subnet, hostname or host pattern, `@netgroup`, `auto` or `*` (for example a typo like `192.168.1.0/33`) stops the app from starting, with the entry named in the log, instead of producing a configuration that could silently match no one.

### Fixes
 - **Legacy share names have been updated.** `addons` and `addon_configs` are now `local_apps` and `app_configs` respectively. Saved settings are updated automatically, and clients can still mount `/addons` and `/addon_configs`, but these paths are deprecated; you should switch to `/local_apps` and `/app_configs`. `/config` remains unchanged. Thanks to @andremmfaria for raising the folder mapping change in PR #2.
 - **Fixed "Remote I/O error".** NFS 4.1/4.2 clients that checked the share immediately after writing to it could get a "Remote I/O error".
 - **Fixed changing a file's group or owner.** Previously, changing a file's group or owner over NFS (for example `chown` or `rsync -a`) set the group to `root` (0) or failed with "Invalid argument".
 - **Changes made on the Home Assistant side are visible immediately.** Configuration edits, new backups and files added by other apps now reach NFS clients straight away. Before, clients would see old content, miss new files and still list deleted ones for up to a minute.
 - **Improved logging.**
   - **Startup failure reason is no longer lost.** NFS-Ganesha now logs straight to the app log. The app exits with NFS-Ganesha's exit code when it stops, so crashes show as errors.
   - **Folders that can't be shared are logged.** If NFS-Ganesha can't share one of the selected folders (for example one on an unsupported filesystem), the log now says so (`[ERROR] /media is NOT being shared ...`) while the other folders keep working. Before, clients just got "No such file or directory".
   - **Additional startup information logged.** The log now always starts with the app and NFS-Ganesha versions, so a pasted log shows exactly what is running.
 - **Stopping the app shuts NFS-Ganesha down cleanly**, including while it's still starting up, instead of it being force-killed after 10 seconds.

### New
 - **New `auto` option for `authorized_ips`.** Setting `authorized_ips` to `auto` sets it, each time the app starts, to the same subnet as Home Assistant itself (based on the Supervisor's network information or the host's routing table). It can also be combined with other entries. If it can't be determined within 60 seconds of starting, the app refuses to start.
 - **Watchdog support.** A health check is configured that makes an NFS call every 30 seconds, so with the Watchdog switch on, Home Assistant restarts the app if NFS stops responding.
 - **Optional `log_level` setting.** A configurable `log_level` in the app's configuration, for troubleshooting (default `WARN`).
 - **Warning for overly broad `authorized_ips`.** A warning is logged at startup when `authorized_ips` is too broad (`*`, a host pattern, a subnet wider than `/16`, or more than one subnet). The Documentation's new "Security" section explains why: every allowed client should be trusted with all of Home Assistant's data, not just the shared folders.
 - **Shared folder pick list.** The shared folders are picked from a list instead of typed in, and the options have names and descriptions on the Configuration tab.
 - **A new icon and logo.** Thanks to @andremmfaria for designing them in PR #2.

### Under the hood
 - The app is now installed from prebuilt images (amd64 and aarch64) instead of being built on your device, so installs and updates are faster and you run exactly the build that passed our tests.
 - Rebuilt on Debian trixie with nfs-ganesha 9.14 from trixie-backports (was 4.3 on bookworm). Thanks to @morgaroth for the upgrade in PR #4.
 - nfs-ganesha is built from Debian's own 9.14 source package with one upstream fix backported: [commit 6c076b4](https://github.com/nfs-ganesha/nfs-ganesha/commit/6c076b4ea9a963249987daa158808e33910e86e3), which fixes a buffer overflow and missing null-termination in `name2id()`. This is what caused the group and owner bug listed under Fixes.
 - Fewer privileges: the app no longer needs SYS_ADMIN, and it now runs under its own AppArmor profile (previously AppArmor was disabled). The security rating improves from 2 to 4.
 - The app requests the SYS_RESOURCE capability so NFS-Ganesha can register as an IO flusher, which avoids stalls under memory pressure. It still starts without it. SYS_RESOURCE doesn't affect the security rating.
 - Quieter startup: at `WARN` and below, the app hides the ~45 lines NFS-Ganesha prints about log-level changes at every start.

### Documentation
 - New "Security" section, and the defaults and `auto` are explained.
 - Windows: its built-in NFS client only supports NFSv3, so the docs now recommend the official Samba app (or a third-party NFSv4 client).
 - Support links now point to the Home Assistant Community thread (GitHub Discussions isn't enabled), plus small fixes (PR #8).

## [1.2.1] - 2026-09-30
 - Security fix - An empty `export_folders` list exported the container's root directory (`/`) read-write to authorized clients. The app now refuses to start and logs why when there are no folders to share, and empty folder names are ignored.
 - Security fix - Export folder names are now checked against the supported list (config, ssl, addons, addon_configs, backup, share, media); anything else is skipped with a warning.
 - An empty `authorized_ips` list produced an invalid configuration. The app now refuses to start with a clear message, and blank entries are ignored.
 - If none of the selected folders exist, the app now refuses to start instead of running with nothing shared.
 - Internal: configuration generation moved to `gen-config.sh`, with automated tests and CI. The generated configuration is unchanged for valid options, apart from the "Starting D-Bus..." log line now appearing after the "Exporting" lines.

## [1.2.0] - 2026-03-15
 - Removed NFSv3 support. The addon is now NFSv4-only. NFSv3 was non-functional due to a conflict with the rpcbind service already running on the HAOS host.

## [1.1.0] - 2026-03-13
 - Security fix - Previously all exports were published RW regardless of client IPs.  This has now been fixed to a default deny configuration.

## [1.0.1] - 2026-03-04
 - Fixed missing addon_configs export

## [1.0.0] - 2026-02-08
 - Initial Release

### Added
- Initial release
- NFSv3 and NFSv4 support
- IP-based access control
- Automatic export of HA directories
