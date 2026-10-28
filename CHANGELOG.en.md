# Changelog

<p align="center"><a href="CHANGELOG.md">🇷🇺 Русский</a> · <b>🇬🇧 English</b></p>

Every notable change to this project is documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project follows [semantic versioning](https://semver.org/).

## [Unreleased]

## [5.0.0] — 2026-10-23

Modes became commands (`usfc apply web` instead of `usfc --apply web`), SSH
hardening is no longer overridden by foreign drop-ins, the swap priority is no
longer lost in fstab, and a whole section applies the same way as items one by
one. The menu has 19 items instead of 14, and the firewall learned UDP, ping
and Docker.

**This version is incompatible with the old flags.** Scripts with `--apply`,
`--audit`, `--list`, `--backups`, `--restore` exit with code `2` and print the
ready-made new line. What to rewrite and what changes on servers that are
already set up — in [docs/MIGRATION-5.en.md](docs/MIGRATION-5.en.md).

### Added

- **Commands:** `usfc apply`, `audit`, `firewall`, `export`, `list`,
  `backups`, `restore`, `help`, `version`. Each has its own options; an option
  from another command is an error with an explanation. `usfc help <command>`
  shows help for one command.
- **A server in one command.** `curl … | sudo bash -s -- apply <items> <flags>`
  installs usfc and runs the command right away, with no menu and no terminal.
  Every answer-file key has a flag (`--swap`, `--allow`, `--ssh-port`,
  `--reboot-time`…), plus a generic `--set KEY=VALUE`. A flag beats the
  answers file. `--config` also takes an `https://` address.
- **`usfc firewall`** — ports without the menu: `--allow 80,443,51820/udp`,
  `--deny`, `--from <IP>`, `ping on|off`, `docker on|off`.
- **`usfc export`** — an answers file for the current server and a one-line
  command that repeats it on a new one. Secrets are never exported.
- **New items:** "Hostname, time, NTP" (`hostname`), "TCP BBR" (`bbr`),
  "Login greeting" (`motd`, a server card instead of the stock motd, with
  rollback), "systemd journal cap" (`journald`), "Telegram alerts" (`notify`:
  SSH logins, fail2ban bans, reboot required; the token never reaches the log,
  argv or export).
- **Firewall:** listening TCP and UDP ports with the process name, an editable
  list, ranges and `--from`; SSH is allowed first. Ping replies can be turned
  off by editing `before.rules` (`ping on` restores the file byte for byte).
  Docker is tied to UFW through `DOCKER-USER`, so published container ports
  are no longer open past the firewall.
- **SSH port move** in two steps: first both ports are listened on (UFW,
  fail2ban and `ssh.socket` are taken care of), and the old one is closed only
  after a login on the new one is confirmed. Works without the menu too:
  `usfc apply sshhardening --ssh-port N`.
- **Reboot window** for unattended-upgrades: `--reboot-time 04:00`,
  `--reboot-with-users`, in its own file `52usfc-reboot`.
- **CLI block:** three starship presets (`minimal`, `git`, `powerline`, no
  Nerd Font needed), functions `ports`, `dps`, `extract`, `myip`. A user
  alias with the same name doesn't break the block.
- **lazydocker**, optional in the Docker item — from the GitHub release with
  its sha256 verified.
- **Passwordless sudo** for a key-only user — asked, default yes: with a
  locked password the `%sudo` rule does not let the user in at all.
- **Menu:** ranges `1-5`, a three-line legend, an input error shown above the
  prompt instead of vanishing after a second, a one-line result after a single
  item, a "why" column for skipped items in the batch summary.
- **Audit:** keyboard-interactive, a foreign drop-in overriding hardening, UDP
  ports, ping, Docker ports past UFW.
- **Documentation:** the reference [docs/CLI.en.md](docs/CLI.en.md) is the only
  one, and `test_flags_doc.sh` checks it against the code in both directions;
  [docs/MIGRATION-5.en.md](docs/MIGRATION-5.en.md),
  [docs/TROUBLESHOOTING.en.md](docs/TROUBLESHOOTING.en.md). The README got
  shorter.

### Changed

- **SSH hardening writes `00-usfc-hardening.conf`** instead of
  `10-hardening.conf` (the old one is removed on apply). Foreign lines that
  would override ours are found up front and commented out with your consent.
  After the restart every key is checked through `sshd -T`; on a mismatch the
  change is rolled back and the mismatched keys are listed. Added
  `KbdInteractiveAuthentication no`; `AllowUsers` only after a separate
  question.
- **fail2ban** writes its own `/etc/fail2ban/jail.d/usfc-sshd.local` with
  `backend = systemd` and leaves `jail.local` alone. Debian 12 has no
  `auth.log`, and the old jail found no log.
- **Batch mode asks the same questions as manual mode**, only up front and
  after the list is confirmed. Before, questions defaulting to "no" silently
  became "no": certbot TLS templates were never installed, UFW was not enabled
  even in the `web` and `secure` profiles. User creation goes first and
  interactively.
- **`--yes` no longer restarts Docker** in the `dockerlog` item: that needs an
  explicit answer or `--docker-restart`.
- **`usfc audit` returns `1`** on critical findings.
- **Items on the command line beat `ITEMS=`** in the answers file; values in
  the answers file are validated, garbage is an error with code `2`.
- **The update check** runs only when the menu starts, not in `apply` or
  `audit`.
- **fastfetch** runs only on SSH login, not inside tmux and not when the motd
  card is installed.
- **Snapshots** remember files that did not exist, and `restore` removes them.
  The first copy of a file per run is kept, not the last.
- `/etc/default/zramswap` is edited in place; with `systemd-zram-generator`
  present, zram-tools is not installed on top. Reconfiguring zram doesn't turn
  swap off if what's in use there doesn't fit into free memory.
- **`apply` again with new answers.** An item that is already applied is no
  longer skipped silently when new settings are given for it: `--hostname`,
  `--journal-max`, `--starship`, `--tg-chat`, `--swap`, and others. The full
  list is in [docs/CLI.en.md](docs/CLI.en.md#usfc-apply).
- **Choosing `unattended` or `notify` again in the menu** asks "set it up
  again?" and turns the item off only on "no".
- `/etc/fstab` is written atomically: a temporary file and `mv`, keeping the
  mode and owner.

### Fixed

- **The swap priority was lost in fstab.** `sed` understood one form of the
  line and silently skipped `defaults`, `sw,nofail`, `pri=5`, `UUID=` and
  `LABEL=`, and mangled `swap swap` into `sw,pri=10ap`, while the item printed
  "priority 10". Now the line is parsed by fields (on LVM too, where `swapon`
  shows `/dev/dm-N`), the result is verified, and the item status shows `!`
  when fstab has no priority.
- **btop: "~/.config could not be created".** `~/.config` was created as root;
  now every level belongs to the user, and an already broken one is repaired.
- `restore ..` could point at `/var`: the label is now checked against its
  format.
- `.bashrc` blocks without an end marker removed everything to the end of the
  file.
- Update: the new version is downloaded in full before replacing, and the
  previous one is restored on failure.
- fail2ban did not reread its config after writing; a failed service start,
  `apt install`, starship or fastfetch looked like success in the summary.
- An existing user's password was locked when item 1 was applied again; a key
  was glued to the last line of `authorized_keys` without a newline.
- Ctrl+C did not stop a run.
- `cloudflare.ini` was emptied before its snapshot.
- **UFW could cut off SSH during a port move.** Enabling UFW allowed one SSH
  port; now it allows every port sshd listens on, and if SSH listens nowhere,
  UFW is not enabled. `--deny` protects all SSH ports.
- **Ctrl+C in the middle of an SSH port move** could leave the config without
  a `Port` line. Now an interrupt rolls the move back. The SSH hardening
  rollback uses its own snapshot instead of the session's first one, which
  could hold an old `Port`.
- The updater and the installer, when they fail halfway, restore the old
  `lib`, `setup.sh`, `MODULES`, and `VERSION` together, not just `lib`.
- `install.sh` took a flag's value for a command (`--hostname list`).
- `--ufw=Y` gave "unknown option" and now gives a clear hint;
  `usfc help apply firewall` is an error instead of help for the last topic;
  `HTTPS://` in `--config` is accepted in any case.
- zram: `zram-generator.conf` is edited in place and other sections are kept;
  priority 10 goes to every on-disk swap, not just the last one.
- motd: symlinked scripts no longer strip `+x` from a package file outside
  `/etc`; turning the card off asks for confirmation; a stale `motd.orig` is
  overwritten.
- dockerlog: another `log-driver` is no longer overwritten with `json-file`,
  and a failed `daemon.json` write or a missing `python3` no longer looks like
  success.
- bbr in a container writes no files and doesn't fail on `sysctl -p`.
- hostname: `preserve_hostname` for cloud-init is written even when the name
  already matches.
- notify: the SSH alert status checks the `pam_exec` line itself, not just
  the marker.
- The journald status no longer runs `journalctl --disk-usage` on every menu
  frame; the journal size is shown again, via `du`.
- Ctrl+C during SSH hardening rolls back `sshd_config`, edits to other
  drop-ins and our own drop-in; if sshd was already restarted, it is
  restarted again with the old settings.

### Removed

- The mode flags `--apply`, `--audit`, `--list`, `--backups`, `--restore`
  (code `2` and a hint with the new line).
- The flag reference in the README — it now lives in
  [docs/CLI.en.md](docs/CLI.en.md).

## [4.2.0] — 2026-08-21

The one-line install finally accepts arguments, sysctl stopped silently not
applying, the interface stopped leaking Russian into English, and four new
things arrived: btop, a first-run wizard, item preview, and a machine-readable
audit.

### Added

- **Installing with arguments.** `curl … | sudo bash -s -- --apply web` now
  installs and applies in one go, without opening the menu, and needs no
  terminal. This used to be impossible: the installer did `exit 2` on any
  unknown flag, and the final `exec setup.sh </dev/tty` forwarded nothing and
  demanded a controlling terminal — under cloud-init it failed with `No such
  device or address`, so the install ended in an error on its last step even
  though the files were already in place. The installer keeps only `--branch`
  and `--help` for itself.
- **First-run wizard.** One question — "what is this server for?" — instead of
  fourteen items, and the answer turns into a ready-made profile. You can
  decline at any point; every outcome leads to the regular menu.
- **The `V` key — item preview.** Shows what an item would do, changing
  nothing. Previously you had to quit and restart with `--dry-run`.
- **`usfc --audit --json`** — the same audit, machine-readable, for monitoring,
  Ansible and cron. Every finding carries a stable, language-independent `id`.
- **btop** in the CLI tool set, plus an `htop='btop'` alias. htop stays
  installed: the alias merely shadows it.

### Fixed

- **sysctl for zram was not applied during a batch run.** The line
  `[ "$cur_sw" != "60" ] || [ "$cur_vfs" != "100" ] && sysctl_default=N`
  parses as `(A || B) && C`, so "yes" only came up on an untouched machine with
  exactly 60/100 — and in batch mode `ask_yn` with a "no" default silently
  returns no without showing the question. The answer is now asked up front,
  together with the zram percentage and the swap size.
- **Russian text leaked into the English interface** — 68 places: "applied N of
  14" in the header, uptime units, "[dry run]", "failed/done/skipped" in the
  summary, "waiting for the dpkg lock", "N package(s)", all 19 package
  descriptions, the entire alias table on screen `H`. Closed by a guard,
  `tests/i18n_scan.py`: a source line with Cyrillic outside a comment must be
  a call of the `t()` family with two string arguments.
- **The dry run did not intercept `cp`, `mv` and `ssh-keygen`.** The SSH
  hardening item runs `cp /etc/ssh/sshd_config .bak.$(date +%s)`, so a dry run
  would litter `/etc/ssh` with a copy on every pass. It never surfaced because
  `--apply all --dry-run` filters that item out.
- **A newly added alias never reached already-configured machines**: the CLI
  item bailed out on the mere presence of the block marker in `~/.bashrc` —
  silently, while reporting success. The block now carries a version number.
- **The column header on screen `H` was not truncated**, and the English
  `What it does` broke the frame on a narrow terminal.
- **`-y/--yes` was lying**: declared as general, read in exactly one place. It
  now works only together with `--apply` and only on the questions of the items
  being applied — it cannot be global, since 24 of the 62 questions have a
  protective "no" default.
- The audit printed a second finding, "Details: systemctl --failed", and
  immediately decremented the counter — in JSON that would have produced a
  phantom record.

## [4.1.0] — 2026-08-11

zram that silently did not work on cloud images, an honest uninstall, and an
English CHANGELOG.

### Added

- **The `U` key now removes usfc completely.** Previously only
  `/opt/vps-setup` and the `usfc` command went away, leaving the log, the
  config snapshots and a block in `~/.bashrc` behind — that is, a `usfc()`
  function calling a command that no longer exists. You "removed" it and got
  a broken shell.

  Now a list with sizes comes first — exactly what will go, including
  `/var/log/usfc.log` with its rotation and the wrapper block in **every**
  home directory it could have landed in (the user created by item 1 gets the
  wrapper too). Config snapshots are a **separate** question and stay by
  default: they are the only way to bring `sshd_config` and `fstab` back to
  what they were before usfc, and wiping them together with the log means
  closing the way back at the exact moment someone is leaving. Only then comes
  the overall confirmation.

  The boundaries are the same and deliberate: packages, Docker, nginx and the
  sshd changes are left alone (rollback commands are on screen `I`), and so are
  the `vps-setup:cli` and `vps-setup:fastfetch` blocks — those belong to the
  items, not to the script. Running from a cloned repository is guarded
  separately: `USFC_ROOT` points at the working copy there, and a "remove the
  script" button must not delete it.

- **`CHANGELOG.en.md`** — the last document in the repository without an
  English counterpart. Sections, versions and entries match the Russian file
  one to one, and there is a language switcher between them.
- **The notes for all six releases are now bilingual and half as long**:
  Russian on top, English under `<details>`. They were 520–730 words per
  release and are now 230–265 per language — the filler is gone, the facts and
  measurements stayed.

### Fixed

- **zram silently did not work on cloud images.** The service failed on every
  boot:

  ```
  modprobe: FATAL: Module zram not found in directory /lib/modules/6.8.0-137-generic
  Error: inserting the zram kernel module
  ```

  On some Ubuntu images `zram.ko` lives not in the main modules package but in
  `linux-modules-extra`, which cloud images usually do not ship. The script did
  not know this and advised "try by hand: systemctl restart zramswap" — advice
  that could not possibly help, because by hand you get exactly the same thing.

  The module is now checked **before** zram-tools is installed, and the item
  tells five states apart: the module is there; it lives in a separate package
  (it will ask permission and fetch it, naming the download size — the number
  comes from apt, not from a figure baked into the text); the machine is a
  container with no kernel of its own; the kernel was upgraded without a
  reboot; the kernel is provider-built and there is nowhere to get the module
  from. In the last cases the reason is stated plainly and the failing service
  is disabled along with a reset of its `failed` state — otherwise it would
  keep showing up red in `systemctl --failed`. Swap and sysctl are configured
  as usual: zram is only part of the item.

  The five states are covered by `tests/test_zram_module.sh`: they cannot be
  assembled on one machine, so exactly four external points are stubbed —
  `modinfo`, `systemd-detect-virt`, `uname` and apt.
- **The audit said "Swap is present (zram)" where zram was off or broken.**
  The tag came from a `${ZRAM_ACTIVE:+ …}` substitution, which fires on any
  non-empty string — including the word `false`, i.e. always. Plus a separate
  audit line about zram: enabled but not running, and why.
- **The self-update progress printed escape sequences literally:**

  ```
  \033[2m[ 1/38]\033[0m lib/core.sh ✓
  ```

  The single place in the whole codebase where a colour reached `printf` via
  `%s` instead of `%b`: colours are strings like `'\033[2m'`, and printf
  expands those only in the format itself and in `%b`. It was visible only
  during a real update, which is how it survived into a release.
- **The test that should have caught this stayed silent.** The `| grep -q` ban
  added in 3.0.1 scanned only `src/setup.sh` — and went quiet after the
  monolith was split in 4.0.0: all the logic moved into `lib/`, and the loader
  has no such code by definition. Verified with a deliberate regression: a
  `grep -q` inside a module went unnoticed. Both static checks now scan the
  loader and every module from the manifest, and both were verified by
  breaking them.

## [4.0.1] — 2026-08-10

Installing via `curl | bash` hung after the modules downloaded — for two
independent reasons at once.

### Fixed

- **The install hung silently** before reaching the menu: all 38 modules
  downloaded, "usfc 4.0.0 installed" was printed — and then nothing.

  The installer was at fault. It ran `exec < /dev/tty` for the CURRENT shell,
  but under `curl | bash` the script itself is read from stdin: by replacing
  stdin we made bash read the remaining commands from the terminal. It never
  got as far as the line that starts the menu.

  The redirect is attached to the launched command only again —
  `exec "${INSTALL_DIR}/setup.sh" </dev/tty`, as it was before 4.0.0. Verified
  with a real `curl | bash` on a pseudo-terminal.
- **The update check reported "no network or no VERSION file in the repo"**
  while checking neither: the request for `VERSION` from the same machine takes
  0.3 s and answers. The real cause was that the background `curl` lived in the
  same process group as the script, so Ctrl+C killed the check mid-flight. The
  check now moves into its own session (see the next entry), where the
  terminal's signal cannot reach it; an empty result triggers one synchronous
  retry; and the message no longer names a cause it never verified
- **The install froze solid right after the language question** — the same
  trouble as in the first entry, but with a different cause that went unnoticed
  then. The first fix removed only one of the two obstacles.

  Measured on Ubuntu 26.04 (which already ships `sudo-rs` and
  `Defaults use_pty`):

  ```
  strace: --- SIGTTIN {si_signo=SIGTTIN, si_code=SI_KERNEL} ---
          --- stopped by SIGTTIN ---
  ps:     T+  curl -fsSL --max-time 5 …
  ```

  `sudo` runs the script inside its own pseudo-terminal session, and on the
  very first terminal read the process group turns out to be a background one.
  The kernel sends SIGTTIN to the **whole group** — the background update check
  receives it along with the script. `sudo` then revives the script but knows
  nothing about the check: it stays stopped forever, and the wait on it never
  ends.

  The condition takes exactly two ingredients: the script arrived at `sudo`
  through a pipe **and** the language question is asked. That is why running an
  already installed `usfc` worked while the one-line install from the README
  did not.

  The check now lives in its own session (`setsid`), where group signals cannot
  reach it, and waiting for its result is bounded: a missed check costs a line
  of output, a frozen start costs the whole tool.
- **The `L` key switched languages instantly, asking nothing.** The logic was
  copied from the `⇄` items, where picking again means "do the opposite" — but
  there the action changes the system and therefore always asks, and
  "the opposite" language stops making sense the moment there are more than
  two. `L` now shows the same list as on first run, marking the current choice;
  Enter cancels.

## [4.0.0] — 2026-08-10

The tool stopped being a single 3674-line file. It runs on Debian, speaks
English, fits into cloud-init, and can tell you what is wrong with the server.

### Added

- **English interface.** The language is asked on first run in both at once —
  at that point there is no telling which one you read — is remembered, and is
  changed with the `L` key in the menu. The `--lang` flag applies to one run
  and saves nothing
- **Debian 12 and 13 support** and an honest OS gate: there was no check at all
  before, and on an unsupported system the script died somewhere in the middle
- **Non-interactive mode** for cloud-init, Ansible and provisioning scripts:
  `--apply`, `--config`, profiles `minimal`/`web`/`dockerhost`/`secure`, exit
  codes for CI
- **Dry run** `--dry-run`: shows what would be done and changes nothing. Its
  completeness is covered by a test — the system snapshot before and after must
  match
- **Server audit** (`--audit`, key `D`): disk space and inodes, memory and
  swap, failed units, externally reachable ports against the UFW rules,
  password login, security updates, certificate expiry. Read-only, and that is
  checked by a snapshot too
- **Config snapshots** (`--backups`, `--restore`): a copy is taken
  automatically before any system file is overwritten

### Changed

- **The monolith is split into 38 modules.** The entry point `src/setup.sh`
  stayed a loader — renaming it was impossible: installed copies update by that
  name, and a 404 would have left them without updates forever
- **A menu item = one file.** It used to be smeared across six parallel arrays
  kept in sync by hand. Now each file registers itself, and adding an item is
  one file plus a line in the manifest
- **Updates became transactional**: everything downloads into a separate
  directory, is verified, and only then swapped in one move. If the network
  drops, the working install is untouched. A file-by-file update would have
  left a new setup.sh with old modules
- The installer shows every file as it downloads and supports `--branch`

### Fixed

- **`--dry-run` changed the system.** Intercepting at the narrow spots was not
  enough: direct calls and redirections slipped past. The commands themselves
  are now shadowed, and writes to system files go through a single point
- **`--apply` disabled what was already applied.** In the menu, picking a `⇄`
  item again means "toggle", and the same logic in non-interactive mode did the
  opposite of what was asked
- **Rollback reported success while returning what you were escaping from**:
  the pre-restore snapshot landed in a directory with the same timestamp and
  overwrote the one being restored
- The loader treated healthy modules as broken: the status of `source` is the
  status of the file's last command, and `lib/ident.sh` ends on a condition
  that is false on a normal install
- Aliases could break `ls`: the check was "neither `eza` nor `batcat`" and
  missed the mixed case — exactly the one you meet on Debian 12
- The `docker` profile collided by name with an item id, and `--apply docker`
  expanded into eight items instead of one

## [3.0.1] — 2026-08-07

Bug fixes from live runs.

### Fixed

- **`| grep -q` under `set -o pipefail` — the condition was always false.**
  `grep -q` exits on the first match and closes the pipe; the producer
  (`apt-cache`, `locale -a`, `ufw status`) takes SIGPIPE and dies with 141, and
  `pipefail` makes 141 the status of the whole pipeline. The "was it found"
  check answered "not found" precisely when it was found and the output was
  long — that is, on a real server but not in a short test.

  It was most visible with Docker: the "are there packages for our codename"
  check never fired, and every machine printed

  ```
  [!] Docker has no packages for 'noble' yet — switching to noble (24.04, compatible)
  ```

  — that is, "switching from noble to noble", plus a pointless `apt-get
  update`. Fixed in all nine places: locale selection, `ufw status`, the
  `python3-cloudflare` version, the user's `docker` group, three `swapon`
  checks, the key self-check during SSH hardening, and Docker itself
- The Docker fallback no longer offers to switch to noble when the system is
  noble already: there is nowhere to switch, and instead of a meaningless
  message the item stops honestly and says where to look at the log
- **The sysctl block did not show the result.** A line with the old numbers was
  printed, followed by an unconditional "sysctl applied" — which read as
  "recommended, but not done". The values are now re-read from `/proc` and the
  transition is shown:

  ```
  [i] Currently: swappiness=60, vfs_cache_pressure=100 (80/50 recommended)
  [✓] sysctl applied: swappiness 60 → 80, vfs_cache_pressure 100 → 50
  ```

- **`umask 077`, set while writing the Cloudflare token, was never restored**
  and stayed in effect for the rest of the run. `cloudflare.ini` itself came
  out correct (600), but every config the items after Certbot wrote next —
  `daemon.json`, `20auto-upgrades`, `99-zram.conf`, `10-hardening.conf` — was
  created with 600 instead of 644. The file is now created with the right mode
  from the start (`install -m 600`), and `umask` is not touched at all
- Permissions of a pre-existing `cloudflare.ini` were never checked: the file
  might not have come from the script, yet the "file already there" branch
  reported green. Permissions are now checked and, with confirmation, fixed.
  The Certbot item's status also stopped showing a green tick for a file
  anyone can read

### Added

- A regression guard for `| grep -q`: the pattern is banned throughout
  `setup.sh`. The bug does not reproduce on short output, so the pattern itself
  is caught rather than the behaviour — plus a check that the SIGPIPE mechanism
  still works as described
- Tests for `cloudflare.ini` permissions. The threshold is exactly certbot's
  own: it looks only at the "other" bits, so 640 and 660 are safe while 644 is
  not

## [3.0.0] — 2026-08-06

Services toggle straight from the menu, the table is aligned, help and rollback
are merged into one screen.

### Added

- **Managing nginx and Docker from the menu.** On an installed system items 6
  and 7 act as switches: they show the current state and offer the opposite —
  stop a running service or bring up a stopped one together with autostart.
  Declining autostart at install time used to be a permanent decision
- An "already installed" branch for the Docker item. Without it, picking the
  item on a system with Docker went into a full reinstall — key, repository,
  `apt install`
- "Remove completely" commands filled in for all 14 items: five security items
  had none at all
- `CHANGELOG.md` — version history in one file
- `ensure_pkg` — installs only the missing packages from a set and does not
  touch apt when there is nothing to install
- A column-alignment test: it runs the real `show_menu` and `show_item_help`
  and checks that item numbers and `⇄` marks line up

### Changed

- **The `⇄` mark is right-aligned within its column.** It used to stick to the
  end of the name, leaving a ragged edge
- The mark also appeared in the services section. Before that it only showed up
  under "security" and read as "the rest cannot be rolled back". All 14 of 14
  can be rolled back, just in two ways: `⇄` right in the menu, everything else
  via `apt purge` using the commands from the help. The legend now says so
  directly
- Item numbers are right-aligned — 1..9 and 10..14 line up
- **Screens `R` and `I` are merged.** The separate rollback screen took ~74
  lines, fit in no ordinary terminal, and duplicated the help. The `R` key
  still works and opens the same help
- Certbot status without the Cloudflare plugin: was `✓ certbot + nginx`, now
  `✓ certbot + nginx, no CF`. The old line listed what was installed honestly,
  but the green tick read as "everything is there"

### Fixed

- **`systemctl disable --now docker` did not disable Docker.** Only
  `docker.service` went down while `docker.socket` stayed `enabled/active` —
  the daemon came back on the first access to `/var/run/docker.sock`, and the
  status said "autostart off". Both units now move together, with the socket
  coming up first: otherwise the service creates the socket itself and
  `docker.socket` cannot bind to it
- Some items ran `apt install` without checking whether the package was already
  there: on an installed system that is a no-op, but `apt update` still went
  over the network first
- The "package manager busy" warning is gone: it guessed via `pgrep` and
  printed on the mere fact that `unattended-upgrades` was running. In a test
  with a deliberately held lock it named the wrong process
- The legend line about disabling items did not fit even in 120 columns, and
  promised something untrue on top of that

## [2.0.0] — 2026-08-06

Speed, working on a bare VPS, and looks. The largest shift in the project.

### Added

- **The "User + sudo" item**: creates a user with sudo, copies the SSH keys
  from `/root` to them, and switches further configuration to that user inside
  the running session. Many hosts hand you a VPS with only `root`, and SSH
  hardening without a separate user makes no sense at all
- **The "Certbot + plugins" item**: `certbot` was taken out of the base
  packages — TLS is a service with its own plugins and secrets. The
  `dns-cloudflare` plugin for wildcards, creating `cloudflare.ini` with an API
  token, and copying `ssl-dhparams.pem` and `options-ssl-nginx.conf` from the
  certbot package: issuing via `certbot certonly` does not create them, and a
  stock nginx config then kills the server
- **Swap size management**: the current size is shown next to the recommended
  one, and if they differ by more than 10% you are offered a rebuild. The
  rebuild is fenced with checks: swap files only, refusal if what is in use
  will not fit into RAM, the path stays the same, a `dd` fallback for btrfs
- **Per-item help** (key `I`): a list of all items, and by number a full
  description with status and the way to roll it back
- A package breakdown after installation: one line per package, `+` — arrived
  just now, `·` — was already there
- The question about nginx and Docker autostart comes before installation and
  defaults to "no". So that "do not start" means exactly that, the installation
  is wrapped in `policy-rc.d`
- A log of every command in `/var/log/usfc.log` with rotation, a summary after
  a bulk run, and `[N/M]` headers on each item
- `NO_COLOR` support; colour switches itself off under `TERM=dumb` and when
  output is not a terminal
- The `C` menu section and the `--help`, `--version`, `--no-update`,
  `--verbose` flags
- CI: `bash -n`, `shellcheck` and layout unit tests in four locales

### Changed

- **Menu rendering: 1464 ms → 15 ms per frame, startup 3.1 s → 0.6 s.** The
  network was not the cause: the layout helpers spawned `python3` for EVERY
  table cell — about 90 processes for one screen. All of it was rewritten in
  pure bash, plus one `dpkg` snapshot instead of ~25 `dpkg -s` calls, a status
  cache between redraws, and one `sshd -T` instead of three
- The swap size formula: was "10% of free disk space", became
  `min(RAM, free/4)` clamped to 512–4096 MB. The old one knew nothing about the
  amount of memory
- The spinner explains what it is waiting for: it reads the reason and the name
  of the holding process from apt's own message instead of guessing via `pgrep`
- The "Section" column is gone and section names became group subheadings — the
  status gained 13 columns and package lists stopped being truncated
- Looks: rounded frames, a gradient on the logo with a fallback to flat colour
  on a poor palette, a machine summary and an "applied N of 14" counter
- The questions before a bulk run explain what they are about: `zram`, service
  autostart, the Cloudflare plugin
- Passwords shorter than 8 characters are no longer accepted: the server faces
  the internet, and it is brute-forced around the clock

### Fixed

- **Installation failed with `code 100, 0s` on a freshly booted server.**
  `unattended-upgrades` held the dpkg lock and apt did not wait at all:
  `DPkg::Lock::Timeout` defaults to zero. The irony is that usfc enables
  `unattended-upgrades` itself
- **The script would not start at all on a machine without a login session** —
  the very scenario it was built for. `logname` prints "no login name" to
  stderr and exits with status **zero**, so `logname || echo root` never fired
  and the user name stayed empty
- `declare -A` without `=()` crashed the script on the very first screen under
  bash 5.3 (`unbound variable`)
- It offered to copy keys when there were none: the condition looked at file
  size rather than a count. Any non-empty lines were copied too, comments
  included
- A weak password was accepted: a warning was printed, but the password was set
  anyway
- The Cloudflare plugin was silently skipped in `A` mode — the question went to
  its "no" default without being shown
- Colour was lost when truncating a status: GNU `grep -E` does not understand
  `\x1b`; `pad_title` measured the raw string including escape bytes;
  `status_marker` cut the first **byte** instead of the first character, and in
  a byte-wise locale the markers fell apart
- `tput cnorm` mixed control sequences into the output even without a spinner,
  and the screen was cleared outside a terminal
- `tests/test_layout.sh` degraded silently without `python3`: the reference
  functions fell back to byte-wise counting and compared against knowingly
  wrong numbers — the tests "passed" while checking nothing

## [1.0.0] — 2026-07-15

First public release. A menu script that turns a clean Ubuntu 24.04/26.04 VPS
into a configured server in one pass.

### Added

- 12 menu items: base / services / security — one at a time or in bulk
  (`A`, `B`, `S`, `P`)
- Modern CLI replacements: `eza`, `bat`, `fd`, `ripgrep`, `zoxide`, `starship`
- Docker CE + Compose from the official repository, nginx-full, log rotation
- fail2ban, unattended-upgrades
- ZRAM + a backup swap file + earlyoom
- SSH hardening with a mandatory self-check and automatic rollback on failure
- UFW that detects ports already in use (Docker/nginx do not get cut off)
- Self-update on every run (`sudo usfc`)

[5.0.0]: https://github.com/SkyDeaD/UbuntuServer-Fast-Configuration/compare/v4.2.0...v5.0.0
[4.2.0]: https://github.com/SkyDeaD/UbuntuServer-Fast-Configuration/compare/v4.1.0...v4.2.0
[4.1.0]: https://github.com/SkyDeaD/UbuntuServer-Fast-Configuration/compare/v4.0.1...v4.1.0
[4.0.1]: https://github.com/SkyDeaD/UbuntuServer-Fast-Configuration/compare/v4.0.0...v4.0.1
[4.0.0]: https://github.com/SkyDeaD/UbuntuServer-Fast-Configuration/compare/v3.0.1...v4.0.0
[3.0.1]: https://github.com/SkyDeaD/UbuntuServer-Fast-Configuration/compare/v3.0.0...v3.0.1
[3.0.0]: https://github.com/SkyDeaD/UbuntuServer-Fast-Configuration/compare/v2.0.0...v3.0.0
[2.0.0]: https://github.com/SkyDeaD/UbuntuServer-Fast-Configuration/compare/v1.0.0...v2.0.0
[1.0.0]: https://github.com/SkyDeaD/UbuntuServer-Fast-Configuration/releases/tag/v1.0.0
