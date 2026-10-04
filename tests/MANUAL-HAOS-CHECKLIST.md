# HAOS release checklist

Run before tagging a release, on the HAOS test VM (`tests/haos/haos-vm.sh`; needs
Docker and `/dev/kvm`). Record the results in the release PR.

## Set up

1. `tests/haos/haos-vm.sh start`, `wait`, then `onboard` (first run only; the
   login is saved in `.test-haos/credentials`). Home Assistant is at
   http://127.0.0.1:18123.
2. Serve the released version: `URL=$(tests/haos/haos-vm.sh repo main)`, then
   `tests/haos/haos-vm.sh api POST store/repositories "{\"repository\":\"$URL\"}"`.
   The add-on's slug is `<repository hash>_nfs_ganesha`
   (`tests/haos/haos-vm.sh api GET store/addons`).
3. For the upgrade, make a local, never-pushed branch from the release branch
   with only `version` bumped above the released one, and serve it with
   `tests/haos/haos-vm.sh repo <branch>`, then `api POST store/reload`.

## Automated checks

`tests/haos/haos-checks.sh SLUG VERSION` (set `NFS_EXPORT=/share` when `/config`
isn't exported) checks what the Supervisor reports (version, rating, AppArmor
profile, privileges), the add-on's log, AppArmor events in the HAOS kernel log,
and NFS 4.0/4.1/4.2 from this machine (read/write, numeric owner/group changes,
chmod/chown on other users' files, links). Run it for each scenario:

- [ ] **Upgrade, options never saved:** install the released version, start it
      without saving options, update. The new defaults apply (expected, see the
      CHANGELOG's breaking note).
- [ ] **Upgrade, options saved:** reinstall the released version, save options
      including the legacy folder names, update. Options are kept and
      `addons`/`addon_configs` are renamed `local_apps`/`app_configs` in the
      Supervisor's stored options.
- [ ] **Fresh install:** uninstall, install, start with defaults. The log shows
      `authorized_ips "auto" -> 10.0.2.0/24 (... from Supervisor)`.
- [ ] **Refused client:** set `authorized_ips` to an address other than
      `10.0.2.2`; mounting is refused.
- [ ] **Clean stop:** stopping takes about a second and the Supervisor log has
      no SIGTERM warning.
- [ ] **Restart under a mounted client:** a client keeps working across an
      add-on restart without remounting.

## In the browser

- [ ] The app store and the app's Info page show the icon and logo.
- [ ] The Configuration tab shows the option names and descriptions
      (`translations/en.yaml`).
- [ ] The Info page shows the security rating and the custom AppArmor profile.
- [ ] The Documentation tab renders the "Defaults" box and the `log_level` table.

To look around the shares yourself, mount them from your desktop as described
in CONTRIBUTING.md ("Browsing the test VM's shares").

## Afterwards

`tests/haos/haos-vm.sh stop`, and delete the local version-bump branch.
