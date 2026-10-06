# Contributing

Thank you for considering contributing to the NFS Ganesha Home Assistant App

## How to Contribute

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Make your changes
4. Test your changes thoroughly
5. Commit your changes (`git commit -m 'Add amazing feature'`)
6. Push to the branch (`git push origin feature/amazing-feature`)
7. Open a Pull Request

## Reporting Bugs

Use the GitHub issue tracker and provide:
- Clear description of the issue
- Steps to reproduce
- Expected vs actual behavior
- Home Assistant version
- App version
- Architecture (amd64 or aarch64)
- Relevant logs from the app

## Suggesting Features

Open an issue with:
- Clear description of the feature
- Use case / why it would be useful
- Example configuration (if applicable)

## Testing

- `make test` runs everything CI runs: lint, unit tests of the generated
  ganesha.conf, and functional NFSv4 mount tests under the app's AppArmor
  profile. Only Docker and make are needed on the host (the tools run in the
  tests/toolbox image); port 2049 must be free, and the host's kernel must
  have AppArmor enabled.
- CI runs the same targets on every PR (amd64 and aarch64).
- Before a release, the maintainer runs `tests/MANUAL-HAOS-CHECKLIST.md` on a
  Home Assistant OS VM (`tests/haos/haos-vm.sh`, which needs `/dev/kvm`).

### Browsing the test VM's shares from your desktop

The VM's NFS port is forwarded to `127.0.0.1:12049`, and the VM sees your
desktop as `10.0.2.2`, which `authorized_ips: auto` allows. With the add-on
running and an NFS client installed (`nfs-common` on Debian/Ubuntu):

```bash
sudo mkdir -p /mnt/haos-nfs
sudo mount -t nfs4 -o port=12049 127.0.0.1:/ /mnt/haos-nfs   # or 127.0.0.1:/share
ls /mnt/haos-nfs
sudo umount /mnt/haos-nfs    # before stopping the VM, or the mount hangs
```

File managers' "Connect to Server" (`nfs://`) doesn't work: GNOME's NFS
support (libnfs 5) only speaks NFSv3, and the add-on is NFSv4-only. The port
is bound to `127.0.0.1`, so other machines can't reach the VM.

## Documentation

When adding features:
- Update README.md if user-facing changes
- Add entry to CHANGELOG.md
- Include examples where helpful

## Questions?

Feel free to open an issue, or ask in the [Home Assistant Community thread](https://community.home-assistant.io/t/new-haos-app-nfs-server/984352), if you have questions!
