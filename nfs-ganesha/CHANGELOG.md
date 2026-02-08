# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [2.3.0] - 2026-02-08

### Added
- User-selectable list of folders to export via NFS
- Support for multiple authorized IPs/subnets (array format)
- `addon_configs` folder to list of exportable folders
- NFSv4 `Only_Numeric_Owners` setting for better UID mapping
- Comprehensive documentation

### Changed
- Configuration now uses `authorized_ips` (plural, array) instead of `authorized_ip` (singular)
- All mapped folders now explicitly request read-write access (`:rw`)
- Default authorized IPs now include all private network ranges instead of `*`

### Fixed
- Fixed read-only filesystem issue by ensuring container mounts are read-write
- Fixed UID mapping showing files as `nobody:nogroup` instead of `root:root`
- Fixed rpcbind startup failure not preventing addon from starting
- Improved error handling and logging

## [2.2.0] - 2026-01-31

### Fixed
- Fixed rpcbind startup failure that could cause addon to crash
- Added graceful handling when rpcbind is unavailable

### Changed
- Simplified startup script for better reliability

## [2.1.0] - Initial Release

### Added
- Initial release
- NFSv3 and NFSv4 support
- IP-based access control
- Automatic export of HA directories
