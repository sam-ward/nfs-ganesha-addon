# Home Assistant App: NFS Server (Ganesha)

## Installation

1. Add this repository to your Home Assistant instance
2. Install the "NFS Server (Ganesha)" app
3. Configure the app (see Configuration below)
4. Start the app

## Configuration

> **Defaults (new in this version)**
>
> - By default the app shares only `share`, `media` and `backup`, and only with clients on Home Assistant's own network (`auto`).
> - **Updating from an earlier version:** if you ever saved the app's options, your settings are kept. If you never changed them, the new defaults apply after the update, so `config`, `ssl`, `local_apps` and `app_configs` are no longer shared, and clients outside Home Assistant's own subnet (for example over a VPN or from another VLAN) are refused. Add them back in the options if you need them.
> - To also share `config`, `ssl`, `local_apps` or `app_configs`, add them to `export_folders`. Each one exposes sensitive files:
>   - `config`: your Home Assistant configuration, including `secrets.yaml`
>   - `ssl`: certificates and their private keys
>   - `local_apps`: the source of locally installed apps
>   - `app_configs`: other apps' configuration, which can include their secrets
> - `auto` means Home Assistant's own network subnet, worked out at each start. The app's log shows what it resolved to, for example `authorized_ips "auto" -> 192.168.1.0/24 (primary interface end0, from Supervisor)`. You can combine it with other entries, or replace it with explicit subnets.

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
**Default:** `auto`

List of IP addresses or CIDR subnets allowed to access your NFS shares, and/or `auto`.

`auto` is replaced at each start by the subnet of Home Assistant's primary network interface (from Settings → System → Network), for example `192.168.1.0/24`. If the app can't work it out, it refuses to start and logs why, rather than guessing. Clients on other subnets, VPNs or VLANs need their own entries.

**Examples:**

```yaml
# Home Assistant's own network (the default)
authorized_ips:
  - auto

# Home Assistant's network plus a VPN subnet
authorized_ips:
  - auto
  - "10.20.0.0/24"

# Allow a specific subnet
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

Installs from before this change default to all private network ranges (`10.0.0.0/8`, `172.16.0.0/12` and `192.168.0.0/16`) and keep that setting until you change it.

### Option: `export_folders`

**Required:** Yes  
**Type:** Multi-select list  
**Default:** `share`, `media`, `backup`

Select which Home Assistant folders to export via NFS.

**Available folders:**
- `config` - Home Assistant configuration files, including `secrets.yaml`
- `ssl` - SSL certificates and their private keys
- `local_apps` - Local apps
- `app_configs` - App configuration files, which can include other apps' secrets

`local_apps` and `app_configs` were called `addons` and `addon_configs` before Home Assistant renamed add-ons to apps. The app still accepts the old names and renames them in your saved settings automatically. Clients can still mount the old paths (`/addons`, `/addon_configs`), but they are deprecated: switch your mounts to `/local_apps` and `/app_configs`.
- `backup` - Backup files
- `share` - Shared files
- `media` - Media files

**Examples:**

```yaml
# The default
export_folders:
  - share
  - media
  - backup

# Export everything (includes secrets and private keys)
export_folders:
  - config
  - ssl
  - local_apps
  - app_configs
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

### Option: `log_level`

**Required:** No  
**Type:** One of `NULL`, `FATAL`, `MAJ`, `CRIT`, `WARN`, `EVENT`, `INFO`, `DEBUG`, `MID_DEBUG`, `FULL_DEBUG`  
**Default:** `WARN`

How much the app and the NFS server log. Leave it at `WARN` unless you're troubleshooting, because the debug levels are very verbose.

**What the app logs at each level:**

| Level | What you see in the app's log |
|---|---|
| Every level | The app version, the NFS-Ganesha version, the log level, the authorized IPs and each exported folder. Include these lines when you ask for help. |
| `NULL` to `WARN` | NFS-Ganesha's warnings and errors. A few noisy Ganesha components (`TIRPC`, `NFS_CB`, `INIT`, `DISPATCH`) only log fatal errors, as in earlier versions, and Ganesha's messages about log-level changes are hidden. |
| `EVENT` and above | Nothing is muted or hidden: every Ganesha component logs at the chosen level. |
| `DEBUG`, `MID_DEBUG`, `FULL_DEBUG` | Also prints the full generated `ganesha.conf` before the server starts. It contains your authorized IPs and folder names. |

For what each level means inside NFS-Ganesha, see the [NFS-Ganesha logging documentation](https://github.com/nfs-ganesha/nfs-ganesha/blob/next/src/doc/man/ganesha-log-config.rst).

**Example:**

```yaml
log_level: DEBUG
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

Windows' built-in NFS client ("Services for NFS") only supports NFSv3, and this app is NFSv4-only, so it can't connect. Either:

- **Use the official Samba share app (recommended).** It shares the same Home Assistant folders over SMB, which Windows supports natively.
- **Use a third-party NFSv4 client for Windows.**

## Troubleshooting

### Can't write to files

**Check these:**

1. **Is the folder exported?**
   - Verify the folder is in your `export_folders` configuration
   - Restart the app after changing configuration

2. **Is your IP authorized?**
   - Check your `authorized_ips` includes your client IP
   - Find your client IP: `ip addr show` (Linux), `ifconfig` (macOS), `ipconfig` (Windows)

3. **Check addon logs:**
   - Settings → Apps → NFS Server (Ganesha) → Logs
   - Look for errors or warnings
   - For more detail, set `log_level` to `DEBUG`, restart the app and try again

### `showmount -e` doesn't work

**This is expected.** The app runs in host network mode where `showmount` may not function properly.

**Workaround:** Mount the root directory to see all available exports:
```bash
mount -t nfs4 <HA_IP>:/ /mnt/test
ls /mnt/test  # Shows all exported folders
umount /mnt/test
```

### Connection refused / No route to host

**Possible causes:**

1. **App not running** - Check Home Assistant app status
2. **Firewall blocking** - Check network firewall for port 2049
3. **Wrong IP address** - Verify Home Assistant IP address

**Debug:**
```bash
# Check if port 2049 is accessible
telnet <HA_IP> 2049

# Or with nc (netcat)
nc -zv <HA_IP> 2049
```

### "No such file or directory" when mounting

**Cause:** Your client isn't in `authorized_ips`. NFS-Ganesha hides exports from clients it doesn't allow, so the mount fails as if the folder didn't exist.

**Solution:**
1. Check the app's log for the `authorized_ips "auto" ->` line to see which subnet `auto` resolved to
2. If your client is on another subnet (a VPN or VLAN, for example), add that subnet to `authorized_ips`
3. Restart the app

### Permission denied

**Cause:** Your client IP is not in the `authorized_ips` list.

**Solution:**
1. Find your client IP
2. Add it to `authorized_ips` in the addon configuration
3. Restart the app

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
2. **Use wired connections** for best performance
3. **Adjust buffer sizes** with mount options if needed:
   ```bash
   mount -t nfs4 -o rsize=1048576,wsize=1048576 <HA_IP>:/ /mnt/ha
   ```

## Security Considerations

1. **Use specific IPs/subnets** - Don't use `*` in production
2. **Network isolation** - Keep NFS on a trusted network/VLAN
3. **No encryption** - NFSv4 traffic is not encrypted (use VPN if needed)
4. **Firewall** - Consider blocking port 2049 at your network edge
5. **Home use only** - This configuration is designed for home networks

### Privileges

The app asks Home Assistant for two extra capabilities, and nothing more:

- **`DAC_READ_SEARCH`** - the NFS server reopens files by their file handle, which needs this capability.
- **`SYS_RESOURCE`** - lets the NFS server tell the kernel it is part of the storage path, which prevents stalls when memory is low.

The app runs under its own AppArmor profile, which limits what the NFS server and the startup scripts can do (capabilities, network access and programs they can run). Its security rating is 4 (up from 2).

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
- [Ask questions](https://community.home-assistant.io/t/new-haos-app-nfs-server/984352) (Home Assistant Community thread)
- [Home Assistant Community](https://community.home-assistant.io/)

## License

MIT License - see LICENSE file for details.

## Credits

This app uses [nfs-ganesha](https://github.com/nfs-ganesha/nfs-ganesha), a userspace NFS server.
