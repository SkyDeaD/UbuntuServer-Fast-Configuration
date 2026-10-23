# Moving from usfc 4.x to 5.0

<p align="center"><a href="MIGRATION-5.md">🇷🇺 Русский</a> · <b>🇬🇧 English</b></p>

In 5.0, modes became commands: `usfc --apply web` is now `usfc apply web`.
The old flags are not supported: they exit with code `2` and print the
ready-made new line. This page is for anyone who already has usfc on servers
or calls it from cloud-init, cron, and Ansible.

## What happens on its own

usfc updates itself every time the menu starts. Once 5.0 lands in `main`,
servers running 4.x get it on the next `usfc`. The update itself changes
nothing on the server: items aren't reapplied and configs aren't rewritten.

What will break without any action from you:

- **Scripts with old flags.** `usfc --audit` in cron and `--apply` in
  cloud-init will start exiting with code `2`. The list of replacements is
  below.
- **Nothing else.** Services, the firewall, sshd, and swap keep working the
  way they were set up in 4.x.

## Before you update

1. Find the usfc calls in your scripts:

   ```bash
   grep -rn 'usfc --\|install.sh.*--apply' /etc/cron* /var/lib/cloud /path/to/ansible 2>/dev/null
   ```

   Replace `/path/to/ansible` with the directory of your playbooks.

2. Rewrite each call using the [table](#before--after).
3. Check the new line with a dry run: `sudo usfc apply web --dry-run`.

## Before → after

| 4.x | 5.0 |
|---|---|
| `usfc --apply web` | `usfc apply web` |
| `usfc --apply=web` | `usfc apply web` |
| `usfc --apply all --dry-run` | `usfc apply all --dry-run` |
| `usfc --apply zram --yes` | `usfc apply zram --yes` |
| `usfc --config f.conf` | `usfc apply --config f.conf` |
| `usfc --config f.conf --apply web` | `usfc apply web --config f.conf` |
| `usfc --audit` | `usfc audit` |
| `usfc --audit --json` | `usfc audit --json` |
| `usfc --list` | `usfc list` |
| `usfc --backups` | `usfc backups` |
| `usfc --restore` | `usfc restore` (needs a terminal) |
| `usfc --restore <label> --yes` | `usfc restore <label> --yes` |
| `… \| sudo bash -s -- --apply web` | `… \| sudo bash -s -- apply web` |
| `usfc --help`, `usfc --version` | unchanged; also `usfc help`, `usfc version` |

The old line suggests the new one itself:

```text
$ sudo usfc --audit --json
usfc: in 5.0 modes became commands. Use this instead:
  usfc audit --json
```

## What changed in behavior

These changes don't break the command line, but they change the result.

- **`usfc audit` returns `1` on important findings** (`crit`). In 4.x the code
  was always `0`. If a cron job checks the exit code, it will start reporting
  problems, which is the intent.
- **Items from the command line beat `ITEMS=`.** In 4.x, `ITEMS=` from the
  answers file overrode `--apply`. Now `ITEMS=` is used only if the command line
  names no items.
- **`--config` without `apply` is an error.** In 4.x it was silently ignored
  outside `--apply`.
- **Values in the answers file are validated.** `NGINX_AUTOSTART=yse` silently
  meant "no" in 4.x; now it's an error with exit code `2`. "Yes" is `Y`, `yes`,
  `true`, `on`, `1`, `да`.
- **`--lang` with an invalid value is an error**, not a quiet fall back to
  Russian.
- **UFW is enabled in batch mode.** In 4.x, the `ufw` item in `--apply` was
  silently skipped, even in the `web` and `secure` profiles. Now it's enabled if
  there is consent: `--ufw`, `UFW=Y`, `--yes`, or a `--allow` port list. Without
  consent, it's skipped with a warning. **Check that your profiles
  with `--yes` won't close ports you need:** open them with `--allow`.
- **`--yes` no longer restarts Docker** in the `dockerlog` item: the restart
  stops containers. If you need it, add `--docker-restart`.
- **Questions that default to "no" no longer quietly turn into "no" in a
  batch.** Certbot TLS stub files, nginx and Docker autostart, and zram
  reconfiguration are set ahead of time: as a question in the menu, and as a flag
  or key in `apply`. The full list is in
  [CLI.en.md](CLI.en.md#answers-to-item-questions).
- **A flag for an item that is not in the list is an error.** `usfc apply docker
  --swap 2048` exits with code `2`: `--swap` belongs to `zram`.

## What changes on servers that are already set up

The update itself does none of this. The changes arrive when you apply an item
again; the menu shows such items with the `!` status.

### SSH hardening: new drop-in file

4.x wrote `/etc/ssh/sshd_config.d/10-hardening.conf`. In sshd, the first value
of a key wins, so any provider file that sorts earlier (for example
`00-*.conf`) quietly overrode the password ban.

5.0 writes `00-usfc-hardening.conf` and deletes the old file when it applies.
On a server with 4.x, the item shows "! old 10-hardening.conf — apply the item
again".

1. Open the menu: `sudo usfc`.
2. Choose item **18 "SSH hardening"** and go through the questions.
3. If usfc finds foreign lines that override the hardening, it shows them as
   file, line, and value and offers to comment them out. Without your consent,
   the item is not applied.

After the sshd restart, usfc checks all the keys through `sshd -T`. If they
differ, it rolls back its file and names the file that won.

### Swap: priority in fstab

In 4.x, the swap line in `/etc/fstab` was edited with a single `sed` that
understood only the `<path> none swap sw` form. Lines with `defaults`,
`sw,nofail`, `pri=5`, `UUID=`, and `LABEL=` were left without `pri=10`, even
though the item reported "priority 10". After a reboot, swap came up with the
default priority and could be used before zram.

5.0 notices this: item **17 "ZRAM + swap + earlyoom"** shows "! swap priority
not in fstab". Choose it and it fixes the line without turning off zram.

### Blocks in .bashrc

The `cli` and `fastfetch` items write blocks to `~/.bashrc`. In 5.0 both have
new versions: in `cli`, the `ports`, `dps`, `extract`, and `myip` functions and
the starship presets; in `fastfetch`, it runs only on SSH login and not inside
tmux. The items show "the .bashrc block is outdated" or "autorun outdated".
Choose the item to update the block.

### fail2ban

4.x overwrote `/etc/fail2ban/jail.local`. 5.0 leaves it alone and writes its
own `/etc/fail2ban/jail.d/usfc-sshd.local` with `backend = systemd`; on
Debian 12, the jail couldn't find the log without it. The old `jail.local`
keeps working until you apply the item again. The item has `⇄`: in the menu,
choosing it again turns it off, so to rewrite the config, turn the item off and
on again.

### Snapshots and rollback

The 4.x snapshots in `/var/backups/usfc` stay and are restored with
`usfc restore <label>`. 5.0 snapshots also remember files that did not exist
before usfc and delete them on restore.

## If something goes wrong

- To restore configs: `sudo usfc backups`, then
  `sudo usfc restore <label>`.
- For what to do about sshd conflicts, swap, and the log, see
  [TROUBLESHOOTING.en.md](TROUBLESHOOTING.en.md).
- To stay on 4.x: 4.x checks for updates on every run, including `--apply` and
  `--audit`, and updates from `main`. The only way to stop that is the
  `USFC_NO_UPDATE=1` variable on every call. Installing from a tag
  (`install.sh --branch v4.2.0`) has not been tested with this approach.
