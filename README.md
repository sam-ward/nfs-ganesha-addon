# Home Assistant NFS Server (Ganesha) App

[![GitHub Release][releases-shield]][releases]
[![License][license-shield]](LICENSE)

Expose Home Assistant folders via NFS using nfs-ganesha in userspace.

## Features

- ✅ NFSv3 and NFSv4 support
- ✅ Select which Home Assistant folders to export
- ✅ IP-based access control with support for multiple IPs/subnets
- ✅ Userspace implementation (no kernel modules required)
- ✅ Works with host network mode for best compatibility
- ✅ Read-write access to all exported folders

## Installation

1. Click the button below to add this repository to your Home Assistant instance:

   [![Open your Home Assistant instance and show the add app repository dialog with a specific repository URL pre-filled.](https://my.home-assistant.io/badges/supervisor_add_addon_repository.svg)](https://my.home-assistant.io/redirect/supervisor_add_addon_repository/?repository_url=https://github.com/sam-ward/nfs-ganesha-addon)

   Or manually add this repository in Home Assistant:
   - Go to **Settings** → **Apps** → **App Store**
   - Click the three dots (⋮) in the top right
   - Select **Repositories**
   - Add: `https://github.com/sam-ward/nfs-ganesha-addon`

2. Find "NFS Server (Ganesha)" in the app store
3. Click "Install"
4. Configure the app (see Configuration section below)
5. Start the app

## Configuration

### Basic Configuration

```yaml
authorized_ips:
  - "192.168.1.0/24"
export_folders:
  - config
  - backup
  - media
```

### Options

#### `authorized_ips` (required)

List of IP addresses or CIDR subnets allowed to access the NFS shares.

**Default:** All private network ranges
```yaml
authorized_ips:
  - "10.0.0.0/8"
  - "172.16.0.0/12"
  - "192.168.0.0/16"
```

**Examples:**
```yaml
# Single IP
authorized_ips:
  - "192.168.1.100"

# Single subnet
authorized_ips:
  - "192.168.1.0/24"

# Multiple IPs and subnets
authorized_ips:
  - "192.168.1.0/24"
  - "10.0.0.5"
  - "172.16.0.0/16"

# Allow all (not recommended for security)
authorized_ips:
  - "*"
```

#### `export_folders` (required)

List of Home Assistant folders to export via NFS. Select one or more from:

- `config` - Home Assistant configuration
- `ssl` - SSL certificates
- `addons` - Local apps
- `addon_configs` - App configuration files
- `backup` - Backups
- `share` - Shared files
- `media` - Media files

**Default:** All folders
```yaml
export_folders:
  - config
  - ssl
  - addons
  - addon_configs
  - backup
  - share
  - media
```

## Mounting from Clients

### Linux

**NFSv4 (recommended):**
```bash
# Mount all exports
sudo mount -t nfs4 <HA_IP>:/ /mnt/homeassistant

# Or mount individual exports
sudo mount -t nfs4 <HA_IP>:/config /mnt/ha-config
```

**Make permanent** - Add to `/etc/fstab`:
```
<HA_IP>:/  /mnt/homeassistant  nfs4  defaults,_netdev  0  0
```

### macOS

```bash
sudo mount -t nfs -o nfsvers=4 <HA_IP>:/config /Volumes/ha-config
```

### Windows

1. Enable NFS Client:
   - Settings → Apps → Optional Features → Add a feature
   - Search for "NFS" and install "Services for NFS"

2. Mount the share:
```cmd
mount -o anon \\<HA_IP>\config Z:
```

## Troubleshooting

### Permission Issues

All NFS operations are mapped to root on the server side, so you should have full read-write access. If you encounter permission issues:

1. Verify the folder is in your `export_folders` list
2. Check your `authorized_ips` includes your client IP
3. Remount the share

### showmount doesn't work

This is expected. The app runs in host network mode where `showmount` may not function. Use NFSv4 direct mounting instead:

```bash
# List available exports by mounting root
mount -t nfs4 <HA_IP>:/ /mnt/test
ls /mnt/test
umount /mnt/test
```

### Can't write to files

1. Ensure the folder is in `export_folders`
2. Check addon logs for any errors
3. Verify your client IP is in `authorized_ips`

## Known Limitations

- `showmount -e` command may not work due to rpcbind limitations in container mode
- NFSv4 is recommended; NFSv3 may have limited functionality
- Access control is IP-based only (no user authentication)

## Support

- [Open an issue](https://github.com/sam-ward/nfs-ganesha-addon/issues)
- [Discussions](https://github.com/sam-ward/nfs-ganesha-addon/discussions)
- [Home Assistant Community](https://community.home-assistant.io/)

## Contributing

Contributions are welcome! Please read [CONTRIBUTING.md](CONTRIBUTING.md) for details.

## License

MIT License - see [LICENSE](LICENSE) file for details.

## Credits

Based on [nfs-ganesha](https://github.com/nfs-ganesha/nfs-ganesha) userspace NFS server.

[releases-shield]: https://img.shields.io/github/release/sam-ward/nfs-ganesha-addon.svg
[releases]: https://github.com/sam-ward/nfs-ganesha-addon/releases
[license-shield]: https://img.shields.io/github/license/sam-ward/nfs-ganesha-addon.svg
