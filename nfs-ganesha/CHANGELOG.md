# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).


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
