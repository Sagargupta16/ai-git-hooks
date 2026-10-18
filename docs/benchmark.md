# Secret Scan Benchmark

How well does a regex secret scan in Bash do, and where should you reach for
gitleaks instead? This page answers with measurements, not claims.

Generated on 2026-10-18 with:

```bash
GITLEAKS_VERSION=8.30.1 ./scripts/benchmark.sh --gitleaks --noise
```

on Windows 11 under Git Bash (bash 5.3, git 2.55), with gitleaks 8.30.1 built
by `go install`. The corpus commit and project tags are pinned in
[`scripts/benchmark.sh`](../scripts/benchmark.sh), so a re-run scans the same
bytes.

## How to read it

- **leaky-repo** is a public corpus of fake credentials in 44 real-world file
  formats (shell profiles, Docker and npm configs, FileZilla, `.netrc`,
  `/etc/shadow`, WordPress and Laravel config, SQL dumps). Its ground truth
  counts both "risk" lines (a usable credential) and "informative" lines
  (usernames, hostnames), so no secret scanner is meant to reach 100%.
  The scoring is leaky-repo's own, so the figures line up with the tables it
  publishes for other tools.
- **Noise check** scans four clean, popular projects. Every finding there would
  block a push. On these projects all of them are deliberate examples or test
  fixtures: TLS private keys under `tests/certs`, hardcoded session secrets in
  Express's example apps, and credential-bearing URLs and `.netrc` lines in the
  requests test suite.
- Both tools are counted by distinct `file:line`, so one line that matches two
  rules counts once.

What it says: on this corpus the pre-push scan finds more config-file
credentials than gitleaks' default rules (34 lines against 22). The difference
is password hashes (10 bcrypt hashes in a SQL dump, plus `/etc/shadow`,
`.htpasswd` and ProFTPD), quoted password fields in SFTP, IDE and DBeaver
configs, `.netrc`, `.git-credentials` and a PuTTY key, where gitleaks' defaults
flag nothing. gitleaks in turn finds the AWS credentials files, shell-profile
exports and the Rails `secrets.yml`, where this scan flags nothing.

Before the 1.2.0 rules the same benchmark scored the scan at 5/175 lines in
5/44 files: the old rules only accepted `password = "..."` with `=`, so every
JSON and YAML config slipped past. The noise check was re-run after each rule
change. The first draft of the new rules produced 31 findings on requests; a
6-character minimum on URL and `.netrc` passwords took that to 11, and making
the npm `_auth` keys start a line (so `old_auth = ...` in Python is not a
credential) took it to 10.

That is a narrow win: the scan has 40
patterns, while gitleaks 8.30.1 ships 222 default rules (130 of them with an
entropy threshold) covering far more token formats. gitleaks is the better
general scanner; this hook is a zero-dependency push gate. Use both if you can.

Counted with `grep -c '^\[\[rules\]\]'` and `grep -c '^entropy'` on gitleaks'
`config/gitleaks.toml` at v8.30.1, and by counting the `SECRET_PATTERNS` entries
in `hooks/pre-push/security-scan.sh`.

## Results

Corpus: [leaky-repo](https://github.com/Plazmaz/leaky-repo) at `2e95135`, 44 files.
Scored with leaky-repo's benchmark.py method (see the header of `scripts/benchmark.sh`).

### ai-git-hooks pre-push

- Files covered: 21/44 (47.7%)
- Lines found: 34/175 (19.4%)
- False positives: 0

### gitleaks 8.30.1 (default rules)

- Files covered: 13/44 (29.5%)
- Lines found: 22/175 (12.6%)
- False positives: 0

### Noise check on clean projects

| Project | Files | ai-git-hooks findings | gitleaks findings |
|---------|-------|-----------------------|-------------------|
| express v5.3.0 | 214 | 5 | 0 |
| requests v2.34.2 | 129 | 10 | 4 |
| flask 3.1.3 | 235 | 0 | 6 |
| react-hook-form v7.69.0 | 475 | 0 | 0 |

ai-git-hooks findings on these projects:

- `express/examples/auth/index.js:25`
- `express/examples/cookie-sessions/index.js:13`
- `express/examples/mvc/index.js:43`
- `express/examples/session/index.js:19`
- `express/examples/session/redis.js:23`
- `requests/docs/user/advanced.rst:631`
- `requests/tests/certs/expired/ca/ca-private.key:1`
- `requests/tests/certs/expired/server/server.key:1`
- `requests/tests/certs/mtls/client/client.key:1`
- `requests/tests/certs/valid/server/server.key:1`
- `requests/tests/test_utils.py:161`
- `requests/tests/test_utils.py:169`
- `requests/tests/test_utils.py:178`
- `requests/tests/test_utils.py:457`
- `requests/tests/test_utils.py:466`

### Per file

| File | ai-git-hooks found/expected | false pos | gitleaks found/expected | false pos |
|------|-----------------------------|-----------|-------------------------|-----------|
| `.bash_profile` | 0/11 | 0| 3/11 | 0 |
| `.bashrc` | 0/6 | 0| 2/6 | 0 |
| `.docker/.dockercfg` | 2/4 | 0| 2/4 | 0 |
| `.docker/config.json` | 2/4 | 0| 2/4 | 0 |
| `.mozilla/firefox/logins.json` | 0/28 | 0| 0/28 | 0 |
| `.ssh/id_rsa` | 1/1 | 0| 1/1 | 0 |
| `.ssh/id_rsa.pub` | 0/1 | 0| 0/1 | 0 |
| `cloud/.credentials` | 0/4 | 0| 2/4 | 0 |
| `cloud/.s3cfg` | 0/3 | 0| 2/3 | 0 |
| `cloud/.tugboat` | 0/3 | 0| 1/3 | 0 |
| `cloud/heroku.json` | 0/2 | 0| 1/2 | 0 |
| `db/dump.sql` | 10/10 | 0| 0/10 | 0 |
| `db/mongoid.yml` | 1/1 | 0| 0/1 | 0 |
| `etc/shadow` | 1/1 | 0| 0/1 | 0 |
| `filezilla/recentservers.xml` | 0/6 | 0| 0/6 | 0 |
| `filezilla/filezilla.xml` | 0/3 | 0| 0/3 | 0 |
| `high-entropy-misc.txt` | 0/2 | 0| 0/2 | 0 |
| `misc-keys/cert-key.pem` | 1/1 | 0| 1/1 | 0 |
| `misc-keys/putty-example.ppk` | 1/2 | 0| 0/2 | 0 |
| `proftpdpasswd` | 1/1 | 0| 0/1 | 0 |
| `web/ruby/config/master.key` | 0/1 | 0| 0/1 | 0 |
| `web/ruby/secrets.yml` | 0/3 | 0| 3/3 | 0 |
| `web/var/www/.env` | 1/10 | 0| 0/10 | 0 |
| `.npmrc` | 2/3 | 0| 1/3 | 0 |
| `web/var/www/public_html/wp-config.php` | 0/12 | 0| 0/12 | 0 |
| `web/var/www/public_html/.htpasswd` | 1/1 | 0| 0/1 | 0 |
| `.git-credentials` | 1/1 | 0| 0/1 | 0 |
| `db/robomongo.json` | 0/7 | 0| 0/7 | 0 |
| `web/js/salesforce.js` | 0/1 | 0| 0/1 | 0 |
| `.netrc` | 2/2 | 0| 0/2 | 0 |
| `hub` | 1/2 | 0| 1/2 | 0 |
| `config` | 0/4 | 0| 0/4 | 0 |
| `db/.pgpass` | 0/1 | 0| 0/1 | 0 |
| `ventrilo_srv.ini` | 0/2 | 0| 0/2 | 0 |
| `web/var/www/public_html/config.php` | 0/4 | 0| 0/4 | 0 |
| `db/dbeaver-data-sources.xml` | 1/1 | 0| 0/1 | 0 |
| `.esmtprc` | 0/3 | 0| 0/3 | 0 |
| `web/django/settings.py` | 0/1 | 0| 0/1 | 0 |
| `deployment-config.json` | 1/4 | 0| 0/4 | 0 |
| `.ftpconfig` | 0/5 | 0| 0/5 | 0 |
| `.remote-sync.json` | 1/3 | 0| 0/3 | 0 |
| `.vscode/sftp.json` | 1/4 | 0| 0/4 | 0 |
| `sftp-config.json` | 1/4 | 0| 0/4 | 0 |
| `.idea/WebServers.xml` | 1/2 | 0| 0/2 | 0 |
