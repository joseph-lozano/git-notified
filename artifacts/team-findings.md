# Team Findings: git-notified

Findings raised by the review team (junior-developer, user-experience-designer, edge-case-explorer, test-engineer) for the git-notified menubar app, and how each was resolved. Behavioral outcomes live in [../feature-specification.md](../feature-specification.md); decisions affected live in [decision-log.md](decision-log.md).

## Major findings

### F1: Cursor data model described at two incompatible granularities

- **Agent:** junior-developer (OQ-1, Conflict-1, US-1), edge-case-explorer (EC12), test-engineer (T1, T5, T6)
- **Finding:** D10 specifies a single cursor per (repo, event-type) — a high-water mark — but the "Changing a repository's mode" flow requires retaining cursors for individual pull requests so that narrowing then re-widening does not re-deliver previously suppressed events. A single high-water mark per (repo, event-type) cannot model per-PR retention. The two descriptions cannot both be implemented as written. Test-engineer additionally flagged that "cursor advances" is not testably observable without a concrete data shape.
- **Resolution:** Decision escalated to the user. Selected: cursor is per (repo, PR, event-type) — a high-water mark stored per pull request per event type. D10 is rewritten and a new full decision D17 records the formal model. The state structure example is added to D7. The spec's Primary Flow step 5 is rewritten to describe the per-PR comparison. The mode-change flow's "cursors retained" sentence is rewritten to behavioral outcome.
- **Resolved by:** user input
- **Affected decisions:** D7, D10, D17 (new)
- **Affected tech-notes:** —
- **Changed in spec:** Primary Flow (steps 2, 5, 9); Changing a repository's mode (steps 3, 4); Removing a repository; Coordinations.

### F2: "Event ID" ordering assumption undefined

- **Agent:** junior-developer (OQ-2, A1), edge-case-explorer (EC12)
- **Finding:** The cursor model treats event IDs as comparable scalars but the spec does not state what ordering property is required. GitHub event IDs are not strictly monotonic across all event types under all conditions (cross-shard assignment, eventual consistency). If `gh`'s response ordering or the assumed ordering property is violated, events may be silently skipped.
- **Resolution:** Spec Primary Flow step 5 now states the ordering assumption explicitly: events are ordered by their GitHub-reported `updated_at` timestamp; the cursor is the timestamp of the most recent event already delivered. If `gh`'s response does not include a timestamp for a given event type, the app uses the response's natural ordering (newest first) and the event's globally-unique ID as a tiebreaker. D17 (new) records this ordering rule.
- **Resolved by:** evidence (GitHub API convention) + user-input cursor-model decision (F1)
- **Affected decisions:** D10, D17 (new)
- **Affected tech-notes:** —
- **Changed in spec:** Primary Flow (step 5).

### F3: macOS Notification Center may silently drop events during burst delivery

- **Agent:** edge-case-explorer (EC2), junior-developer (OQ-3)
- **Finding:** The spec commits to "each event delivered to the user exactly once." The app can guarantee firing at most one notification per event, but macOS Notification Center may coalesce or drop notifications under burst load (catch-up after a long outage, ten repos in `all` mode, etc.). The user has no way to detect dropped notifications and the cursor has already advanced — the event becomes invisible.
- **Resolution:** Weaken the spec's delivery guarantee. The spec now states the app fires at most one notification per event; OS delivery is best-effort. The dropdown is declared authoritative for currently-outstanding state, providing a recovery surface for dropped notifications. The Coordinations row for macOS Notification Center is updated with the rate-limit caveat.
- **Resolved by:** evidence (macOS Notification Center documented behavior)
- **Affected decisions:** D10, D11
- **Affected tech-notes:** —
- **Changed in spec:** Outcome; Primary Flow (step 6); Error state alternate flow (step 4); Coordinations.

### F4: `gh` not on the GUI app's PATH is misdiagnosed as "not installed"

- **Agent:** edge-case-explorer (EC1)
- **Finding:** macOS GUI apps launched from Login Items or Launchpad inherit the system PATH (`/usr/bin:/bin`), not the user's shell PATH. Homebrew installs `gh` to `/opt/homebrew/bin` (Apple Silicon) or `/usr/local/bin` (Intel). The app would enter setup state saying "Install gh" when `gh` is actually installed but unreachable. The user can never recover by following the setup checklist.
- **Resolution:** New edge-case row distinguishes "`gh` not installed" from "`gh` installed but not reachable from app's PATH." First-run flow updated: when `gh` is not reachable, the setup checklist row reads "gh not found — see Troubleshooting if gh is already installed" with a link to a troubleshooting note about PATH for GUI apps.
- **Resolved by:** evidence (documented macOS GUI app behavior)
- **Affected decisions:** D15
- **Affected tech-notes:** —
- **Changed in spec:** First-run / setup alternate flow (step 2); Edge Cases.

### F5: Two instances on the same Mac produce duplicate notifications

- **Agent:** edge-case-explorer (EC3)
- **Finding:** If the user has the app set as a Login Item and also launches it manually, two processes read and write to the same `state.json`. Both poll, both fire notifications. Read-then-write races mean cursors are not reliably advanced. The user sees doubled notifications.
- **Resolution:** Add a behavioral requirement: only one instance runs at a time on a given Mac. A second launch attempt activates the existing instance's dropdown and exits. New full decision D20 records this. Edge-case row added.
- **Resolved by:** evidence (common macOS pattern: NSApplication launchedBefore / single-instance enforcement)
- **Affected decisions:** D20 (new)
- **Affected tech-notes:** —
- **Changed in spec:** Edge Cases; Out of Scope is unchanged.

### F6: Pagination is not addressed — events on later `gh` response pages are silently missed

- **Agent:** edge-case-explorer (EC5)
- **Finding:** The spec describes a single "ask GitHub through `gh` for the current set" without mentioning pagination. `gh` paginates by default (typically 30 results per page). On any active repo with more than 30 in-scope PRs or more than 30 new events between ticks, page-2+ events are never seen. Cursors advance based on page-1 data, so those events are permanently lost. Systematic silent miss, not edge-case.
- **Resolution:** Primary Flow step 3 now requires: "For each repository, the app fetches the complete current set of relevant events across all pages of any paginated `gh` response before comparing against cursors." Coordinations updated.
- **Resolved by:** evidence (gh CLI documented pagination behavior)
- **Affected decisions:** D10
- **Affected tech-notes:** —
- **Changed in spec:** Primary Flow (step 3); Coordinations.

### F7: 24h Recent Activity window vs. long silence — silent data loss

- **Agent:** edge-case-explorer (EC4), junior-developer (OQ-4), user-experience-designer (UX-007 related)
- **Finding:** When the user silences (paused) notifications for more than 24 hours, events arrive, advance cursors, do not fire notifications, and then age out of the 24h Recent Activity window. The user has no signal that activity occurred. Same risk: a Mac sleeping for >24h then waking. Notifications fire on catch-up but events older than 24h don't appear in the dropdown's Recent Activity section, creating notification/dropdown asymmetry.
- **Resolution:** Recent Activity window is computed against GitHub-reported event timestamps but the window slides relative to "events the app has observed since it was last clean." When the app un-silences (or wakes from sleep with backlog), the dropdown shows a "Silenced for N hours — N new items below" or "Caught up on N events from while you were offline" banner above Recent Activity, and the window for that batch is extended to cover the silenced/offline duration up to a ceiling of 7 days. This makes silent loss visible without unbounded growth.
- **Resolved by:** user input (recommendation accepted) — applied per the pause-rename answer.
- **Affected decisions:** D13
- **Affected tech-notes:** —
- **Changed in spec:** User Interactions (Recent activity); Silencing notifications alternate flow.

### F8: Mode narrow → re-widen behavior contradicts the spec's stated intent

- **Agent:** edge-case-explorer (EC9), junior-developer (Conflict-1)
- **Finding:** Spec step 3 says retained cursors prevent re-delivery on re-widening — but during the narrow period, cursors for non-matching PRs are never advanced (the app isn't scanning them). On re-widen, events from the narrow window are newer than the retained cursor and produce a notification flood.
- **Resolution:** Decision escalated to user. Selected: re-widen is treated as a fresh add — newly-in-scope PRs get cursors initialized to current high-water marks, no backfill notifications fire. D12 is extended to cover this case. Spec mode-change flow rewritten.
- **Resolved by:** user input
- **Affected decisions:** D12
- **Affected tech-notes:** —
- **Changed in spec:** Changing a repository's mode (step 2).

### F9: CI "fail" notification trigger is undefined for mixed-state check suites

- **Agent:** edge-case-explorer (EC7)
- **Finding:** The spec says the app queries "current CI conclusion" but does not define what triggers a "CI failed" notification when a PR has 10 checks, one of which has failed while others are still running. Possible interpretations produce either notification spam (one per failing check) or silent miss (waiting for all to settle and missing failures that are later masked).
- **Resolution:** Spec now defines: a pull request's CI conclusion is `failing` when at least one check in the most recent check suite has a failure conclusion AND the suite has not been superseded by a newer commit. `passing` when all checks pass. `in_progress` otherwise. Notification fires on transitions between these aggregated states, not per-check. Edge-case row added.
- **Resolved by:** evidence (matches GitHub's own "Checks" tab aggregation behavior)
- **Affected decisions:** D10
- **Affected tech-notes:** —
- **Changed in spec:** Primary Flow (step 3); Edge Cases.

### F10: Participating eligibility requires history scan but polling is described as delta-based

- **Agent:** junior-developer (OQ-7)
- **Finding:** The participating definition (D4) includes "has previously commented or reviewed" and "is @mentioned." For a months-old PR, the app would need to scan historical comments to know if the user participated. The spec describes polling as delta-based but participating-eligibility appears to require full-history awareness per tick.
- **Resolution:** Spec clarifies: participating-eligibility for each PR in `participating` mode is evaluated on each tick by asking `gh` for "PRs involving the user in this repository" — GitHub's API supports this directly via the `involves:` qualifier on the search API and `gh pr list --search "involves:@me"`. The app does not maintain its own per-PR eligibility cache; it relies on GitHub's involvement determination. The behavioral commitment is: "if GitHub considers you involved on this PR, the app considers you participating."
- **Resolved by:** evidence (GitHub search qualifiers documentation)
- **Affected decisions:** D4
- **Affected tech-notes:** —
- **Changed in spec:** Primary Flow (steps 3, 4).

### F11: Dropdown content and notifications are two data sources, but the spec conflates them

- **Agent:** junior-developer (Conflict-2, US-2), test-engineer (C1)
- **Finding:** Notifications fire based on cursor comparison (new since cursor). The dropdown shows "currently outstanding state" (e.g., PRs whose CI is failing right now, regardless of whether the user was notified). These are two separate data paths. The spec describes both but never declares them as separate, leading to internally-conflicting sentences.
- **Resolution:** New section in spec explicitly names the two data paths. The notification path is cursor-driven (D10/D17). The dropdown path is a snapshot of current `gh`-reported state, filtered by the per-repo mode, recomputed each tick. The dropdown does NOT depend on cursors. New full decision D22 records this separation.
- **Resolved by:** evidence (this is the only model consistent with all stated behaviors)
- **Affected decisions:** D6, D10, D22 (new)
- **Affected tech-notes:** —
- **Changed in spec:** Primary Flow (step 7 split); User Interactions; new "Data sources" subsection under Coordinations.

### F12: Renamed/transferred repo error treatment is per-app instead of per-repo

- **Agent:** edge-case-explorer (EC11, EC16), user-experience-designer (UX-015), junior-developer (OQ-6)
- **Finding:** A 404 on a single watched repo currently triggers app-level error state in some readings of the spec. The user is shown a global error banner with no per-repo Remove action. The rename case in particular leaves the user stranded.
- **Resolution:** Edge Cases clarified: per-repo 404 (rename, transfer, delete, access revoked) shows a "No access" row on that repository's dropdown rows with cause text and an inline Remove action. The global menubar icon enters error state only if ALL watched repos are failing or the failure is app-level (auth, network, rate limit, parse error). D11 amended.
- **Resolved by:** evidence (consistent with the existing "Watched repo became private" row)
- **Affected decisions:** D11
- **Affected tech-notes:** —
- **Changed in spec:** Edge Cases; Error state alternate flow; User Interactions.

### F13: `gh auth status` failures cannot distinguish "not signed in" from "network unavailable"

- **Agent:** edge-case-explorer (EC6)
- **Finding:** On app launch (especially Login Item launch during early network setup or DNS failure), `gh auth status` may fail with a network error. The spec currently treats any failure as "not signed in" and enters setup state — telling the user to run `gh auth login` when they don't need to.
- **Resolution:** Spec First-run flow now distinguishes: if `gh auth status` fails with a network-related error (recognizable via stderr content or specific exit codes), the app enters the error state, not the setup state, and retries the check on the next tick or on network change. The setup state is entered only when `gh auth status` reports an authentication failure conclusively.
- **Resolved by:** evidence
- **Affected decisions:** D15
- **Affected tech-notes:** —
- **Changed in spec:** First-run / setup alternate flow; Edge Cases.

### F14: `gh` output-format-change error wedges the app permanently

- **Agent:** edge-case-explorer (EC10), junior-developer (Conflict-4)
- **Finding:** The spec says "polling pauses on that failure mode until the user dismisses or restarts." This contradicts D14's exponential-backoff pattern, uniquely wedges the app, and leaks implementation mechanics ("polling pauses"). The user dismissing the banner does not fix the underlying parse error.
- **Resolution:** Aligned with D14: parse errors are treated as normal transient errors with backoff. If they persist, the error banner shows "Could not read GitHub response — gh may have been updated" with Retry and Report Issue actions. No special wedge state.
- **Resolved by:** evidence (consistency with D14)
- **Affected decisions:** D14
- **Affected tech-notes:** —
- **Changed in spec:** Edge Cases.

### F15: Pause language hides permanent data discard

- **Agent:** user-experience-designer (UX-007), junior-developer (OQ-5)
- **Finding:** "Pause notifications" implies queue-and-hold, but the spec discards events that arrive during the pause. The user has no signal that events were discarded, leading to silent miss confusion (especially after pauses longer than 24h).
- **Resolution:** Decision escalated to user (combined with notif format Q). Selected: rename to "Silence notifications." On un-silence, the dropdown shows a transient summary banner above Recent Activity: "Silenced for N minutes — N items arrived." This makes the discard behavior legible. D13 updated. F7 directly resolved by same change.
- **Resolved by:** user input
- **Affected decisions:** D13
- **Affected tech-notes:** —
- **Changed in spec:** Silencing notifications alternate flow; User Interactions.

### F16: Notification body format truncates on long repo names

- **Agent:** user-experience-designer (UX-010)
- **Finding:** macOS banner notifications truncate the title around 50–60 characters. The format `{owner/name}#{num} — {event description}` leads with the least-actionable info; long repo names clip the event description.
- **Resolution:** Decision escalated to user. Selected: notification title = event description ("Review requested by @alice"), subtitle = repo/PR reference (`acme/api#421 — Add OAuth login`). Most actionable info wins the title slot and survives truncation. New full decision D18 records this. Spec User Interactions rewritten.
- **Resolved by:** user input
- **Affected decisions:** D18 (new)
- **Affected tech-notes:** —
- **Changed in spec:** Primary Flow (step 6); User Interactions.

### F17: Accessibility behavior is completely unspecified

- **Agent:** user-experience-designer (UX-012, UX-013)
- **Finding:** No accessible name, role, keyboard navigation, or VoiceOver behavior specified anywhere. Badge described only as "badge or dot" — risks WCAG 1.4.1 (color-only encoding) if implemented as colored dot. Tauri's default web layer will produce inaccessible output without explicit work.
- **Resolution:** Decision escalated to user. Selected: include a behavioral accessibility section in the spec. Spec now declares: dropdown section headings are announced as headings; rows are announced as buttons with their full label; the silence toggle announces its on/off state; the menubar icon has a state-inclusive accessible label ("git-notified, 3 items outstanding" / "git-notified, setup required" / "git-notified, error"). Badge is a count badge (number) rather than a colored dot, satisfying WCAG 1.4.1 through shape/text rather than color alone. Dropdown is fully keyboard-navigable. New full decision D19 records the accessibility commitment.
- **Resolved by:** user input
- **Affected decisions:** D19 (new)
- **Affected tech-notes:** —
- **Changed in spec:** User Interactions (new Accessibility subsection); menubar icon description.

### F18: "Settings…" is a YAGNI affordance with no defined content

- **Agent:** user-experience-designer (UX-016)
- **Finding:** "Settings…" appears in the dropdown control list. No content is described. Per-repo configuration is in Manage repositories; the silence toggle has its own affordance. No setting has been identified that needs its own panel.
- **Resolution:** "Settings…" is removed from the dropdown control list and moved to Deferred (YAGNI) with reopen trigger: "a setting exists that cannot be expressed in per-repo mode or the silence toggle."
- **Resolved by:** evidence (YAGNI rule: fails evidence test)
- **Affected decisions:** —
- **Affected tech-notes:** —
- **Changed in spec:** User Interactions (dropdown controls list); Deferred (YAGNI).

### F19: Setup and error icons may share the same visual

- **Agent:** user-experience-designer (UX-002)
- **Finding:** OI-2 left open whether setup and error states share an icon. The First-run flow already says "a distinct icon, not the error state" — internal contradiction.
- **Resolution:** Commit to distinct icons: setup icon is neutral/additive (configure-me signal); error icon is reactive/warning. New full decision D21 records this. OI-2 closed.
- **Resolved by:** evidence + user input (a11y commitment supports this)
- **Affected decisions:** D21 (new)
- **Affected tech-notes:** —
- **Changed in spec:** User Interactions (menubar icon); Open Items (OI-2 removed).

### F20: "Manage repositories panel" interaction model is unspecified

- **Agent:** user-experience-designer (UX-006)
- **Finding:** The panel is named but its presentation model (second popover, push view, separate window) is not stated. macOS HIG prohibits nested popovers.
- **Resolution:** Specified as a push view within the same popover, with a "Done" control returning to the main dropdown.
- **Resolved by:** evidence (macOS HIG)
- **Affected decisions:** —
- **Affected tech-notes:** —
- **Changed in spec:** User Interactions.

### F21: Mechanics-leaking sentences throughout the spec

- **Agent:** test-engineer (final section), user-experience-designer (Mechanics-leaking summary)
- **Finding:** Several spec sentences leak implementation mechanics: "Their cursors are retained" (mode-change), "configuration entry and stored cursors are deleted" (remove-repo), "reads its configuration... state file" (Primary Flow step 2), "writes are atomic" (Coordinations), "polling pauses on that failure mode" (Edge Cases), "exponentially-increasing delays" (Error state). Each rewritten to behavioral outcome.
- **Resolution:** Sentences rewritten throughout the spec. The implementation mechanics that remain load-bearing for stated behavior (atomic writes for crash safety; ordered polling for cursor correctness) are captured in the decision log under D7 (`Evidence:` field) and D17 (cursor model). No tech-notes file is created because the mechanics are discoverable from the chosen platform conventions and library defaults.
- **Resolved by:** evidence (operating principles of the skill)
- **Affected decisions:** D7, D10, D11, D14, D17 (new)
- **Affected tech-notes:** —
- **Changed in spec:** Primary Flow (step 2); Adding a repo; Changing a repository's mode; Removing a repo; Error state; Coordinations.

### F22: Untestable commitments (spec sentences not testably observable)

- **Agent:** test-engineer (C1, C2, C3)
- **Finding:** "Dropdown is updated", "menubar icon switches to error state", "top row names the cause" are committed as behavior but provide no observable structure for tests. C1: dropdown model schema; C2: icon state enum; C3: status banner field with cause enum.
- **Resolution:** The spec now commits to: (a) a dropdown model exposing typed sections (reviews_requested, ci_failing, recent_activity) each with a list of rows that include `repo`, `pr_number`, `title`, `event_summary`, `age`, `url`; (b) a menubar icon state value with the enum `idle | active | setup | error`; (c) a status banner that is either absent or a structured value with a named cause category (`NotSignedIn | RateLimited | NetworkUnavailable | InsufficientScope | ParseError | NotificationsDisabled | CorruptedState`) and an action label. These are behavioral surfaces, not implementation details — they make the spec testable.
- **Resolved by:** evidence
- **Affected decisions:** D6, D11
- **Affected tech-notes:** —
- **Changed in spec:** User Interactions (entire section refined).

### F23: First-run → first-poll has a silent latency gap

- **Agent:** junior-developer (US-4)
- **Finding:** After the user completes the setup checklist, polling begins "on the next tick," which can be up to 60s away. The first run feels broken.
- **Resolution:** Spec now states: completing setup (signing in + adding at least one repository) immediately triggers a poll, not a wait for the next scheduled tick.
- **Resolved by:** evidence
- **Affected decisions:** D15
- **Affected tech-notes:** —
- **Changed in spec:** First-run / setup alternate flow (step 4).

### F24: Mode change feedback timing ambiguous ("next render" vs "next tick")

- **Agent:** junior-developer (US-5), user-experience-designer (UX-011)
- **Finding:** Two separate sentences use different phrases — "updates on next render" and "next tick honors it" — without distinguishing config-level feedback from downstream tick-level effects.
- **Resolution:** Spec distinguishes: (a) the manage-repositories panel reflects the new mode value immediately (optimistic config update — config is written synchronously); (b) the dropdown's content (which PRs appear under which sections) updates on the next poll tick. Both phrasings clarified.
- **Resolved by:** evidence
- **Affected decisions:** —
- **Affected tech-notes:** —
- **Changed in spec:** Changing a repository's mode; User Interactions.

### F25: Empty states are undefined for every dropdown section

- **Agent:** user-experience-designer (UX-004)
- **Finding:** Sections under "Reviews requested", "CI failing", and "Recent activity" have no specified empty-state copy or behavior. Users cannot distinguish "nothing outstanding" from "polling broken."
- **Resolution:** Each section has explicit empty-state text in the spec ("No pending review requests" / "No failing CI" / "No recent activity in the last 24 hours"). A footer line shows "Last checked Nm ago" or "Last check failed — Retry."
- **Resolved by:** evidence
- **Affected decisions:** —
- **Affected tech-notes:** —
- **Changed in spec:** User Interactions.

### F26: Icon flap on alternating success/failure

- **Agent:** edge-case-explorer (EC13)
- **Finding:** A single failed poll flips the icon to error; a single subsequent success flips it back. On a flaky network this produces visual flap that erodes trust.
- **Resolution:** Hysteresis policy specified: icon transitions to error after a single failed poll (low threshold — failure must be visible) but only transitions back to idle/active after 2 consecutive successful polls. Documented in the Error state flow.
- **Resolved by:** evidence
- **Affected decisions:** D11
- **Affected tech-notes:** —
- **Changed in spec:** Error state alternate flow.

### F27: CI restart spam (green → fail → green from ref-update) — already deferred, reopen-when text vague

- **Agent:** edge-case-explorer (EC8)
- **Finding:** Force-push triggering a fresh CI run produces fail-then-pass transitions with new event IDs, bypassing the dedup. Already in Deferred (YAGNI) but the reopen-when text doesn't name this specific pattern.
- **Resolution:** Deferred entry updated: "Reopen when: users report chatty CI loops — particularly from force-push-triggered CI restarts on active PRs — producing too many notifications." No spec change.
- **Resolved by:** evidence
- **Affected decisions:** —
- **Affected tech-notes:** —
- **Changed in spec:** Deferred (YAGNI).

### F28: Scope-revocation recovery instruction is too specific

- **Agent:** junior-developer (YAGNI-3)
- **Finding:** "Run `gh auth refresh -s repo`" assumes the app can detect which scope was lost. Simpler version: generic "re-run `gh auth login`" satisfies the same evidence.
- **Resolution:** Edge-case row simplified to "Run `gh auth login` to re-grant required scopes." Specific scope-detection is deferred.
- **Resolved by:** evidence (YAGNI simpler-version replacement)
- **Affected decisions:** —
- **Affected tech-notes:** —
- **Changed in spec:** Edge Cases.

### F29: OI-1 (24h lookback) — close it

- **Agent:** edge-case-explorer (EC19), self
- **Finding:** OI-1 marks 24h as possibly-configurable. The spec already hardcodes 24h in v1; the "configurability" decision is itself a YAGNI deferral, not an open question.
- **Resolution:** OI-1 removed from Open Items. Deferred (YAGNI) gains a "Configurable Recent Activity window" entry with reopen trigger: "users report 24h is consistently the wrong window for their workflow."
- **Resolved by:** evidence
- **Affected decisions:** —
- **Affected tech-notes:** —
- **Changed in spec:** Open Items; Deferred (YAGNI); User Interactions.

### F30: Notification-history reset state warning copy

- **Agent:** edge-case-explorer (EC17)
- **Finding:** "Reset state" in the corrupted-state-file flow clears all cursors, which causes a catch-up notification flood on the next tick. The user doesn't anticipate this consequence when clicking the button under stress.
- **Resolution:** Button label includes consequence: "Reset state (you may receive notifications for recent events)." Edge-case row updated.
- **Resolved by:** evidence
- **Affected decisions:** —
- **Affected tech-notes:** —
- **Changed in spec:** Edge Cases.

### F31: Two-Macs edge case is emergent, not "handled"

- **Agent:** junior-developer (YAGNI-2)
- **Finding:** The "user on two Macs" row in Edge Cases described the behavior as a handled case, implying implementation effort. It is in fact the default behavior (no coordination) and should be framed as Out of Scope, not Handled.
- **Resolution:** The row is moved from Edge Cases to Out of Scope, where multi-machine sync already lives, and noted as "emergent — no implementation work; each install operates independently."
- **Resolved by:** evidence (consistent with D16 + Out of Scope framing)
- **Affected decisions:** —
- **Affected tech-notes:** —
- **Changed in spec:** Edge Cases; Out of Scope.

### F32: Section name "Recent activity" lacks information scent

- **Agent:** user-experience-designer (UX-001)
- **Finding:** "Recent activity" doesn't signal what kind. "New comments &amp; reviews" is more scannable and matches what's in the section.
- **Resolution:** Section renamed to "New comments &amp; reviews."
- **Resolved by:** evidence
- **Affected decisions:** —
- **Affected tech-notes:** —
- **Changed in spec:** User Interactions; Silencing flow (banner text updated).

## Minor edits

- F33: Add "Last checked Nm ago" footer to the dropdown — user-experience-designer — User Interactions.
### F34: Visual separator between utility actions and Quit in the dropdown

- **Agent:** user-experience-designer
- **Finding:** The dropdown has no visual separator between the utility actions (Add repository, Manage repositories) and the destructive Quit action, making them visually run together.
- **Resolution:** Visual separator added between the utility actions and Quit.
- **Resolved by:** evidence (macOS HIG menu separator convention)
- **Affected decisions:** —
- **Affected tech-notes:** —
- **Changed in spec:** User Interactions (dropdown controls list).
- F35: Setup checklist step "Sign in with `gh auth login`" displays command in a copy-able block — user-experience-designer — First-run flow.
- F36: Setup checklist step "Add a repository" exposes an action button rather than text-only — user-experience-designer — First-run flow.
- F37: Setup checklist step "Install gh" includes a link to `cli.github.com` — user-experience-designer — First-run flow.
- F38: Mode change in Manage repositories updates the control immediately (optimistic) before next tick — user-experience-designer — User Interactions.
### F39: Clock skew clarification: Recent Activity window uses GitHub event timestamps, not local clock

- **Agent:** edge-case-explorer
- **Finding:** The spec was ambiguous about whether the 24h window was measured against the local system clock or the GitHub-reported event timestamp. Using the local clock would cause edge cases where events appear/disappear depending on clock drift between the Mac and GitHub's servers.
- **Resolution:** Spec now explicitly states: the 24h window is measured against the GitHub-reported event timestamp, not the local clock.
- **Resolved by:** evidence (avoids local clock drift causing window inconsistency)
- **Affected decisions:** —
- **Affected tech-notes:** —
- **Changed in spec:** User Interactions (New comments & reviews section).
- F40: Silenced-then-woken summary banner copy: "Silenced for N minutes — N items arrived" — user-experience-designer + edge-case-explorer — Silencing flow.
- F41: macOS-standard silence toggle uses checkmark indicator + label changes between "Silence notifications" / "Silenced" — user-experience-designer — User Interactions.
