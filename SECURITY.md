# Security policy

## Reporting a vulnerability

Do not put exploit details, credentials, runtime tokens, private screenshots, or
browser profiles in a public issue. If this repository's GitHub **Security** tab
offers **Report a vulnerability**, use that private reporting flow. Otherwise,
open a minimal issue asking the maintainer for a private contact channel, without
including vulnerability details. A dedicated security email is not currently
published, and response times are not guaranteed.

Include the affected commit/version, environment, reproduction steps, impact,
and a minimal redacted proof when communicating privately. Development currently
focuses on the latest source; no long-term support or backport schedule is promised.

## Trust model

hyprhand runs as the desktop user. A managed session isolates input and compositor
routing, **not** files, credentials, network, or user permissions. `HOME` remains
unchanged. Applications and other processes under the same user account are not
mutually isolated by runtime directory permissions or hyprhand authorization tokens.
Those tokens are a cooperative control mechanism, not an authentication boundary
against malicious same-user processes.

The CLI accepts local commands from the caller. An external agent or script is
responsible for deciding which tasks are authorized. The tool includes no AI
model or network service and does not upload captures, logs, or text. Invoked
applications can perform their own network operations.

## Controls and limits

- Input commands require explicit session selection and enabled control.
- Frames bind screenshot coordinates to a session, layout, focus and short lifetime.
- Guards recheck authorization, lock state, focus/layout and pointer position.
- `stop` revokes guarded input without waiting for a long-running action lock.
- Native input cleanup releases owned keys/buttons on normal exit and catchable
  cancellation. It cannot undo completed actions or guarantee release after
  SIGKILL, compositor failure, or all external helper failures.
- Session teardown validates recorded process identities and avoids broad
  username/process-group killing. Unattributable detached descendants can remain.
- Experimental libraries execute inside a compositor. Path, version, and ABI
  checks do not make an untrusted library safe; use trusted local builds in a
  disposable compositor. They are never automatically loaded into the host.

## Data handling

Screenshots and frame metadata use private runtime directories/files. Audit logs
exclude typed text, argv, and window titles, but screenshots, accessible names,
compositor logs, and retained app profiles may contain sensitive information.
Password values/children are omitted from AT-SPI traversal; this is not a guarantee
that all other widgets are free of secrets.

`session destroy` retains profiles and logs at the reported path. `gc` only
collects eligible frame files. Inspect diagnostic artifacts before sharing and
remove retained data deliberately when no longer needed. Prefer an actually
isolated account or VM when a workflow needs a security boundary beyond input
routing.
