# Security policy

## Supported versions

Only the latest minor release of `ash_metrics` receives security fixes. A
fix ships as a patch release of that minor; earlier minors are not patched.

## Reporting a vulnerability

Do not open a public issue. Report privately through GitHub's
[private vulnerability reporting](https://github.com/smt116/ash_metrics/security/advisories/new)
or, if that is unavailable, by email to maciej@smefju.pl.

Include the version, a description of the impact and, where possible, a
minimal reproduction. You will receive an acknowledgement within seven days
and a fix or a decision within thirty days of the acknowledgement.

## Disclosure

A confirmed vulnerability is fixed in a patch release, recorded in
`CHANGELOG.md` and published as a GitHub security advisory, which Dependabot
alerts consumers from. The reporter is credited in the advisory unless they
ask not to be.

## Scope

In scope: code in this repository as published on Hex, including the
installer and the `usage-rules` files. Out of scope: the reporter and backend
the host application ships metrics through, `Telemetry.Metrics`, Ash, and
any behaviour that only occurs with a modified copy of the library.
