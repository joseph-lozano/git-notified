# Decision Log: git-notified

## Trivial decisions

- D1: Stack is Tauri (Rust backend + web UI) — chosen by the user at project start as the build platform. — Referenced in spec: _none directly; informs all_.
- D2: Auth relies entirely on `gh` session — the app shells out to `gh` and stores no GitHub credentials of its own. — Referenced in spec: Outcome; Actors and Triggers; Coordinations.
- D16: Multi-account and GHE multi-host support are out of scope for v1 — the app uses whichever account `gh auth status` reports as active. — Referenced in spec: Out of Scope; Deferred (YAGNI).

## Full decisions

### D3: Per-repo mode dropdown — off / participating / all

- **Question:** At what granularity does the user control notifications per repository, and what discrete levels of "involvement" are offered?
- **Decision:** Each watched repository has a single mode setting with three values — `off`, `participating`, and `all`. The mode controls which pull requests are matched when scanning that repository. There are no separate per-event-type toggles within a repository in v1.
- **Rationale:** Matches GitHub's own notification model. Keeps the configuration UI down to a single dropdown per repo.
- **Evidence:** User input. GitHub's notifications UI uses the identical Participating-vs-All split.
- **Rejected alternatives:**
  - Global event-type toggles with no per-repo mode — rejected because it contradicts the stated requirement of opt-in being per-repo.
  - Opt-out model (auto-watch everything) — rejected for the same reason.
- **Linked technical notes:** —
- **Driven by findings:** —
- **Dependent decisions:** D4, D5, D8, D12.
- **Referenced in spec:** Primary Flow (step 4).

### D4: "Participating" definition includes team review requests

- **Question:** What counts as a "participating" pull request for a repository in `participating` mode? How is eligibility determined per tick?
- **Decision:** A pull request matches `participating` if the user is its author, an assignee, a directly requested reviewer, a member of a team whose review has been requested, an @mention recipient on the PR or any of its comments, or has previously commented or reviewed on the PR. Eligibility is determined per tick by `gh`'s `involves:@me` search filter — the app does not maintain its own eligibility cache.
- **Rationale:** Team review requests are common at work. Relying on `gh`'s `involves:` qualifier matches GitHub's own definition and avoids reinventing eligibility detection.
- **Evidence:** User input on the breadth ("Wider: include team review requests"). GitHub `involves:` search-qualifier documentation for the per-tick resolution path.
- **Rejected alternatives:**
  - Narrow: author + assignee + requested reviewer only — rejected; drops @mention and prior-commenter signals.
  - GitHub's strictest Participating (no team reviews) — rejected; team rotations are stated user context.
  - Maintain a per-PR eligibility cache in the app — rejected as duplicate state; `gh`'s `involves:` filter is authoritative.
- **Linked technical notes:** —
- **Driven by findings:** F10
- **Dependent decisions:** D17.
- **Referenced in spec:** Primary Flow (step 4).

### D5: No per-event-type toggles in v1

- **Question:** Within a watched repository, can the user separately mute CI vs. comment notifications?
- **Decision:** No. The repository's mode controls all four event types together.
- **Rationale:** Simplest UI for v1. If CI noise becomes a problem, a targeted toggle can be added later.
- **Evidence:** User input.
- **Rejected alternatives:**
  - Per-event toggles per repository — rejected; deferred under YAGNI.
  - A single CI mute toggle — rejected; no incident yet justifies it.
- **Linked technical notes:** —
- **Driven by findings:** —
- **Dependent decisions:** —
- **Referenced in spec:** Primary Flow.

### D6: Menubar role is passive notifier plus dropdown summary

- **Question:** What does the menubar surface do beyond firing notifications?
- **Decision:** The menubar icon shows one of four state values (`idle`, `active` with numeric count badge, `setup`, `error`) and opens a dropdown popover on click. The popover shows three content sections — Reviews requested, CI failing, New comments &amp; reviews — plus controls (Silence, Add repository, Manage repositories, Quit). The badge is a numeric count, not a colored dot, to satisfy WCAG 1.4.1. No separate main window.
- **Rationale:** Fits the menubar framing without adding a window the user would rarely open. Gives a glance-able state surface.
- **Evidence:** User input; macOS HIG; WCAG 1.4.1.
- **Rejected alternatives:**
  - Notifier only (no dropdown content) — rejected; users would have no in-app way to see what's outstanding.
  - Notifier + full settings window — rejected as more surface than v1 needs.
- **Linked technical notes:** —
- **Driven by findings:** F11, F22
- **Dependent decisions:** D11, D13, D19, D21, D22.
- **Referenced in spec:** Primary Flow (step 7); User Interactions.

### D7: Storage is plain JSON in `~/Library/Application Support/git-notified/`

- **Question:** Where does the app persist its configuration and its dedup cursors?
- **Decision:** Plain JSON files in `~/Library/Application Support/git-notified/` — `config.json` holds watched repos + modes + prefs; `state.json` holds the per-(repo, PR, event-type) cursors (see D17). Writes are persisted such that a crash mid-write does not leave saved state partially-updated. The app stores no GitHub credentials — `gh` owns the token.
- **Rationale:** Easy to inspect and back up. No DB setup. JSON's structural limitations are fine for v1 because the dropdown is recomputed each tick from current GitHub state, not from the saved history.
- **Evidence:** User input.
- **Rejected alternatives:**
  - SQLite — rejected as overkill for v1.
  - Keychain — rejected; the app holds no secrets.
  - Tauri Stronghold / store plugin — rejected to keep the file human-readable.
- **Linked technical notes:** —
- **Driven by findings:** F1, F21
- **Dependent decisions:** D10, D12, D17.
- **Referenced in spec:** Primary Flow (steps 2, 9); Coordinations; Edge Cases (corrupted state).

### D8: Add-repo UX combines searchable picker with paste

- **Question:** How does a user opt a repository into the watch list?
- **Decision:** A single picker UI with a combined search-and-paste input. Results come from `gh repo list`; pasted `owner/name` or full URLs are offered as results regardless of whether they appear in `gh repo list`.
- **Rationale:** Covers both "I know exactly what I want" and "help me find it."
- **Evidence:** User input.
- **Rejected alternatives:**
  - Paste-only — rejected; requires the user to know the exact `owner/name`.
  - Picker-only — rejected; excludes public OSS repos.
- **Linked technical notes:** —
- **Driven by findings:** —
- **Dependent decisions:** —
- **Referenced in spec:** Adding a repository alternate flow.

### D9: Click action opens PR in default browser

- **Question:** What happens when the user clicks a notification or a dropdown row?
- **Decision:** The corresponding GitHub PR URL is opened in the user's default browser. No in-app PR view in v1.
- **Rationale:** Matches every other GitHub tool.
- **Evidence:** User input.
- **Rejected alternatives:**
  - In-app popover with PR details — rejected; deferred under YAGNI.
  - Configurable browser/terminal/in-app — rejected as overkill.
- **Linked technical notes:** —
- **Driven by findings:** —
- **Dependent decisions:** —
- **Referenced in spec:** Primary Flow (step 8); User Interactions.

### D10: One notification per new event, deduplicated by cursor comparison

- **Question:** How does the app avoid spamming notifications, and how does it avoid re-firing for events seen in earlier polls?
- **Decision:** For each (repository, pull request, event-type) triple, the app stores a cursor — the GitHub-reported `updated_at` timestamp of the most recent event already delivered, with the globally-unique event ID as tiebreaker (see D17). Events strictly newer than the cursor produce a notification and advance the cursor. macOS Notification Center delivery is best-effort: the app fires at most one notification per event; the OS may coalesce or drop notifications under burst load, in which case the dropdown remains the authoritative current-state view.
- **Rationale:** Per-PR granularity is the only model that supports D12 (no-backfill on add/widen) and consistent mode-change behavior. Timestamp ordering is the only ordering property GitHub guarantees across event types.
- **Evidence:** User input on dedup intent. Cursor granularity (per-PR) was settled by review-team finding F1. Timestamp ordering chosen based on GitHub API documentation.
- **Rejected alternatives:**
  - Coalesce per PR within a 5-minute window — rejected; deferred under YAGNI.
  - Digest mode — rejected; loses urgency on review requests.
  - Per-(repo, event-type) high-water mark (one number per event type per repo) — rejected because it cannot model per-PR retention required by D12 and the mode-change flow.
- **Linked technical notes:** —
- **Driven by findings:** F1, F2, F3, F6, F9
- **Dependent decisions:** D11, D17, D22.
- **Referenced in spec:** Primary Flow (steps 5, 6, 9); Error state alternate flow.

### D11: Failure UX uses icon error state plus dropdown explanation, never a system notification

- **Question:** When `gh` fails or a watched repo becomes inaccessible, what does the user see?
- **Decision:** App-level failures (auth, network, rate limit, parse, notification permission, corrupted state) switch the menubar icon to its error state and populate the dropdown's status banner with a structured cause from the enum `NotSignedIn | RateLimited | NetworkUnavailable | InsufficientScope | ParseError | NotificationsDisabled | CorruptedState`, plus an action label and an action. Per-repo failures (404 on a single watched repo from rename/transfer/delete/access-revoked) show a per-repo "No access" row with an inline `Remove` action and do NOT switch the global icon unless every watched repo is failing. No system notification fires for any failure. The icon returns to non-error state only after two consecutive successful polls (hysteresis), preventing visual flap on flaky networks.
- **Rationale:** Notification fatigue around connectivity is the worst failure mode for an ambient notifier. Per-repo issues should not look like app-level outages. Hysteresis prevents trust erosion from rapid flips.
- **Evidence:** User input on no-notifications-for-failure. Per-repo vs. app-level split, structured cause, and hysteresis are review-team findings (F12, F22, F26).
- **Rejected alternatives:**
  - Fire a notification on first failure — rejected; flapping notifications.
  - Silent (only dropdown) — rejected; users would not realize they had been missing events.
  - Free-text cause string in the banner — rejected as not testably observable (F22).
  - Single-success return to non-error state — rejected as it would flap on flaky networks (F26).
- **Linked technical notes:** —
- **Driven by findings:** F3, F12, F22, F26
- **Dependent decisions:** D14, D22.
- **Referenced in spec:** Error state alternate flow; User Interactions; Edge Cases.

### D12: No backfill notifications when adding a repository or widening its mode

- **Question:** When the user adds a repository or widens its mode so new pull requests now match, should the app fire notifications for activity that already happened?
- **Decision:** No. On add, on widening (`participating` → `all`), and on re-widening after a previous narrowing, the app initializes cursors for newly-in-scope PRs to current high-water marks. The dropdown still shows outstanding items immediately because it is a separate data path. macOS notifications fire only for events arriving afterward.
- **Rationale:** Adding or widening should not produce a notification flood. Treating re-widen identically to a fresh add (rather than retaining stale cursors) keeps behavior predictable and aligned with user intent — the user widened deliberately and does not expect a backlog dump.
- **Evidence:** User input on no-backfill for add. Re-widen extension settled by user input on F8.
- **Rejected alternatives:**
  - Fire notifications for currently outstanding items on add — rejected; notification flood.
  - Retain narrow-period cursors on re-widen so events from the narrow window deliver — rejected; produces unpredictable bursts at the user's choice of re-widen moment (F8).
  - User-chosen checkbox on add — rejected as unnecessary UI for v1.
- **Linked technical notes:** —
- **Driven by findings:** F8
- **Dependent decisions:** —
- **Referenced in spec:** Adding a repository; Changing a repository's mode.

### D13: Silence notifications toggle in the dropdown

- **Question:** Does v1 include a manual pause / snooze affordance, and what is its UX?
- **Decision:** A single "Silence notifications" toggle in the dropdown (renamed from "Pause" to remove the queue-and-hold implication). While on, polling and dropdown updates continue but system notifications are suppressed; cursors still advance. On resume, the dropdown shows a transient banner above "New comments &amp; reviews": "Silenced for N minutes — M new items below." For silences longer than 24 hours, the "New comments &amp; reviews" window temporarily expands to cover the silenced interval, up to a ceiling of 7 days, so the user can see what they missed. Silence does not persist across app launches.
- **Rationale:** One-click silence is the common case. "Silence" is clearer than "Pause" about the discard semantics. The post-resume banner and window expansion make the data discard legible — the user knows what they missed without being re-notified.
- **Evidence:** User input on toggle existence and rename.
- **Rejected alternatives:**
  - Scheduled quiet hours — rejected; deferred under YAGNI.
  - No app-level pause — rejected; Focus modes are heavier and slower.
  - Persistent across launches — rejected; risks permanently-muted state.
- **Linked technical notes:** —
- **Driven by findings:** F7, F15
- **Dependent decisions:** —
- **Referenced in spec:** Silencing notifications alternate flow; User Interactions.

### D14: Polling is a single global tick of ~60 seconds with jitter, exponential backoff on errors, rate-limit-aware retry

- **Question:** How does the app schedule its polling and recover from transient failures?
- **Decision:** One global timer ticks every 60 seconds with small random jitter. Each tick walks all watched repositories in mode `participating` or `all`. On an error tick, the app retries with progressively-increasing delays up to a ceiling. For rate-limit errors, the app respects the reset time GitHub reports. Parse errors use the same backoff — no special wedged-pause mode. The first poll after setup completion runs immediately, not on the next scheduled tick.
- **Rationale:** A single timer keeps implementation simple and API budget predictable. Jitter prevents synchronized bursts. Parse-error uniformity (vs. the original special-case wedge) keeps the recovery model consistent and self-healing.
- **Evidence:** User input on 60s cadence. Parse-error uniformity is review-team finding F14.
- **Rejected alternatives:**
  - Per-repo timers — rejected; more state and risk of synchronized bursts.
  - Adaptive polling — rejected for v1 simplicity.
  - Webhook-based delivery — deferred under YAGNI.
  - Special wedge-pause on parse errors — rejected (F14); inconsistent with the rest of the recovery model.
- **Linked technical notes:** —
- **Driven by findings:** F14, F23
- **Dependent decisions:** —
- **Referenced in spec:** Triggers; Primary Flow (step 3); Error state alternate flow.

### D15: First-run handshake gates the app on `gh` install and auth

- **Question:** How does the app handle missing `gh` or unauthenticated `gh` at launch?
- **Decision:** On launch, the app verifies `gh` is reachable from its runtime environment and that `gh auth status` reports a signed-in account. If either fails conclusively, the menubar enters its distinct setup state, the dropdown shows a checklist with one actionable step at a time, and polling does not run. If `gh auth status` fails with a network error specifically (as distinct from an auth-failure response), the app enters the error state — not the setup state — and retries. The setup checklist distinguishes "`gh` not installed" from "`gh` installed but not reachable from the app's environment" (the macOS GUI-app PATH case).
- **Rationale:** Polling without `gh` or auth would loop on errors. Setup state with a recoverable checklist is the only sensible path. Distinguishing PATH-misses from not-installed prevents users from being told to install something they already have.
- **Evidence:** User input. PATH-vs-not-installed and network-vs-auth splits settled by review-team findings F4 and F13.
- **Rejected alternatives:**
  - Start polling anyway — rejected; confusing error noise.
  - Quit on missing prerequisites — rejected; no path to recovery.
  - Single "Install gh" checklist row covering both not-installed and not-on-PATH — rejected (F4); misleads users.
  - Treat any `gh auth status` failure as "not signed in" — rejected (F13); strands users on transient network errors.
- **Linked technical notes:** —
- **Driven by findings:** F4, F13
- **Dependent decisions:** —
- **Referenced in spec:** Preconditions; First-run / setup alternate flow; Edge Cases.

### D17: Cursor data model — per (repo, PR, event-type)

- **Question:** What is the storage shape and ordering rule for the dedup cursor that powers D10?
- **Decision:** Cursors are stored per (repository, pull request, event-type) triple. Each cursor's value is the GitHub-reported `updated_at` timestamp of the most recent event already delivered for that triple, with the event's globally-unique ID as tiebreaker. State.json stores the structure:
  ```
  state.json
    acme/api:
      "421": { reviews_requested: t12, ci: t8, comments: t104, prRev: t5 }
      "422": { reviews_requested: t10, ci: -,  comments: t95,  prRev: t2 }
    acme/web:
      "88":  { ... }
  ```
  Per-PR cursors are initialized to current high-water marks on PR-becomes-in-scope events (add, widen, re-widen) per D12. Cursors are pruned when the PR closes/merges and ages out of any 7-day silence-expansion window.
- **Rationale:** The simpler per-(repo, event-type) model cannot support D12's stated behavior (no backfill on add/widen) without per-PR resolution. Timestamps are the only ordering property GitHub guarantees across event types; using the unique ID as tiebreaker handles same-timestamp ties. Storage cost is O(open PRs × 4) ≈ a few hundred entries per active user — negligible.
- **Evidence:** User input on per-PR granularity (review-team finding F1 escalation). GitHub API documentation for `updated_at` semantics.
- **Rejected alternatives:**
  - Per-(repo, event-type) only (single high-water mark per event type per repo) — rejected because it cannot model per-PR retention.
  - Per-(repo, event-type) high-water mark + per-PR "seen" set as a backup — rejected (F1 alternative); adds plumbing with little real benefit over per-PR cursors.
  - Comparing by event ID directly (numeric comparison) — rejected (F2); IDs are not guaranteed monotonic per event type.
- **Linked technical notes:** —
- **Driven by findings:** F1, F2
- **Dependent decisions:** —
- **Referenced in spec:** Primary Flow (steps 2, 5).

### D18: Notification format — title is the event description, subtitle is the PR reference

- **Question:** How should the notification body be structured given macOS banner-title truncation?
- **Decision:** Title = event description ("Review requested by @alice"); Subtitle = pull request reference and title (`acme/api#421 — Add OAuth login`). Most actionable info wins the title slot and survives truncation.
- **Rationale:** macOS banner titles clip around 50–60 characters. Putting the repo name first means long org/repo names hide the event type. Putting the event first ensures the user always knows why the notification fired even when truncation occurs.
- **Evidence:** User input. macOS Notification Center documented truncation behavior (F16).
- **Rejected alternatives:**
  - Repo-first single-line title — rejected; clips the event type for long repo names.
  - Title = repo, subtitle = description — rejected for same reason.
- **Linked technical notes:** —
- **Driven by findings:** F16
- **Dependent decisions:** —
- **Referenced in spec:** Primary Flow (step 6); User Interactions.

### D19: Accessibility commitment — behavioral a11y in v1

- **Question:** How much accessibility commitment does v1 include?
- **Decision:** The spec commits behaviorally to: section headings announced as headings; rows announced as buttons with full visible text as the accessible name; the silence toggle announcing its current state; the menubar icon carrying a state-inclusive accessible label; the badge using a numeric count (not color alone) to satisfy WCAG 1.4.1; the dropdown fully keyboard-navigable (Tab/Shift-Tab/Return/Esc). The spec does not prescribe HTML/ARIA specifics — those belong to the implementation plan.
- **Rationale:** Tauri's default web layer ships inaccessible without explicit work. Retrofitting a11y after launch is materially more expensive than baking it in. The audience may eventually go public (per the user brief), so WCAG-aware design from the spec stage is appropriate.
- **Evidence:** User input. WCAG 2.2 documented criteria.
- **Rejected alternatives:**
  - Defer all a11y to implementation — rejected; the spec needs to commit to observable a11y behaviors for those behaviors to be tested and built.
  - Keyboard-only commitment without VoiceOver — rejected; partial commitment leaves the most impactful affordances out.
- **Linked technical notes:** —
- **Driven by findings:** F17
- **Dependent decisions:** —
- **Referenced in spec:** User Interactions (entire section, especially Accessibility subsection).

### D20: Single-instance enforcement on the same Mac

- **Question:** What should happen when the app is launched a second time while already running?
- **Decision:** The second instance detects the existing one, surfaces its dropdown (activates it), and exits. The same `state.json` is never written by two processes simultaneously.
- **Rationale:** Without enforcement, Login Item + manual launch produces doubled notifications and racing cursor writes. The fix is standard macOS app behavior.
- **Evidence:** Review-team finding F5. Common macOS application pattern (NSApplication launch-detection).
- **Rejected alternatives:**
  - Allow multiple instances — rejected; doubled notifications.
  - Use a file lock — rejected as describing implementation; the behavioral commitment is "second launch surfaces the first and exits."
- **Linked technical notes:** —
- **Driven by findings:** F5
- **Dependent decisions:** —
- **Referenced in spec:** Edge Cases; Coordinations.

### D21: Setup and error icons are visually distinct

- **Question:** Should the menubar's setup state and error state share an icon (closing OI-2)?
- **Decision:** No. Setup uses a neutral/additive overlay (configure-me signal); error uses a reactive/warning overlay (attention-grabbing). Both are distinct from the idle and active states.
- **Rationale:** Users cannot distinguish "I haven't finished setting up" from "something broke" if the icons match. The spec body already required this for the setup flow; OI-2 was an unnecessary escape hatch.
- **Evidence:** Review-team finding F19. Norman affordance principle (signifier must reflect state); Nielsen heuristic 1 (visibility of system status).
- **Rejected alternatives:**
  - Same icon for both states — rejected; causes user confusion.
  - Distinct icons only when in conflict (e.g., setup-during-error) — rejected; adds complexity for no benefit.
- **Linked technical notes:** —
- **Driven by findings:** F19
- **Dependent decisions:** —
- **Referenced in spec:** First-run / setup alternate flow (step 1); Error state alternate flow (step 1); User Interactions (menubar icon states).

### D22: Dropdown model is a separate data path from cursor-driven notifications

- **Question:** Are the notification firing and the dropdown content driven by the same data?
- **Decision:** No. The notification path is cursor-driven (D10/D17): each poll determines which events are newer than each (repo, PR, event-type) cursor and fires a notification per new event. The dropdown path is an independent snapshot of GitHub's current state per tick, filtered by per-repo mode. The dropdown does not consult cursors — it reflects what GitHub currently says is outstanding.
- **Rationale:** Conflating the two is the only way to write internally-conflicting sentences such as "no notifications on add but the dropdown shows outstanding items immediately." Recognizing the two paths as separate resolves multiple downstream behaviors: silence is consistent with state visibility, dropped notifications don't vanish from awareness, mode changes update content without consulting cursors.
- **Rationale (continued):** Each path's correctness can be tested independently.
- **Evidence:** Review-team findings F11, F22. The separation is the only model consistent with all stated behaviors.
- **Rejected alternatives:**
  - One unified cursor-driven model — rejected; cannot model "currently outstanding" as opposed to "newly arrived."
  - Drop the dropdown content entirely and rely on notifications alone — rejected; conflicts with D6 (passive notifier + dropdown summary).
- **Linked technical notes:** —
- **Driven by findings:** F11, F22
- **Dependent decisions:** —
- **Referenced in spec:** Primary Flow (step 7); Coordinations (Data sources subsection); throughout User Interactions.
