# Security Policy

## Reporting a vulnerability

Please do **not** open a public issue for security problems. Use GitHub's
"Report a vulnerability" (private security advisory) on this repository. Include steps to
reproduce and the affected version. We aim to acknowledge reports within a week.

## Scope

GitSync runs the system `git` binary and never stores credentials itself; authentication is
delegated to your Git credential helpers and SSH agent. Reports about argument injection,
unsafe path handling, or destructive operations running without confirmation are especially welcome.

## Supported versions

Only the latest release receives security fixes while the project is pre-1.0.
