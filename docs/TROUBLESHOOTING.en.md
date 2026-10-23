# Troubleshooting usfc

<p align="center"><a href="TROUBLESHOOTING.md">🇷🇺 Русский</a> · <b>🇬🇧 English</b></p>

This page is organized by symptom: find what you see and follow the steps.
Almost always, start with two commands:

```bash
sudo usfc audit                 # what the server looks like now, changes nothing
sudo tail -n 100 /var/log/usfc.log
```

## Contents

- [Where the log is and how to roll back](#where-the-log-is-and-how-to-roll-back)
- [Password login still works after SSH hardening](#password-login-still-works-after-ssh-hardening)
- [SSH hardening didn't apply or rolled itself back](#ssh-hardening-didnt-apply-or-rolled-itself-back)
- [SSH port move is not finished](#ssh-port-move-is-not-finished)
- [Swap without a priority](#swap-without-a-priority)
- [Docker ports are open even though UFW doesn't allow them](#docker-ports-are-open-even-though-ufw-doesnt-allow-them)
- [Telegram alerts don't arrive](#telegram-alerts-dont-arrive)
- [btop: "~/.config could not be created"](#btop-config-could-not-be-created)
- [Installation hangs on "Could not get lock"](#installation-hangs-on-could-not-get-lock)
- [A command exits with code 2](#a-command-exits-with-code-2)

## Where the log is and how to roll back

**Log.** Every command that runs and its output are written to
`/var/log/usfc.log`, even when the screen shows only a spinner. After 5 MB, the
log moves to `/var/log/usfc.log.1`. To see the output on screen right away, run
with `--verbose`.

**Rollback.** Before every edit of a system file, usfc puts a copy in
`/var/backups/usfc/<label>`. The label is printed at the end of the run.

1. Look at the snapshots:

   ```bash
   sudo usfc backups
   ```

2. Restore the one you need:

   ```bash
   sudo usfc restore 20261023-040000-3691
   ```

   Replace `20261023-040000-3691` with a label from the list.

Before a restore, it takes one more snapshot, so a restore can be undone too.
Files that did not exist before usfc are deleted on restore. A restore doesn't
touch packages and services, only files. The removal commands for each item are
on the `I` screen in the menu.

## Password login still works after SSH hardening

**Symptom.** Item 18 shows "! password login still on (overridden elsewhere)" or
"! root login allowed (overridden elsewhere)".

**Cause.** sshd takes the first value of each key. If a provider file in
`/etc/ssh/sshd_config.d/` sorts before the usfc file, or the key is set in
`sshd_config` before the `Include` line, that one wins.

1. See what sshd actually applies:

   ```bash
   sudo sshd -T | grep -E 'passwordauthentication|permitrootlogin|kbdinteractive'
   ```

2. Find who sets the key:

   ```bash
   sudo grep -rn -i 'PasswordAuthentication' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/
   ```

3. Apply item **18 "SSH hardening"** again: `sudo usfc`. It finds the
   conflicting lines, shows them with file, line, and value, and offers to
   comment them out with a snapshot.

`usfc audit` reports such a file as the `ssh.dropin_order` finding.

If a `10-hardening.conf` from 4.x is left on the server, the item shows "! old
10-hardening.conf — apply the item again". Applying the item replaces it with
`00-usfc-hardening.conf`; see [MIGRATION-5.en.md](MIGRATION-5.en.md#ssh-hardening-new-drop-in-file).

## SSH hardening didn't apply or rolled itself back

Before any changes, the item creates a temporary key and checks login with it
on `127.0.0.1`. If that fails, hardening doesn't start. After the sshd restart,
the item checks all the keys through `sshd -T`; if they differ, it rolls back and
password login stays on. This is a safeguard, not a breakage: the item prints the
reason, and it's in the log too.

Common causes:

- **sshd doesn't listen on every address.** The item prints "sshd does not
  listen on every address (ListenAddress) — the self-test needs 127.0.0.1". Add
  `ListenAddress 127.0.0.1` or remove the restriction, then apply the item again.
- **Another file overrides the keys.** The item names the winning file; see the
  [previous section](#password-login-still-works-after-ssh-hardening).
- **No regular user.** The item can't be applied as plain root: it also closes
  root login. Create a user with item **1**.

## SSH port move is not finished

The item status is "! port: move 22 → 2222 not finished". This is the first
step of the move: sshd listens on both ports and UFW allows both.

1. Check login on the new port from your own machine:

   ```bash
   ssh -p 2222 user@server
   ```

   Replace `2222`, `user`, and `server` with your own values.

2. Close the old port by repeating the same command, or answer "yes" to the
   question in the menu:

   ```bash
   sudo usfc apply sshhardening --ssh-port 2222
   ```

If you change your mind, move the port back the same way: `--ssh-port 22`.

If the move doesn't start and the item prints "ListenAddress with an explicit
port overrides Port", remove the port from the `ListenAddress` lines in
`sshd_config` and try again.

## Swap without a priority

**Symptom.** `swapon --show` shows a priority of `-2` (or anything but `10`) for
the swap file, and the on-disk swap is used before zram.

1. Check:

   ```bash
   swapon --show
   grep -v '^#' /etc/fstab | grep swap
   ```

   The fourth field of the swap line should contain `pri=10`.

2. Open the menu and choose item **17 "ZRAM + swap + earlyoom"**. With this
   problem, it shows "! swap priority not in fstab" and fixes the line without
   turning off zram. The item understands lines with `defaults`, `sw,nofail`,
   `pri=N`, `UUID=`, and `LABEL=`.

It won't turn swap off to fix it if what's in use there doesn't fit into free
memory, and the item says so plainly.

## Docker ports are open even though UFW doesn't allow them

**Cause.** Docker publishes ports (`-p 8080:80`) with its own iptables rules,
bypassing the UFW chains. `usfc audit` shows this as `ports.docker`.

Make container ports obey UFW:

```bash
sudo usfc firewall docker on
sudo usfc firewall --allow 8080
```

After `docker on`, only what is allowed through `usfc firewall --allow` reaches
containers from outside. It works for IPv4 and for Docker's iptables backend. To
undo it, run `sudo usfc firewall docker off`.

## Telegram alerts don't arrive

1. Send a test message directly:

   ```bash
   sudo /usr/local/sbin/usfc-notify "test"
   ```

   Without `--bg`, on an error the script prints Telegram's response (with the
   token replaced by `***`).

2. By the response:
   - `Unauthorized`: the token is wrong. Apply item **15** again.
   - `chat not found`: the `chat_id` is wrong, or you haven't sent the bot
     `/start`, or the bot isn't added to the channel.
   - timeout: the server couldn't reach `api.telegram.org`. Check outbound
     HTTPS.
3. Failures of background sends (SSH login, ban) are written to the system
   journal:

   ```bash
   sudo journalctl -t usfc-notify --since today
   ```

The settings are in `/etc/usfc/notify.conf` (permissions `600`). The SSH login
alert is sent in the background and doesn't delay the login, even if there is no
network.

## btop: "~/.config could not be created"

**Cause.** In 4.x, the fastfetch item created `~/.config` as root, and the
user's programs couldn't write to their own directory.

In 5.0, directories in the home directory are created as the user, and an
already broken `~/.config` is fixed when you apply any item that writes there:
`cli`, `fastfetch`. To fix it by hand:

```bash
sudo chown "$USER": ~/.config
```

## Installation hangs on "Could not get lock"

On a freshly created server, `apt-daily.timer` starts `unattended-upgrades`,
which holds the dpkg lock for minutes. usfc waits for it up to 300 seconds. To
wait longer:

```bash
sudo USFC_APT_LOCK_TIMEOUT=900 usfc apply web
```

## A command exits with code 2

Code `2` is an error in the arguments or the answers file. The message above the
code says exactly what is wrong. Common cases:

- **An old 4.x form** (`--apply`, `--audit`, `--list`, `--backups`,
  `--restore`). usfc prints the ready-made new line. The replacement table is in
  [MIGRATION-5.en.md](MIGRATION-5.en.md#before--after).
- **A flag for an item that is not in the list**: `--swap` without `zram`,
  `--allow` without `ufw`. Add the item or remove the flag.
- **An unknown key or an invalid value in the answers file**. The message names
  the file and line: `node.conf:4: unknown key UWF`.
- **An option from the wrong command**: `--json` works only with `audit`.

The full reference is in [CLI.en.md](CLI.en.md).
