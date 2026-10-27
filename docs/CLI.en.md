# usfc command-line reference

<p align="center"><a href="CLI.md">🇷🇺 Русский</a> · <b>🇬🇧 English</b></p>

The one complete reference for the commands, flags, answers file, environment
variables, and exit codes of usfc 5.0. For the short version, see `usfc help`
and `usfc help <command>`. The `tests/test_flags_doc.sh` test checks this page
against the code: a flag missing here, or a flag described here that does not
exist in the code, fails CI.

Coming from 4.x? The "before → after" table is in [MIGRATION-5.en.md](MIGRATION-5.en.md).

## Contents

- [Syntax](#syntax)
- [Installer](#installer)
- [Common options](#common-options)
- [Commands](#commands)
- [What to pass to apply](#what-to-pass-to-apply)
- [Answers to item questions](#answers-to-item-questions)
- [Answers file](#answers-file)
- [Exit codes](#exit-codes)
- [Environment variables](#environment-variables)
- [Ready-made commands](#ready-made-commands)

## Syntax

```text
sudo usfc [command] [arguments] [options]
```

- With no command, the menu opens.
- There is exactly one command: the first word that is not an option. You can
  put options before and after it.
- Each command has its own set of options. An option from another command is
  an error with exit code `2` and an explanation, for example
  `--json does not belong to the apply command`.
- Write an option value after a space or after `=`: `--swap 2048` and
  `--swap=2048` are the same. A value that looks like an option is an error:
  `--lang --yes` will not set the language to "--yes".
- usfc needs root because it changes system files. The `usfc()` function in
  `.bashrc` adds `sudo` for you; in scripts, write `sudo usfc …`.

## Installer

`install.sh` installs usfc to `/opt/vps-setup`, creates the
`/usr/local/bin/usfc` command, and runs it. The installer keeps only the flags
in the table below for itself and passes everything else to `usfc`.

```bash
curl -fsSL https://raw.githubusercontent.com/SkyDeaD/UbuntuServer-Fast-Configuration/main/install.sh | sudo bash
```

| Flag | What it does |
|---|---|
| `--branch <branch>`, `-b <branch>` | install from a branch, `main` by default |
| `--help`, `-h` | installer help |
| `--` | everything after it goes to `usfc`, even if it matches installer flags |

With a command, the menu does not open and no terminal is needed, which is how
usfc runs from cloud-init:

```bash
curl -fsSL https://raw.githubusercontent.com/SkyDeaD/UbuntuServer-Fast-Configuration/main/install.sh \
  | sudo bash -s -- apply web --yes
```

`bash -s --` is required: without it, bash does not pass the arguments to a
script that comes from a pipe. With no command and no terminal, the installer
does not open the menu: it reports that usfc is installed and exits with
code `0`.

## Common options

These work with any command and with no command.

| Option | What it does |
|---|---|
| `--lang ru\|en` | language for this run. Not remembered: change the permanent language with the `L` key in the menu |
| `--no-update` | don't check for a usfc update |
| `--verbose` | show full command output instead of a spinner |
| `--dry-run` | with no command, the menu in preview mode; with `apply` and `firewall`, see below |
| `-h`, `--help` | help; `usfc help <command>` for one command |
| `-V`, `--version` | version |

The update check runs only when the menu starts. Commands (`apply`, `audit`,
and the rest) don't need it: nobody watches their result in real time, and a
background request would delay the exit.

## Commands

### `usfc apply`

```text
usfc apply <what> [--dry-run] [--yes] [--config <file|https://…>] [--set KEY=value] [answer flags]
```

Applies items with no menu and no questions along the way. Answers to item
questions come from flags, the answers file, and item defaults, in that order
of priority.

| Option | What it does |
|---|---|
| `<what>` | what to apply: a profile, `all`, or item ids or numbers. See [What to pass to apply](#what-to-pass-to-apply). You can omit it if the answers file has `ITEMS=` |
| `--dry-run` | show what would be done without changing anything. The exit code is `0` even if items "did not apply": in a dry run they are not supposed to |
| `-y`, `--yes` | answer "yes" even where a question defaults to "no". The exception is the Docker restart (`--docker-restart`): it restarts containers, and `--yes` does not turn it on |
| `--config <file\|https://…>` | take answers from an [answers file](#answers-file). A URL must be `https://` |
| `--set KEY=value` | set any answers-file key right on the command line. You can repeat it |
| answer flags | `--swap 2048`, `--ufw`, `--allow 443`, and others, see the [table](#answers-to-item-questions) |

Behavior worth knowing:

- **Items that are already applied are skipped.** In the menu, choosing an
  item with `⇄` again means "turn it off", and without this rule rerunning
  from cloud-init would turn off what you asked to turn on. The exception is an
  item with new settings given explicitly: `ufw` with `--allow`, `--ping`/`--no-ping`,
  or `--docker-firewall`, `unattended` with `--reboot-time` or
  `--reboot-with-users`, and `sshhardening` with `--ssh-port`. Such an item is
  applied again and only adds the new settings.
- **`newuser` is always skipped**: it needs a name and a password.
- **`sshhardening` without `--ssh-port` is skipped** with a message: locking
  yourself out of the server because of someone else's answers file is not a
  fair price for automation. With `--ssh-port`, the item only moves the port;
  key login and the password ban are set up in the menu.
- **UFW is not enabled without consent.** Consent is `--ufw`, `UFW=Y`, `--yes`,
  or an explicit port list (`--allow`, `UFW_ALLOW`): whoever lists the ports
  knows that everything else will be closed. UFW that is already enabled needs
  no consent.
- **A flag for an item that is not in the list is an error** with exit code
  `2`: `--allow is set, but item ufw is not in the list`. The same key in an
  answers file is not an error: all nodes usually share one file.
- **`--yes` turns on "reboot even if someone is logged in"**
  (`--reboot-with-users`) if the `unattended` item is in the list. If you
  don't want that, add `--no-reboot-with-users`.
- At the end, a summary is printed as "item — result — reason", and if system
  files were edited, the rollback command: `sudo usfc restore <label>`.

### `usfc firewall`

```text
usfc firewall [--allow <ports>] [--deny <ports>] [--from <IP>] [--ping|--no-ping]
              [--docker-firewall|--no-docker-firewall] [--config <file>] [--set KEY=value]
              [--dry-run] [--yes]
usfc firewall ping on|off
usfc firewall docker on|off
```

The UFW firewall with no menu. With no options, it prints a summary: the
policy, the rules, and the state of ping and Docker.

| Option or argument | What it does |
|---|---|
| `--allow <ports>` | open ports. A disabled UFW gets enabled: with a terminal, after confirmation; with `--yes` or without a terminal, right away |
| `--deny <ports>` | remove the allow rule for ports. Only `firewall` has it |
| `--from <IP>` | apply `--allow` and `--deny` only to an address or subnet: `10.0.0.5`, `10.0.0.0/8` |
| `--ping`, `--no-ping` | answer or don't answer ping |
| `ping on\|off` | same as `--ping` and `--no-ping` |
| `--docker-firewall`, `--no-docker-firewall` | whether published ports of Docker containers obey UFW rules |
| `docker on\|off` | same as `--docker-firewall` and `--no-docker-firewall` |
| `--config`, `--set` | take the `UFW_*` keys from an answers file or the command line |
| `--dry-run` | show what would be done |
| `-y`, `--yes` | don't ask for confirmation to enable UFW |

Write ports separated by commas: `443` (that's TCP), `51820/udp`,
`1000:2000/tcp`. The server's SSH port is allowed first and never closed, not
even by `--deny`.

How it works:

- ping is turned off by editing `/etc/ufw/before.rules`: in the ICMP blocks,
  `ACCEPT` becomes `DROP` and a rule for `source-quench` is added. In
  `/etc/ufw/before6.rules`, only `echo-request` is closed: IPv6 itself needs the
  rest of ICMPv6 (neighbor discovery). `ping on` restores the files byte for
  byte.
- Docker publishes ports around UFW. `docker on` adds the ufw-docker scheme (the
  `DOCKER-USER` chain) to `/etc/ufw/after.rules`, after which only what is
  allowed reaches containers from outside. It works for IPv4 and for Docker's
  iptables backend.

### `usfc audit`

```text
usfc audit [--json]
```

Checks the server and changes nothing: disk space and inodes, memory and swap,
failed systemd units, open ports against UFW rules (TCP and UDP, including
Docker ports that bypass UFW), password login and root login, foreign sshd
drop-ins, ping, security updates, whether a reboot is needed, and certificate
expiry.

| Option | What it does |
|---|---|
| `--json` | machine-readable report |

JSON format:

```json
{
  "usfc": "5.0.0",
  "generated_at": "2026-10-23T04:00:00+00:00",
  "host": "node-1",
  "os": "Ubuntu 24.04.3 LTS",
  "lang": "ru",
  "summary": { "ok": 9, "warn": 3, "crit": 0, "total": 12 },
  "findings": [
    {"id": "ssh.password_auth", "section": "...", "level": "warn", "text": "...", "hint": "..."}
  ]
}
```

`id` and `level` (`ok`, `warn`, `crit`) don't depend on the language, so build
monitoring on them. `text` and `hint` are in the interface language. `hint`,
`value`, and `unit` appear only on findings where they make sense. The values in
the example above are illustrative.

### `usfc export`

```text
usfc export > node.conf
```

Prints an answers file based on the server's current state: `ITEMS=` from the
applied items and the values of their settings, and at the end the same setup
as a single install command. Once you've set up one node in the menu, you can
set up the next one with a single line.

- Secrets (`CF_TOKEN`, `TG_TOKEN`) are never exported: only a commented-out key
  with no value.
- The hostname is a comment too: every node has its own.
- UFW allow rules for specific addresses are not part of the file (`UFW_FROM` is
  one for all ports) and are printed as a comment so they don't get lost.
- Read-only, like `audit`.

### `usfc list`

Prints the profiles and the ids of all items.

### `usfc backups`

Prints the config snapshots from `/var/backups/usfc`, newest at the bottom. A
snapshot is taken before every edit of a system file.

### `usfc restore`

```text
usfc restore [label] [--yes]
```

Restores configs from a snapshot. The label is the snapshot directory name in
the form `YYYYMMDD-HHMMSS-PID`; the list is `usfc backups`.

| Option | What it does |
|---|---|
| `[label]` | which snapshot to restore. Without a label, it asks the terminal; without a terminal, it's an error with exit code `2` |
| `-y`, `--yes` | don't ask for confirmation |

Before a restore, it takes one more snapshot so the restore itself can be
undone. Files that did not exist before usfc are deleted on restore.

### `usfc help`

```text
usfc help [command]
```

General help, or detailed help for one command: `usfc help apply`. Same as `-h`
and `--help`.

### `usfc version`

Prints the version. Same as `-V` and `--version`.

## What to pass to apply

A profile, `all`, or item ids or numbers, comma-separated and mixed freely:
`usfc apply web,bbr,motd`. Numbers are as in the menu.

| Profile | What it includes |
|---|---|
| `minimal` | basepkgs cli unattended |
| `web` | basepkgs cli docker nginx certbot fail2ban unattended zram ufw |
| `dockerhost` | basepkgs cli docker dockerlog fail2ban unattended zram ufw |
| `secure` | basepkgs fail2ban unattended sshhardening ufw |

| No. | id | Item |
|---|---|---|
| 1 | `newuser` | User + sudo |
| 2 | `hostname` | Hostname, time, NTP |
| 3 | `bbr` | TCP BBR |
| 4 | `basepkgs` | Base packages |
| 5 | `cli` | CLI tools + starship |
| 6 | `fastfetch` | fastfetch |
| 7 | `motd` | Login greeting |
| 8 | `tmux` | tmux |
| 9 | `docker` | Docker + Compose |
| 10 | `nginx` | nginx-full |
| 11 | `certbot` | Certbot + plugins |
| 12 | `dockerlog` | Docker log rotation |
| 13 | `journald` | systemd journal cap |
| 14 | `fail2ban` | fail2ban |
| 15 | `notify` | Telegram alerts |
| 16 | `unattended` | unattended-upgrades |
| 17 | `zram` | ZRAM + swap + earlyoom |
| 18 | `sshhardening` | SSH hardening |
| 19 | `ufw` | UFW firewall |

Items are applied in table order, not in the order you listed them. For details
on each one, see [MANUAL.en.md](MANUAL.en.md).

## Answers to item questions

You can answer every question an item asks in the menu ahead of time: with an
`apply` flag, an answers-file key, or `--set KEY=value`. A flag beats the file,
and the file beats the item's default.

Yes/no flags have a "no" pair: `--sysctl` is yes, `--no-sysctl` is no. In the
answers file, write "yes" as `Y`, `yes`, `true`, `on`, `1`, or `да`, and "no" as
`N`, `no`, `false`, `off`, `0`, or `нет`. Any other value is an error, not a
quiet "no".

| Flag | Key | Item | Value | What it sets |
|---|---|---|---|---|
| `--swap` | `SWAP_MB` | zram | integer, MB, from 64 | size of the backup swap file |
| `--zram` | `ZRAM_PERCENT` | zram | 1..400 | zram size, % of RAM |
| `--zram-reconfigure`, `--no-zram-reconfigure` | `ZRAM_RECONF` | zram | yes/no | reconfigure a zram that was set up by hand |
| `--sysctl`, `--no-sysctl` | `SYSCTL` | zram | yes/no | `vm.swappiness=80`, `vm.vfs_cache_pressure=50` |
| `--nginx-autostart`, `--no-nginx-autostart` | `NGINX_AUTOSTART` | nginx | yes/no | start nginx and enable autostart |
| `--docker-autostart`, `--no-docker-autostart` | `DOCKER_AUTOSTART` | docker | yes/no | start Docker and enable autostart |
| `--lazydocker`, `--no-lazydocker` | `LAZYDOCKER` | docker | yes/no | install lazydocker |
| `--docker-restart`, `--no-docker-restart` | `DOCKER_RESTART` | dockerlog | yes/no | restart Docker to apply the log limit; this restarts containers. `--yes` does not turn it on |
| `--certbot-cf`, `--no-certbot-cf` | `CERTBOT_CF` | certbot | yes/no | Cloudflare plugin (DNS-01, wildcard) |
| — | `CF_TOKEN` | certbot | token | Cloudflare API token with the `Zone:DNS:Edit` permission. A secret: no flag |
| `--certbot-tls`, `--no-certbot-tls` | `CERTBOT_TLS` | certbot | yes/no | TLS stub files in `/etc/letsencrypt` |
| `--ufw`, `--no-ufw` | `UFW` | ufw | yes/no | enable UFW |
| `--allow` | `UFW_ALLOW` | ufw | ports | open ports: `443,51820/udp,1000:2000/tcp`. In the file, separate with spaces or commas |
| `--from` | `UFW_FROM` | ufw | IP or subnet | open ports only for this address |
| `--ping`, `--no-ping` | `UFW_PING` | ufw | yes/no | answer ping; `--no-ping` means don't answer |
| `--docker-firewall`, `--no-docker-firewall` | `UFW_DOCKER` | ufw | yes/no | make Docker container ports obey UFW |
| `--hostname` | `HOSTNAME` | hostname | name | server name: `node-1.example.com` |
| `--timezone` | `TIMEZONE` | hostname | `Area/City` | time zone: `Europe/Moscow`, `UTC` |
| `--journal-max` | `JOURNAL_MAX_MB` | journald | integer, MB | systemd journal limit |
| `--motd-clean`, `--no-motd-clean` | `MOTD_CLEAN` | motd | yes/no | turn off the stock greeting and provider scripts |
| `--starship` | `STARSHIP_PRESET` | cli | `minimal`, `git`, `powerline` | prompt style |
| `--starship-prod`, `--no-starship-prod` | `STARSHIP_PROD` | cli | yes/no | production server: hostname in red in the prompt |
| `--ssh-port` | `SSH_PORT_NEW` | sshhardening | `22` or `1024..65535` | move SSH to this port |
| `--reboot-time` | `REBOOT_TIME` | unattended | `HH:MM` or `off` | reboot at this time after updates; `off` means never |
| `--reboot-with-users`, `--no-reboot-with-users` | `REBOOT_WITH_USERS` | unattended | yes/no | reboot even if someone is logged in |
| — | `TG_TOKEN` | notify | token | Telegram bot token from @BotFather. A secret: no flag |
| `--tg-chat` | `TG_CHAT` | notify | chat_id or `@channel` | where to send: `123456`, `-100…`, `@channel` |
| `--notify` | `NOTIFY_EVENTS` | notify | `ssh,ban,reboot` | which events to send, any subset |

Secrets (`CF_TOKEN`, `TG_TOKEN`) have no flags: any user can see the command
line in `ps`. Pass them in an answers file with `600` permissions.
`--set CF_TOKEN=…` is refused with exit code 2 for the same reason.

### Moving the SSH port

`--ssh-port` moves the port in two steps so you don't lose access:

1. First run: SSH listens on both ports. UFW allows the new one, fail2ban
   watches both, `ssh.socket` restarts, and login on the new port is checked
   on `127.0.0.1`. If the check fails, everything is rolled back.
2. You check the login on the new port from your own machine.
3. A second run of the same command closes the old port.

```bash
sudo usfc apply sshhardening --ssh-port 2222   # step 1: 22 and 2222 are both listening
ssh -p 2222 user@server                        # step 2: check from another machine
sudo usfc apply sshhardening --ssh-port 2222   # step 3: 22 is closed
```

In the menu, step 3 is the question "Did the login on port 2222 work?" in the
same item.

## Answers file

A text file of `KEY=value` lines, one key per line. The keys are from the
[table above](#answers-to-item-questions), plus `ITEMS`.

```ini
# node.conf — example
ITEMS=basepkgs,cli,docker,zram,ufw
SWAP_MB=2048
ZRAM_PERCENT=75
UFW=Y
UFW_ALLOW="443 51820/udp"
UFW_PING=N
TIMEZONE=Europe/Moscow
TG_TOKEN=123456:ABC-replace-me
TG_CHAT=123456789
NOTIFY_EVENTS=ssh,ban
```

Parsing rules:

- The file is read line by line and never executed: `--config` from an
  unverified place must not be able to run commands.
- `#` starts a comment that runs to the end of the line, even inside a value.
- Spaces around a value are dropped, and one pair of `"…"` or `'…'` quotes is
  stripped.
- **An unknown key is an error** with exit code `2`: otherwise a typo like
  `UWF=Y` would quietly leave the server with no firewall. An invalid value is
  an error too.
- `ITEMS` is used only if `<what>` is not given on the command line.
- `--config https://…` downloads the file with a 20-second timeout. `http://`
  is not accepted because files can hold tokens. The URL is not written to the
  log.

For a ready-made file from a server that is already set up, use
[`usfc export`](#usfc-export).

## Exit codes

| Code | `apply`, `firewall` | `audit` | other commands |
|---|---|---|---|
| `0` | everything applied, or there was nothing to apply, or it's a dry run | no important problems | success |
| `1` | some items or actions failed | important findings (`crit`) | runtime error |
| `2` | error in the arguments or the answers file | error in the arguments | error in the arguments |

The old 4.x forms (`--apply`, `--audit`, `--list`, `--backups`, `--restore`)
exit with code `2` and print the ready-made new line.

## Environment variables

| Variable | Default | What it does |
|---|---|---|
| `USFC_LANG` | — | language for this run, `ru` or `en`; same as `--lang` |
| `USFC_NO_UPDATE` | — | non-empty: don't check for updates; same as `--no-update` |
| `USFC_VERBOSE` | — | non-empty: full command output; same as `--verbose` |
| `USFC_APT_LOCK_TIMEOUT` | `300` | how many seconds to wait for the dpkg lock. On a fresh server, `unattended-upgrades` holds it for minutes |
| `USFC_REPO_RAW_BASE` | raw link to `src` on the `main` branch | where to get modules and updates, for your own fork or to test a branch |
| `USFC_KEEP_LOCALE` | — | non-empty: don't switch the locale to `C.UTF-8` |
| `USFC_BRANCH` | `main` | branch for the installer; same as `--branch` |
| `NO_COLOR` | — | non-empty: no color. There is also no color with `TERM=dumb` or when output is not a terminal |

## Ready-made commands

See what a profile would do without changing anything:

```bash
sudo usfc apply web --dry-run
```

A new node in one command: packages, Docker, memory, and a firewall without ping:

```bash
curl -fsSL https://raw.githubusercontent.com/SkyDeaD/UbuntuServer-Fast-Configuration/main/install.sh \
  | sudo bash -s -- apply basepkgs,cli,docker,zram,ufw --allow 443,51820/udp --no-ping --swap 2048 --yes
```

A new node from an answers file taken from your server:

```bash
curl -fsSL https://raw.githubusercontent.com/SkyDeaD/UbuntuServer-Fast-Configuration/main/install.sh \
  | sudo bash -s -- apply --config https://example.com/node.conf --yes
```

Replace `https://example.com/node.conf` with the address of your own file.

Take an answers file from a configured server:

```bash
sudo usfc export > node.conf
```

Open a port for one address only:

```bash
sudo usfc firewall --allow 5432 --from 10.0.0.5
```

Reboot after updates at 4:30, only if nobody is logged in:

```bash
sudo usfc apply unattended --reboot-time 04:30 --no-reboot-with-users
```

Audit into monitoring once a day via cron:

```bash
sudo usfc audit --json > /var/lib/node_exporter/usfc.json
```

Roll back configs:

```bash
sudo usfc backups
sudo usfc restore 20261023-040000-3691 --yes
```

Replace `20261023-040000-3691` with the label from the `usfc backups` output.
