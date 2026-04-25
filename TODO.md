# TODO

## Browser-Assisted HLTB Support

Status: deferred for further review.

Goal:

- Explore a browser-assisted HowLongToBeat import flow for `EstimatedHours`.
- Keep authentication inside the real browser session.
- Avoid storing credentials, browser cookies, or long-lived auth tokens in the repo.

Why this is under consideration:

- HLTB appears to block or restrict anonymous scripted access.
- The backlog-curator tool solves workflow problems that HLTB alone does not cover.
- A browser-assisted flow may allow user-approved, local-only extraction of runtime data.

Preferred design shape:

1. PowerShell starts a short-lived localhost listener.
2. Listener binds to `127.0.0.1` only.
3. Script generates a one-time random nonce/session token.
4. Real browser opens and user logs in manually to HLTB.
5. User explicitly triggers a small in-browser helper.
6. Browser helper posts only scoped game-time data plus the nonce back to localhost.
7. PowerShell validates the nonce, accepts a single payload, writes normalized metadata, and shuts the listener down.

Security requirements:

- No password capture.
- No browser cookie scraping.
- No copying session cookies into PowerShell.
- No storage of long-lived HLTB auth material in repo files.
- Localhost receiver must accept `POST` only.
- Localhost receiver must validate a one-time nonce.
- Localhost receiver should accept one payload only, then shut down.
- Payload should be limited to game/runtime data needed for enrichment.
- Logic should remain fully inspectable and repo-controlled.

Risks to think through:

- A malicious local process could try to post fake data to the localhost port.
- A malicious webpage could try to hit the localhost listener if protections are weak.
- A buggy helper could over-collect data from the authenticated session.
- Any design that reuses browser auth behind the user's back starts to resemble credential interception and should be avoided.

Safer patterns:

- User-mediated local handoff.
- Short-lived localhost callback.
- Explicit user action in the browser.
- Minimal browser helper script that is easy to audit.

Patterns to avoid:

- Reading/decrypting browser cookie stores.
- Asking the user to paste session cookies into the script.
- Silent tab injection or hidden browser automation against an authenticated session.
- Binding the receiver to anything broader than `127.0.0.1`.

Potential implementation options:

1. Bookmarklet or browser-console export
   - Lowest complexity
   - Strong user control
   - Good first version

2. Small browser extension or userscript
   - Better UX
   - More setup and maintenance

3. Playwright persistent browser profile
   - Smooth automation
   - Heavier dependency and broader trust surface

Current recommendation:

- Do not implement yet.
- Revisit only after deciding whether the security/trust tradeoff is acceptable.
- If implemented later, start with the bookmarklet/local-callback approach rather than cookie/session scraping.
