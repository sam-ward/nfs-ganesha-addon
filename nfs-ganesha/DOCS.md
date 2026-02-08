# Home Assistant Add-on: NFS Server (Ganesha)

## Installation

1. Add this repository to your Home Assistant instance
2. Install the "NFS Server (Ganesha)" add-on
3. Configure the add-on (see Configuration below)
4. Start the add-on

## Configuration

### Example Configuration

```yaml
authorized_ips:
  - "192.168.1.0/24"
  - "10.0.0.5"
export_folders:
  - config
  - backup
  - media
```

### Option: `authorized_ips`

**Required:** Yes  
**Type:** List of strings  
**Default:** All private network ranges

List of IP addresses or CIDR subnets allowed to access your NFS shares.

**Examples:**

```yaml
# Allow a specific subnet (recommended)
authorized_ips:
  - "192.168.1.0/24"

# Allow multiple networks
authorized_ips:
  - "192.168.1.0/24"
  - "10.0.0.0/8"

# Allow specific IPs
authorized_ips:
  - "192.168.1.10"
  - "192.168.1.20"
  - "192.168.1.30"

# Allow all (NOT recommended for security)
authorized_ips:
  - "*"
```

**Private Network Ranges (default):**
- `10.0.0.0/8` - Class A (10.0.0.0 - 10.255.255.255)
- `172.16.0.0/12` - Class B (172.16.0.0 - 172.31.255.255)
- `192.168.0.0/16` - Class C (192.168.0.0 - 192.168.255.255)

### Option: `export_folders`

**Required:** Yes  
**Type:** Multi-select list  
**Default:** All folders

Select which Home Assistant folders to export via NFS.

**Available folders:**
- `config` - Home Assistant configuration files
- `ssl` - SSL certificates
- `addons` - Local add-ons
- `addon_configs` - Add-on configuration files
- `backup` - Backup files
- `share` - Shared files
- `media` - Media files

**Examples:**

```yaml
# Export everything (default)
export_folders:
  - config
  - ssl
  - addons
  - addon_configs
  - backup
  - share
  - media

# Export only config and backups
export_folders:
  - config
  - backup

# Export only media
export_folders:
  - media
```

## Mounting from Clients

### Linux

#### NFSv4 (Recommended)

**Mount all exports:**
```bash
sudo mkdir -p /mnt/homeassistant
sudo mount -t nfs4 <HA_IP>:/ /mnt/homeassistant
```

You can then access:
- `/mnt/homeassistant/config`
- `/mnt/homeassistant/backup`
- `/mnt/homeassistant/media`
- etc.

**Mount individual export:**
```bash
sudo mkdir -p /mnt/ha-config
sudo mount -t nfs4 <HA_IP>:/config /mnt/ha-config
```

#### Make Permanent

Add to `/etc/fstab`:

```bash
# Mount all exports
<HA_IP>:/  /mnt/homeassistant  nfs4  defaults,_netdev  0  0

# Or mount individually
<HA_IP>:/config  /mnt/ha-config  nfs4  defaults,_netdev  0  0
<HA_IP>:/backup  /mnt/ha-backup  nfs4  defaults,_netdev  0  0
```

The `_netdev` option tells the system to wait for network before mounting.

#### Unmounting

```bash
sudo umount /mnt/homeassistant
```

### macOS

```bash
# Create mount point
sudo mkdir -p /Volumes/homeassistant

# Mount
sudo mount -t nfs -o nfsvers=4 <HA_IP>:/config /Volumes/homeassistant

# Unmount
sudo umount /Volumes/homeassistant
```

**Note:** macOS Finder may not show NFS mounts in the sidebar, but they're accessible via Terminal or by navigating to `/Volumes/`.

### Windows

#### Prerequisites

Enable NFS Client:
1. Open Settings → Apps → Optional Features
2. Click "Add a feature"
3. Search for "Services for NFS"
4. Install "Services for NFS" (requires reboot)

Or via PowerShell (as Administrator):
```powershell
Enable-WindowsOptionalFeature -Online -FeatureName ServicesForNFS-ClientOnly
```

#### Mount the Share

```cmd
# Map as network drive
mount -o anon \\<HA_IP>\config Z:

# Access the drive
Z:
dir

# Unmount
umount Z:
```

**Note:** Windows uses backslashes and converts the NFS path format automatically.

## Troubleshooting

### Can't write to files

**Check these:**

1. **Is the folder exported?**
   - Verify the folder is in your `export_folders` configuration
   - Restart the add-on after changing configuration

2. **Is your IP authorized?**
   - Check your `authorized_ips` includes your client IP
   - Find your client IP: `ip addr show` (Linux), `ifconfig` (macOS), `ipconfig` (Windows)

3. **Check addon logs:**
   - Settings → Add-ons → NFS Server (Ganesha) → Logs
   - Look for errors or warnings

### `showmount -e` doesn't work

**This is expected.** The add-on runs in host network mode where `showmount` may not function properly.

**Workaround:** Mount the root directory to see all available exports:
```bash
mount -t nfs4 <HA_IP>:/ /mnt/test
ls /mnt/test  # Shows all exported folders
umount /mnt/test
```

### Connection refused / No route to host

**Possible causes:**

1. **Add-on not running** - Check Home Assistant add-on status
2. **Firewall blocking** - Check network firewall for port 2049
3. **Wrong IP address** - Verify Home Assistant IP address

**Debug:**
```bash
# Check if port 2049 is accessible
telnet <HA_IP> 2049

# Or with nc (netcat)
nc -zv <HA_IP> 2049
```

### Permission denied

**Cause:** Your client IP is not in the `authorized_ips` list.

**Solution:**
1. Find your client IP
2. Add it to `authorized_ips` in the addon configuration
3. Restart the add-on

### Mount hangs or times out

**Cause:** Network issues or firewall blocking NFS traffic.

**Solution:**
- Ensure client and server are on same network/VLAN
- Check firewall allows port 2049 (TCP/UDP)
- Try adding mount options: `-o soft,timeo=10`

### Stale file handle error

**Cause:** The NFS server was restarted while files were mounted.

**Solution:**
```bash
# Force unmount
sudo umount -f /mnt/homeassistant

# Or lazy unmount
sudo umount -l /mnt/homeassistant

# Then remount
sudo mount -t nfs4 <HA_IP>:/ /mnt/homeassistant
```

## Performance Tips

1. **Mount the root (`/`)** instead of individual exports to reduce overhead
2. **Use NFSv4** exclusively (faster than NFSv3)
3. **Use wired connections** for best performance
4. **Adjust buffer sizes** with mount options if needed:
   ```bash
   mount -t nfs4 -o rsize=1048576,wsize=1048576 <HA_IP>:/ /mnt/ha
   ```

## Security Considerations

1. **Use specific IPs/subnets** - Don't use `*` in production
2. **Network isolation** - Keep NFS on a trusted network/VLAN
3. **No encryption** - NFSv4 traffic is not encrypted (use VPN if needed)
4. **Firewall** - Consider blocking port 2049 at your network edge
5. **Home use only** - This configuration is designed for home networks

## Advanced Usage

### Read-Only Mounts (Client-side)

To mount a share as read-only on the client:

```bash
sudo mount -t nfs4 -o ro <HA_IP>:/backup /mnt/ha-backup
```

This doesn't change the server configuration, just prevents the client from writing.

### Multiple Mount Points

You can mount different exports to different locations:

```bash
sudo mount -t nfs4 <HA_IP>:/config /mnt/ha-config
sudo mount -t nfs4 <HA_IP>:/media /mnt/ha-media
sudo mount -t nfs4 <HA_IP>:/backup /mnt/ha-backup
```

## Support

- [Report bugs](https://github.com/sam-ward/nfs-ganesha-addon/issues)
- [Ask questions](https://github.com/sam-ward/nfs-ganesha-addon/discussions)
- [Home Assistant Community](https://community.home-assistant.io/)

## License

MIT License - see LICENSE file for details.

## Credits

This add-on uses [nfs-ganesha](https://github.com/nfs-ganesha/nfs-ganesha), a userspace NFS server.
