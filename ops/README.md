# foundry-ops

Operational automation for the zoidberg host — **weekly OS auto-updates** and a **daily
security scan**, both of which email a report. Runs as systemd timers/services (root), so it
can patch, reboot, and read privileged logs. Reports are sent through the estate's existing
Resend account (no local MTA required).

Deployed on the host at `/home/mike/foundry-ops/` (scripts) and `/etc/systemd/system/`
(units). State, apt logs, and scan baselines live in `/home/mike/foundry-ops/state/`.

## What runs

| Timer | Schedule | Does |
|-------|----------|------|
| `foundry-autoupdate.timer` | Sun 04:15 UTC | `apt update && upgrade && autoremove`, records what changed, **reboots only if `/var/run/reboot-required`**, then health-verifies + emails |
| `foundry-secscan.timer` | daily 06:25 UTC | lynis + rkhunter + debsums + auth/network/integrity checks → emails a security report |

On-demand (no reboot): `sudo systemctl start foundry-update-now`
On-demand scan: `sudo systemctl start foundry-secscan.service`

## Scripts

| File | Role |
|------|------|
| `foundry-autoupdate.sh` | apply OS updates; conditional reboot (writes a post-boot flag first) or inline report |
| `foundry-postboot-report.sh` | on every boot: if a post-update reboot flag exists, wait for the stack, health-check, email, clear flag |
| `foundry-report.sh` | estate health check (services, workers, docker infra, app `/api/health`, disk/mem) → report text + send |
| `foundry-secscan.sh` | daily security scan → report text + send |
| `foundry-email.py` | renders a report into a branded HTML email and sends via Resend (`User-Agent` header required — Resend is behind Cloudflare) |

The email sender reads `RESEND_API_KEY` / `MAIL_FROM` / `MAIL_REPLY_TO` at runtime from
`/home/mike/zoidlab/server/.env`. **No secrets are stored in this repo.** Recipient defaults to
`REPORT_TO` (env) → `mike@256kmagic.com`.

## Security scan coverage

Pending security updates · failed/successful SSH logins (24h) + top source IPs · ufw firewall
status + allowed ports · non-loopback listeners **diffed against a baseline** (alerts on new
ports) · failed systemd units · docker containers · rkhunter (rootkits) · debsums (package-file
integrity) · lynis hardening index + warnings · TLS cert expiry · SUID-binary diff. Verdict:
`OK` / `WARNINGS` / `CRITICAL`.

## Install / update on the host

```bash
# scripts
install -m 0755 -d /home/mike/foundry-ops
cp foundry-*.sh foundry-email.py /home/mike/foundry-ops/ && chmod +x /home/mike/foundry-ops/*

# units
sudo cp systemd/foundry-*.service systemd/foundry-*.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now foundry-autoupdate.timer foundry-secscan.timer foundry-postboot-report.service
```

## Notes
- Reboot policy is **conditional** (only when a patch requires it). To force a weekly reboot,
  drop the `[ -f /var/run/reboot-required ]` guard in `foundry-autoupdate.sh`.
- Scripts are mike-owned but executed as root by the timers — acceptable on a single-admin box;
  move to a root-owned path if you want them immutable to the login user.
