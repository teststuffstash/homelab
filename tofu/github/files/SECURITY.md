# Security Policy

This policy covers TESTSTUFF OÜ (Estonian registry code 17393222).
Security lead: Rasmus Sööt.

## Reporting a vulnerability

- **Code in a repository:** use "Report a vulnerability" on the repository's Security tab
  (GitHub private vulnerability reporting).
- **Services, or anything else:** email security@teststuff.net.

Please include the affected URL or repository and commit, what you found, steps to reproduce it,
and the impact you expect. Do not open public issues for vulnerabilities.

## Scope

In scope are the systems TESTSTUFF OÜ operates:
- repositories under github.com/teststuffstash
- minutark.ee
- public services under *.teststuff.net

Out of scope: third-party platforms we use (GitHub, Cloudflare, Proton — report to them directly),
denial-of-service or volumetric testing, social engineering, physical attacks, and findings with
no demonstrated security impact (e.g. missing best-practice headers on their own).

## What to expect

TESTSTUFF OÜ is a one-person company, so these times are realistic rather than aspirational:
- acknowledgement within 5 working days
- initial assessment within 14 working days
- a status update at least every 14 working days until the issue is resolved

## Coordinated disclosure

We ask you to wait until a fix is released, or 90 days after your report, whichever comes first,
before you disclose publicly. If a fix needs longer, we will agree an extension with you.

## Safe harbour

If you act in good faith and within this policy, we consider your research authorised and will
not take legal action against you. If a third party takes action against you, we will make it
known that you acted in line with this policy. Good faith means you:
- do not access, change or delete data that isn't yours, beyond what proves the issue
- stop and report as soon as you have confirmed a vulnerability
- avoid degrading service for other users
- keep the details confidential until disclosure as above

## Recognition

There is no bug bounty. With your permission, we credit you in the advisory.
