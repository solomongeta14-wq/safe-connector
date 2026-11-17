# Connect Safely

A local matchmaking prototype with a PowerShell API server and a plain HTML/CSS/JavaScript frontend. No Node.js, package installation, or database server is required.

## Run locally

1. Double-click `run.bat`, or open PowerShell in this folder.
2. In PowerShell, start the server and open the site:

   ```powershell
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\start.ps1
   ```

4. Visit **http://localhost:5173/**. Register an account to begin. The health endpoint is **http://localhost:5173/api/health**.

To run the server in the current PowerShell window instead, use `.\server.ps1`. Keep that window open while using the site; press Ctrl+C there to stop the server. If port 5173 is already in use, close its process or change `$script:Port` near the top of `server.ps1`.

## Administrator account

To make a newly registered account an administrator, set its email before starting the server:

```powershell
$env:CONNECT_ADMIN_EMAIL = 'admin@example.com'
.\start.ps1
```

Register using that email. The admin role is only assigned at registration time. Do not use this feature on a publicly reachable server.

## Local data

Accounts, profiles, likes, matches, messages, contact-exchange requests, reports, and audit events are stored in `data\connect-safely.json`, created on first registration. Passwords are salted and hashed server-side with PBKDF2-HMAC-SHA256. Session cookies are HTTP-only and sessions expire after 12 hours; sessions are kept in memory and end when the server stops.

## Important limitations

This is a development prototype, not a production-ready dating service. It runs over local HTTP, stores application data in a local JSON file, and does not provide email verification, password recovery, MFA, encrypted-at-rest storage, image uploads, or production moderation workflows. Do not put real personal information in it or expose it to the internet. A production deployment needs a hardened HTTPS host, a managed database, email delivery, operational monitoring, backup and retention policies, and a security/privacy review.
