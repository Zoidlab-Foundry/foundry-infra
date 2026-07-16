#!/usr/bin/env python3
"""Send an ops/security report via Resend, rendered as a professional HTML email.

Parses the structured plain-text report (title, meta key:values, `-- Section --` blocks,
`[CRITICAL]/[warn]` findings, `key: value` rows) into a branded, responsive HTML email.
Plain text is kept as the fallback part.
"""
import os, sys, re, json, html, urllib.request

ENV_FILE = "/home/mike/zoidlab/server/.env"


def load_env(path):
    d = {}
    try:
        for ln in open(path):
            ln = ln.strip()
            if ln.startswith("#") or "=" not in ln:
                continue
            k, v = ln.split("=", 1)
            d[k] = v
    except Exception:
        pass
    return d


def severity(verdict):
    v = (verdict or "").upper()
    if "CRITICAL" in v:
        return "#dc2626"
    if "WARN" in v or "NEEDS ATTENTION" in v or "ISSUE" in v:
        return "#d97706"
    if "OK" in v:
        return "#16a34a"
    return "#475569"


SEC_RE = re.compile(r"^--\s*(.+?)\s*--$")
FND_RE = re.compile(r"^\[(CRITICAL|warn)\]\s*(.*)$", re.I)


def parse(body):
    lines = body.splitlines()
    i = 0
    while i < len(lines) and not lines[i].strip():
        i += 1
    title = lines[i].strip() if i < len(lines) else "Report"
    i += 1
    if i < len(lines) and lines[i].strip() and set(lines[i].strip()) <= set("="):
        i += 1
    meta, sections, cur = {}, [], None
    for ln in lines[i:]:
        m = SEC_RE.match(ln.strip())
        if m:
            cur = (m.group(1), [])
            sections.append(cur)
            continue
        if cur is None:
            if ":" in ln and ln.strip():
                k, v = ln.split(":", 1)
                meta[k.strip()] = v.strip()
        else:
            cur[1].append(ln)
    return title, meta, sections


def rows(lines):
    out = ""
    for raw in lines:
        s = raw.strip()
        if not s:
            continue
        m = FND_RE.match(s)
        if m:
            crit = m.group(1).lower() == "critical"
            color = "#dc2626" if crit else "#d97706"
            bg = "#fef2f2" if crit else "#fffbeb"
            label = "CRITICAL" if crit else "WARNING"
            out += (f'<tr><td colspan="2" style="padding:5px 0">'
                    f'<span style="display:inline-block;font:700 10px -apple-system,Segoe UI,sans-serif;'
                    f'letter-spacing:.05em;color:{color};background:{bg};border:1px solid {color}44;'
                    f'border-radius:5px;padding:2px 7px;margin-right:8px">{label}</span>'
                    f'<span style="font:13px -apple-system,Segoe UI,sans-serif;color:#1e293b">{html.escape(m.group(2))}</span></td></tr>')
            continue
        if s.lower().startswith("none") or (len(s) < 26 and "clean" in s.lower()):
            out += (f'<tr><td colspan="2" style="padding:5px 0;font:13px -apple-system,Segoe UI,sans-serif;color:#16a34a">'
                    f'&#10003; {html.escape(s)}</td></tr>')
            continue
        if re.match(r"^[A-Za-z][^:]{0,40}:\s", s + " ") and ": " in (s + " "):
            k, v = s.split(":", 1)
            out += (f'<tr><td style="padding:5px 14px 5px 0;vertical-align:top;white-space:nowrap;'
                    f'font:12px -apple-system,Segoe UI,sans-serif;color:#64748b">{html.escape(k.strip())}</td>'
                    f'<td style="padding:5px 0;font:12px ui-monospace,SFMono-Regular,Menlo,monospace;'
                    f'color:#0f172a;word-break:break-word">{html.escape(v.strip()) or "&mdash;"}</td></tr>')
        else:
            out += (f'<tr><td colspan="2" style="padding:4px 0;font:12px ui-monospace,SFMono-Regular,Menlo,monospace;'
                    f'color:#334155;word-break:break-word">{html.escape(s)}</td></tr>')
    return out


def render_html(body):
    title, meta, sections = parse(body)
    verdict = meta.get("Verdict") or meta.get("VERDICT") or "REPORT"
    fg = severity(verdict)
    tstamp = meta.get("Time", "")
    sub = " &nbsp;·&nbsp; ".join(f"{html.escape(k)}: {html.escape(v)}"
                                 for k, v in meta.items() if k.lower() not in ("verdict", "time"))
    sub_title = title.replace("ZOIDBERG", "").strip() or "Report"
    secs = ""
    for stitle, slines in sections:
        secs += (f'<tr><td style="padding:20px 26px 2px"><div style="font:700 11px -apple-system,Segoe UI,sans-serif;'
                 f'letter-spacing:.09em;text-transform:uppercase;color:#94a3b8">{html.escape(stitle)}</div></td></tr>'
                 f'<tr><td style="padding:2px 26px 6px"><table width="100%" cellspacing="0" cellpadding="0" '
                 f'style="border-collapse:collapse">{rows(slines)}</table></td></tr>')
    return (
        '<div style="background:#eef1f5;padding:26px 12px;font-family:-apple-system,BlinkMacSystemFont,Segoe UI,Roboto,Helvetica,Arial,sans-serif">'
        '<table align="center" width="640" cellspacing="0" cellpadding="0" style="max-width:640px;margin:0 auto;'
        'background:#ffffff;border:1px solid #e2e8f0;border-radius:14px;overflow:hidden;box-shadow:0 1px 3px rgba(15,23,42,.06)">'
        '<tr><td style="background:#0f172a;padding:20px 26px">'
        '<table width="100%" cellspacing="0" cellpadding="0"><tr>'
        '<td style="font:700 15px -apple-system,Segoe UI,sans-serif;color:#f8fafc;letter-spacing:.02em">'
        f'ZOIDBERG <span style="color:#64748b;font-weight:500">&nbsp;/&nbsp; {html.escape(sub_title)}</span></td>'
        f'<td align="right"><span style="display:inline-block;font:700 11px -apple-system,Segoe UI,sans-serif;'
        f'letter-spacing:.05em;color:#fff;background:{fg};border-radius:999px;padding:5px 13px">{html.escape(verdict)}</span></td>'
        '</tr></table>'
        f'<div style="margin-top:7px;font:12px -apple-system,Segoe UI,sans-serif;color:#94a3b8">{html.escape(tstamp)}'
        f'{(" &nbsp;·&nbsp; " + sub) if sub else ""}</div></td></tr>'
        f'{secs}'
        '<tr><td style="padding:16px 26px;border-top:1px solid #f1f5f9;font:11px -apple-system,Segoe UI,sans-serif;color:#94a3b8">'
        'Automated report · zoidberg foundry-ops · '
        '<a href="https://zoidlab.ai" style="color:#94a3b8;text-decoration:none">zoidlab.ai</a></td></tr>'
        '</table></div>')


def main():
    if len(sys.argv) < 3:
        print("usage: foundry-email.py <subject> <body-file>"); sys.exit(2)
    subject, body_file = sys.argv[1], sys.argv[2]
    env = load_env(ENV_FILE)
    key = env.get("RESEND_API_KEY", "")
    frm = env.get("MAIL_FROM", "ZOIDLAB <clearance@nyquest.ai>")
    to = os.environ.get("REPORT_TO", "mike@256kmagic.com")
    reply = env.get("MAIL_REPLY_TO", "")
    if not key:
        print("RESEND_API_KEY missing — cannot send"); sys.exit(3)
    body = open(body_file).read()
    payload = {"from": frm, "to": [to], "subject": subject, "text": body, "html": render_html(body)}
    if reply:
        payload["reply_to"] = reply
    data = json.dumps(payload).encode()
    req = urllib.request.Request("https://api.resend.com/emails", data=data,
                                 headers={"Authorization": "Bearer " + key, "Content-Type": "application/json",
                                          "User-Agent": "Mozilla/5.0 (foundry-ops zoidberg)",
                                          "Accept": "application/json"})
    try:
        r = urllib.request.urlopen(req, timeout=30)
        print("email sent -> %s (HTTP %s)" % (to, r.status))
    except urllib.error.HTTPError as e:
        print("send failed HTTP", e.code, e.read()[:300]); sys.exit(1)
    except Exception as e:
        print("send failed:", e); sys.exit(1)


if __name__ == "__main__":
    main()
