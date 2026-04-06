# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
