# LENS: asvs — OWASP Application Security Verification Standard (FU-101)

**ADVISORY LENS.** Findings from this lens are ALWAYS `Follow-ups:` bullets prefixed
`LENS(asvs):` — they NEVER change your verdict (a per-stack claim knob graduates a lens to
blocking; until then advisory is the contract). Apply it ONLY to the auth/input/session code
this PR touches — it is a lens on the diff, not an audit of the repo.

**Source (pinned):** [OWASP ASVS v5.0](https://asvs.dev/) (May 2025 release —
[github.com/OWASP/ASVS](https://github.com/OWASP/ASVS)). A new major release of the ASVS = a
re-baseline issue, not an inline edit (staleness is outsourced by design).

**Selection predicate:** This lens fires when the diff adds or modifies code that is a
strong signal of authentication, session management, input parsing/validation, or a new public
endpoint. The predicate (`gh pr diff` grep in `reviewer-session.sh`) checks for:

| Signal | Examples matched |
|---|---|
| Auth-specific imports | `jwt`, `oauth`, `saml`, `oidc`, `session`, `csrf`, `cors`, `bcrypt`, `argon2`, `passport` |
| Auth function definitions | `Login`, `Logout`, `Authenticate`, `Authorize`, `Register`, `Signup`, `Session` |
| Session management | `session.Save`, `session.Get`, `session.Set`, `session.Destroy`, `session.Regenerate` |
| Input parsing | `ParseForm`, `ParseMultipartForm`, `.Bind(`, `.Validate(`, `.Sanitize(` |
| New public endpoints | HTTP handler/route registration (Go: `HandleFunc`, `gin.*`, `echo.*`, `chi.*`; Python: `@app.route`, `@router.*`; TS: `router.*`, `@Get`, `@Post`) |

**False-positive behaviour:** A PR that adds a new auth library import but uses it in a
non-auth context (e.g., adding a JWT library for a unrelated token format), or adds a
trivial handler (health check, static route) — the lens fires but the reviewer will find
nothing to flag. Favoured over a silent miss (see below).

**False-negative behaviour:** A PR that modifies existing auth logic without adding new
imports, function definitions, or route registrations — the lens stays quiet. This is a
deliberate choice: an advisory lens that fires on every PR trains the reviewer to skip
findings. Prefer a quiet miss.

For the ASVS requirements touched by this diff, check:

## V2: Authentication (relevant section)
- Are new credentials stored using a dedicated password hashing algorithm (bcrypt, argon2,
  scrypt) — never a fast hash (SHA-256, MD5) or reversible encryption?
- Are session tokens cryptographically random (minimum 128 bits of entropy) and generated
  by a secure random number generator?
- Are credential validation and rate limiting enforced server-side, not client-side?

## V3: Session Management (relevant section)
- Are session IDs rotated on login, privilege escalation, and logout?
- Are session tokens transmitted only over HTTPS with `Secure`, `HttpOnly`, and `SameSite`
  cookie attributes?
- Does session timeout/inactivity expiry exist, and does logout destroy the session
  server-side?

## V5: Validation, Sanitization & Encoding (relevant section)
- Is all user-supplied input validated against a whitelist (allow-list) for type, length,
  format, and range — never a blacklist?
- Are structured data formats (JSON, XML, YAML) parsed with a parser that disables
  external entities (XXE prevention)?
- Is output encoded for the target interpreter (HTML entity encoding for HTML, parameterized
  queries for SQL, etc.)?

## New/modified public endpoints
- Do new endpoints enforce authentication and authorization at the handler level, not solely
  in middleware that can be bypassed?
- Are HTTP verbs strictly enforced (a `DELETE` endpoint rejects `GET`)?
- Are request bodies size-limited and content-type-validated before processing?