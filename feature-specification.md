# Feature Specification: git-notified (Mac Menubar GitHub Notifier)

A macOS menubar application that watches user-selected GitHub repositories through the user's existing `gh` CLI session and surfaces review requests, CI outcomes, comments, and reviews as native notifications and as a summary dropdown attached to the menubar icon.

## Outcome

A developer on macOS, after opting a set of repositories into the app, receives a native macOS notification whenever (a) someone requests their review, (b) CI on one of their in-scope pull requests transitions between passing and failing, (c) a new comment lands on an in-scope pull request, or (d) a new review is submitted on an in-scope pull request. The same activity is available at a glance by clicking the menubar icon, which shows a categorized summary of currently outstanding items. Clicking a notification or any dropdown row opens the corresponding pull request in the user's default browser. The user never has to think about authentication separately from `gh`. The app fires at most one notification per event, even across restarts; OS-level notification delivery is best-effort, and the dropdown remains the authoritative view of currently outstanding state.

## Actors and Triggers

- **Actors**
  - **End user** — a single developer running the app on their own Mac. Single-user, single-host, single GitHub account in v1.
  - **GitHub** — the external system whose pull-request activity the app observes, accessed indirectly through the `gh` CLI.
  - **`gh` CLI** — the user-installed and user-authenticated GitHub command-line client; the sole channel through which the app reads GitHub state and the sole owner of the user's GitHub credentials ([D2](artifacts/decision-log.md#d2-auth-relies-entirely-on-gh-session)).
  - **macOS Notification Center** — the native system surface where notifications appear.

- **Triggers**
  - **Recurring poll** — the app polls GitHub roughly once per minute through `gh` to detect new activity ([D14](artifacts/decision-log.md#d14-polling-cadence-single-global-tick-jittered-backoff)).
  - **User adds a repository** — through the menubar's "Add repository" affordance.
  - **User changes a repository's mode** — switching between off, participating, and all.
  - **User toggles silence** — through the dropdown's silence control ([D13](artifacts/decision-log.md#d13-silence-notifications-toggle)).
  - **App launch / wake from sleep** — triggers a setup check and an immediate poll.
  - **Completing first-run setup** — adding the first repository immediately triggers a poll rather than waiting for the next scheduled tick ([F23](artifacts/team-findings.md#f23-first-run--first-poll-has-a-silent-latency-gap)).

- **Preconditions**
  - `gh` is installed and reachable from the app's runtime environment.
  - The user is signed in to GitHub through `gh auth login` with at least `repo` and `read:org` scopes.
  - The user has granted the app permission to deliver notifications.
  - At least one repository has been added with a mode other than off (otherwise the app runs idle and shows an empty dropdown).

## Primary Flow

1. The user launches the app. The app verifies that `gh` is reachable and that `gh auth status` reports a signed-in account ([D15](artifacts/decision-log.md#d15-first-run-handshake-blocks-on-gh-install--auth)). If either check fails the app enters its setup state or error state (see the First-run / setup and Error state alternate flows) and does not begin polling.
2. The app loads previously-saved state — the list of watched repositories with their per-repo mode and the per-pull-request, per-event-type cursors used to recognize already-delivered events ([D17](artifacts/decision-log.md#d17-cursor-data-model-per-repo-pr-event-type)) — and resumes from where it left off without re-delivering past events.
3. On a recurring tick of roughly one minute, jittered to avoid synchronized bursts ([D14](artifacts/decision-log.md#d14-polling-cadence-single-global-tick-jittered-backoff)), the app asks GitHub through `gh` for the current set of: (a) pull requests in each watched repository that fall within the user's selected mode for that repository, and (b) for each such pull request, its current CI conclusion and any new comments or reviews. **For any paginated response from `gh`, the app fetches all pages before comparing against cursors** ([F6](artifacts/team-findings.md#f6-pagination-is-not-addressed--events-on-later-gh-response-pages-are-silently-missed)).
4. For each repository with mode `participating`, the matching pull requests are those GitHub considers the user involved in — author, assignee, directly requested reviewer, member of a team requested as a reviewer, @mention recipient, or previous commenter/reviewer. The app relies on GitHub's `involves:@me` filter as the source of truth for involvement; it does not maintain its own per-PR eligibility cache ([D4](artifacts/decision-log.md#d4-participating-definition-includes-team-review-requests), [F10](artifacts/team-findings.md#f10-participating-eligibility-requires-history-scan-but-polling-is-described-as-delta-based)). For mode `all`, every open pull request in the repository matches. For mode `off`, the repository is skipped entirely — no `gh` call is made for it ([D3](artifacts/decision-log.md#d3-per-repo-mode-dropdown--off--participating--all)).
5. The app compares each observed event against the stored cursor for the (repository, pull request, event-type) triple. Events strictly newer than the cursor — determined by the GitHub-reported `updated_at` timestamp, with the event's globally-unique ID as tiebreaker — are treated as new and the cursor is advanced past them ([D10](artifacts/decision-log.md#d10-one-notification-per-event-dedup-by-cursor-comparison), [D17](artifacts/decision-log.md#d17-cursor-data-model-per-repo-pr-event-type), [F2](artifacts/team-findings.md#f2-event-id-ordering-assumption-undefined)). A pull request's CI conclusion is treated as `failing` when at least one check in the most recent check suite has a failure conclusion and the suite has not been superseded by a newer commit, `passing` when all checks pass, and `in_progress` otherwise; the app fires a notification only when the aggregate state transitions between `failing` and `passing` ([F9](artifacts/team-findings.md#f9-ci-fail-notification-trigger-is-undefined-for-mixed-state-check-suites)).
6. For each new event, the app fires at most one macOS notification. The notification's title carries the event description ("Review requested by @alice", "CI failed on build #3"); its subtitle carries the pull request reference and title (`acme/api#421 — Add OAuth login`) ([D18](artifacts/decision-log.md#d18-notification-format-title-event-subtitle-pr-ref)). If the silence toggle is currently active, the notification is suppressed but the dropdown is still updated; cursors still advance ([D13](artifacts/decision-log.md#d13-silence-notifications-toggle)). macOS Notification Center may coalesce or drop individual notifications during burst delivery; the dropdown remains the authoritative current-state view ([F3](artifacts/team-findings.md#f3-macos-notification-center-may-silently-drop-events-during-burst-delivery)).
7. The app independently refreshes its **dropdown model** — a separate data path from the cursor-based notification path ([D22](artifacts/decision-log.md#d22-dropdown-model-is-a-separate-data-path-from-cursor-driven-notifications)). The dropdown model is a snapshot of GitHub's current state filtered by per-repo mode, recomputed each tick. It contains three sections, each with a list of typed rows containing `repo`, `pr_number`, `title`, `event_summary`, `age`, and `url` ([F22](artifacts/team-findings.md#f22-untestable-commitments-spec-sentences-not-testably-observable)): (a) Reviews requested, (b) CI failing, (c) New comments &amp; reviews. The menubar icon shows a count badge — a numeric overlay — whenever any section is non-empty ([D19](artifacts/decision-log.md#d19-accessibility-commitment), [D6](artifacts/decision-log.md#d6-menubar-passive-notifier-plus-dropdown-summary)).
8. When the user clicks a notification, the app opens the corresponding pull request URL in the default browser ([D9](artifacts/decision-log.md#d9-click-action-opens-pr-in-default-browser)). The same happens when the user clicks a row in the menubar dropdown.
9. The cursors are persisted after each tick that advances any of them so a restart resumes without re-delivering events. A crash mid-write does not leave the saved state in a partially-updated form ([D7](artifacts/decision-log.md#d7-storage-plain-json-in-app-support-dir)).

## Alternate Flows and States

### First-run / setup

- **Entry condition:** the app launches and either (a) `gh` is not reachable from the app's runtime environment, (b) `gh auth status` reports no signed-in account with confidence (not a network error — see Error state below), or (c) the user has never added a repository.
- **Sequence:**
  1. The menubar icon enters its setup state — a distinct icon from the error icon ([D21](artifacts/decision-log.md#d21-setup-and-error-icons-are-visually-distinct)).
  2. The dropdown shows a setup checklist. Each row covers one prerequisite. The next pending step is the only one prompting action; completed steps are checked off.
     - "Install `gh`" — includes a link to `cli.github.com`. If the app detected that `gh` is installed somewhere but unreachable from its environment, this row shows "`gh` not found in this app's environment — see Troubleshooting if `gh` is already installed" with a link to a troubleshooting note about GUI app PATH ([F4](artifacts/team-findings.md#f4-gh-not-on-the-gui-apps-path-is-misdiagnosed-as-not-installed)).
     - "Sign in with `gh auth login`" — displays the command in a copy-able block.
     - "Add a repository" — exposes an action button that opens the Add Repository picker.
  3. The app does not poll while any setup step is incomplete.
  4. As the user resolves each step, the app re-checks and advances. When all setup steps are complete and at least one repository has been added, the app immediately fires its first poll rather than waiting for the next scheduled tick ([F23](artifacts/team-findings.md#f23-first-run--first-poll-has-a-silent-latency-gap)), and the icon transitions to the normal state.
- **Exit:** all setup steps complete and polling has begun.

### Adding a repository

- **Entry condition:** user clicks "Add repository" in the dropdown.
- **Sequence:**
  1. A picker appears with a combined search-and-paste input ([D8](artifacts/decision-log.md#d8-add-repo-ux-picker-plus-paste)).
  2. As the user types, results from `gh repo list` are shown. If the user pastes a string matching `owner/name` or a full GitHub URL, that exact reference is offered as a result even when it is not in the `gh repo list` set.
  3. The user picks a repository and chooses a starting mode from a dropdown defaulting to `participating`.
  4. On confirm, the repository is added to the watched list with the chosen mode. The app immediately queries that repository's current state and records the resulting cursors so that pre-existing activity will not trigger notifications ([D12](artifacts/decision-log.md#d12-no-backfill-notifications-on-add-repo-or-mode-widen)). Currently-outstanding items (e.g., pending reviews requested of the user in this repo, currently-failing CI) appear in the dropdown right away because the dropdown is a separate data path from the cursor-driven notification path ([D22](artifacts/decision-log.md#d22-dropdown-model-is-a-separate-data-path-from-cursor-driven-notifications)).
- **Exit:** repository appears in the dropdown summary. Polling on the next tick includes it.

### Changing a repository's mode

- **Entry condition:** user picks a different mode for an already-watched repository.
- **Sequence:**
  1. The mode change is recorded immediately. The Manage repositories panel reflects the new mode value the instant the user makes the selection — no waiting for the next tick to confirm ([F24](artifacts/team-findings.md#f24-mode-change-feedback-timing-ambiguous-next-render-vs-next-tick)). The dropdown's content (which PRs appear under which sections) updates on the next poll tick.
  2. If the new mode widens scope (e.g., `participating` → `all`), pull requests that newly match are treated the same as a fresh add: their cursors are initialized to current high-water marks and no backfill notifications fire ([D12](artifacts/decision-log.md#d12-no-backfill-notifications-on-add-repo-or-mode-widen), [F8](artifacts/team-findings.md#f8-mode-narrow--re-widen-behavior-contradicts-the-specs-stated-intent)). This applies whether the widening is from initial add or after a previous narrowing.
  3. If the new mode narrows scope, pull requests that no longer match are dropped from the dropdown on the next tick. The cursors for those pull requests are not retained — narrowing is treated symmetrically with widening, and any later re-widening starts the affected PRs from fresh high-water marks.
  4. If the new mode is `off`, the repository is silenced. The app makes no `gh` calls for it. The dropdown drops its rows on the next tick. The repository's configuration entry is retained so the user does not have to re-pick it from the picker.
- **Exit:** the new mode is in effect.

### Removing a repository

- **Entry condition:** user picks "Remove from watch" for a repository.
- **Sequence:** the repository disappears from the watched list and from the dropdown on the next tick. If the user adds the same repository again later, the app treats it as a fresh add: no events that occurred during the removal interval generate notifications.
- **Exit:** repository is no longer tracked.

### Silencing notifications

- **Entry condition:** user toggles "Silence notifications" in the dropdown ([D13](artifacts/decision-log.md#d13-silence-notifications-toggle), [F15](artifacts/team-findings.md#f15-pause-language-hides-permanent-data-discard)).
- **Sequence:**
  1. The silence toggle becomes active. The dropdown's silence control shows a checkmark and the label changes to "Silenced — click to resume."
  2. Polling continues on schedule. The dropdown still reflects new outstanding items as they arrive.
  3. macOS notifications are suppressed for the duration of the silence. Cursors still advance — events that arrive while silenced will not fire notifications later, even after the user resumes ([D13](artifacts/decision-log.md#d13-silence-notifications-toggle)).
  4. When the user resumes (toggles silence off, or quits and relaunches — silence does not persist across launches), the dropdown shows a transient banner above the "New comments &amp; reviews" section: "Silenced for N minutes — M new items below" ([F7](artifacts/team-findings.md#f7-24h-recent-activity-window-vs-long-silence--silent-data-loss), [F15](artifacts/team-findings.md#f15-pause-language-hides-permanent-data-discard)). For silences longer than 24 hours, the "New comments &amp; reviews" section temporarily expands its window to cover the silenced duration, up to a ceiling of 7 days, so the user can see what they missed ([D13](artifacts/decision-log.md#d13-silence-notifications-toggle)).
- **Exit:** silence toggle off; subsequent ticks fire notifications normally.

### Error state (gh failure, network failure, rate limit, parse error)

- **Entry condition:** a poll fails because `gh` returns a non-zero exit attributable to an app-level cause (authentication failure, rate limiting, network unavailable, insufficient scope, parse error), OR `gh auth status` itself fails with a network-related error at startup ([F13](artifacts/team-findings.md#f13-gh-auth-status-failures-cannot-distinguish-not-signed-in-from-network-unavailable)).
- **Sequence:**
  1. The menubar icon switches to its error state — a distinct icon from the setup icon ([D21](artifacts/decision-log.md#d21-setup-and-error-icons-are-visually-distinct)). The dropdown's status banner is populated with a structured cause from the enum `NotSignedIn | RateLimited | NetworkUnavailable | InsufficientScope | ParseError | NotificationsDisabled | CorruptedState`, plus an action label and an action ([F22](artifacts/team-findings.md#f22-untestable-commitments-spec-sentences-not-testably-observable)). Example banners: "Not signed in to GitHub — Run `gh auth login`"; "GitHub rate limit exceeded — Retrying at 14:30"; "Network unavailable — Retry now"; "Could not read GitHub response — gh may have been updated — Retry / Report issue."
  2. No system notification fires about the failure itself.
  3. The app re-attempts on a backoff schedule that starts short and increases up to a ceiling, with jitter ([D14](artifacts/decision-log.md#d14-polling-cadence-single-global-tick-jittered-backoff)). For rate-limit errors specifically, the app respects the reset time reported by GitHub and waits until then before retrying. Parse errors use the same backoff — there is no separate wedged-pause mode ([F14](artifacts/team-findings.md#f14-gh-output-format-change-error-wedges-the-app-permanently)).
  4. The icon transitions back from the error state after two consecutive successful polls — not after a single success — to prevent visual flap during flaky network conditions ([F26](artifacts/team-findings.md#f26-icon-flap-on-alternating-successfailure)). Per-repo failures (404 on a single watched repo) do NOT enter app-level error state; they surface as per-repo rows (see Edge Cases) and only escalate the global icon if every watched repo is failing ([F12](artifacts/team-findings.md#f12-renamedtransferred-repo-error-treatment-is-per-app-instead-of-per-repo)).
  5. Events that occurred during the outage are caught up on the first successful tick. They go through the same cursor-based dedup, so the app fires at most one notification per event. After a long outage, this may be many notifications fired in quick succession; macOS may coalesce or drop individual ones, and the dropdown remains the authoritative current-state view ([F3](artifacts/team-findings.md#f3-macos-notification-center-may-silently-drop-events-during-burst-delivery)).
- **Exit:** two consecutive successful polls restore normal operation.

## Edge Cases and Failure Modes

| Condition | Required Behavior |
|---|---|
| `gh` not installed at all | App enters setup state with cause "Install `gh`" and a link to `cli.github.com`. Polling does not run. |
| `gh` installed but not reachable from the app's runtime environment (e.g., Homebrew on `/opt/homebrew/bin` with the app launched as a Login Item) | App enters setup state with cause "`gh` not found in this app's environment — see Troubleshooting if `gh` is already installed." Distinct copy from the not-installed case. ([F4](artifacts/team-findings.md#f4-gh-not-on-the-gui-apps-path-is-misdiagnosed-as-not-installed)) |
| `gh` installed but no active account | App enters setup state; checklist instructs the user to run `gh auth login`. Polling does not run. |
| `gh auth status` itself fails with a network error at app launch | App enters error state with cause `NetworkUnavailable`, not setup state. Retries on backoff and on network change. ([F13](artifacts/team-findings.md#f13-gh-auth-status-failures-cannot-distinguish-not-signed-in-from-network-unavailable)) |
| `gh` token loses required scope mid-use (e.g., `repo` revoked) | App enters error state with cause `InsufficientScope` and instructs the user to run `gh auth login` to re-grant required scopes. ([F28](artifacts/team-findings.md#f28-scope-revocation-recovery-instruction-is-too-specific)) |
| GitHub returns rate-limit error | Error state with cause `RateLimited` and reset time displayed. App waits until the reset before retrying; no notifications fire about the rate limit itself. |
| Network offline | Error state with cause `NetworkUnavailable`. App retries with backoff; no notifications fire about the outage. |
| Watched repo became private to the user or access revoked | The repository's rows in the dropdown are replaced by a single "No access" row with cause "Access revoked" and an inline `Remove` action. Polling for that single repo is skipped on subsequent ticks; the rest continue. The global menubar icon does not enter error state unless all watched repos fail. ([F12](artifacts/team-findings.md#f12-renamedtransferred-repo-error-treatment-is-per-app-instead-of-per-repo)) |
| Watched repo deleted on GitHub | Same per-repo handling as access revoked, with cause "Repository not found." |
| Watched repo renamed or transferred | Same per-repo handling with cause "Repository not found — it may have been renamed or transferred." A hint suggests removing and re-adding under the new name. (Rename auto-detection is out of scope.) ([F12](artifacts/team-findings.md#f12-renamedtransferred-repo-error-treatment-is-per-app-instead-of-per-repo)) |
| `gh` is upgraded and the output format changes underneath the app | App enters error state with cause `ParseError` ("Could not read GitHub response — gh may have been updated"). Banner offers `Retry` and `Report issue`. Backoff and retry continue as normal — the app does not wedge. ([F14](artifacts/team-findings.md#f14-gh-output-format-change-error-wedges-the-app-permanently)) |
| User launches the app while another instance is already running on the same Mac | The second instance detects the existing one, activates its dropdown, and exits. No duplicate notifications fire. ([F5](artifacts/team-findings.md#f5-two-instances-on-the-same-mac-produce-duplicate-notifications), [D20](artifacts/decision-log.md#d20-single-instance-enforcement-on-the-same-mac)) |
| App is force-quit mid-poll | On next launch, polling resumes from the last persisted cursors; any partial in-flight tick is discarded; no events are double-delivered. |
| Pull request closes / merges between two polls | Dropdown removes it on the next tick. No additional notification is fired about the close/merge itself in v1. |
| PR CI in mixed state (some checks failing, some still running) | PR appears in "CI failing" as soon as one check has a failure conclusion in the most recent suite; the section does not wait for all checks to settle. Notification fires once when the aggregate state transitions to failing, and again only when it transitions to passing. ([F9](artifacts/team-findings.md#f9-ci-fail-notification-trigger-is-undefined-for-mixed-state-check-suites)) |
| User clicks silence, then changes a repo's mode | Mode change applies normally on the next tick. Silence continues to suppress notifications; new events still advance cursors silently. |
| Notification permission denied at the OS level | Menubar icon enters error state with cause `NotificationsDisabled` and an action linking to System Settings → Notifications. Polling and dropdown continue to function. |
| Config or state file is corrupted or unreadable | App enters error state with cause `CorruptedState`, names the affected file, and offers `Open folder` and `Reset state (you may receive notifications for recent events)` actions. Reset preserves config and clears cursors — the user is explicitly informed of the catch-up notification consequence in the button label. ([F30](artifacts/team-findings.md#f30-notification-history-reset-state-warning-copy)) |

## User Interactions

The user surface lives in three places: the macOS menubar icon, a popover anchored to that icon, and macOS notifications. There is no full window in v1.

### Menubar icon

Four visual states, each represented as a discrete value the app exposes (so its current state is unambiguous to both users and tests):

| State | Icon appearance | Accessible label |
|---|---|---|
| `idle` | base icon, no overlay | "git-notified, no outstanding items" |
| `active` | base icon with a numeric count badge | "git-notified, N outstanding items" |
| `setup` | base icon with a configure overlay (neutral, additive — e.g., gear or plus glyph) | "git-notified, setup required" |
| `error` | base icon with a warning overlay (reactive, attention-grabbing — e.g., triangle or exclamation glyph) | "git-notified, error" |

The active-state badge uses a numeric count, not color alone, satisfying WCAG 1.4.1 ([D19](artifacts/decision-log.md#d19-accessibility-commitment)). Setup and error icons are visually distinct ([D21](artifacts/decision-log.md#d21-setup-and-error-icons-are-visually-distinct)).

### Dropdown popover

Anchored to the menubar icon; opens on left-click; closes on click-outside or Esc. Contents, in order:

1. **Status banner** (only when in setup or error state) — populated with a `cause` from the cause-enum and an action label. Absent in normal operation.
2. **Reviews requested** — pull requests where the user has been asked to review (directly or as a team member). Each row: `owner/name #num · title · requested by · age`. Empty state: "No pending review requests."
3. **CI failing** — pull requests in scope whose aggregate CI conclusion is `failing`. Each row: `owner/name #num · title · failing check · age`. Empty state: "No failing CI."
4. **New comments &amp; reviews** — comments and reviews on in-scope pull requests within the last 24 hours, measured against the GitHub-reported event timestamp ([F39](artifacts/team-findings.md#f39-clock-skew-clarification-recent-activity-window-uses-github-event-timestamps-not-local-clock)). Each row: `owner/name #num · author · "comment" / "review" · age`. Empty state: "No recent activity in the last 24 hours." Footer line: "Showing activity from the last 24 hours." This window temporarily expands to cover a silenced or offline interval up to 7 days when the user resumes ([F7](artifacts/team-findings.md#f7-24h-recent-activity-window-vs-long-silence--silent-data-loss)).
5. **Silence notifications** toggle — macOS-standard checked menu item. When silence is off, label reads "Silence notifications." When on, label reads "Silenced — click to resume" with a checkmark.
6. Visual separator.
7. **Add repository…** and **Manage repositories…**
8. Visual separator before destructive action ([F34](artifacts/team-findings.md#f34-visual-separator-between-utility-actions-and-quit-in-the-dropdown)).
9. **Quit**.
10. **Footer:** "Last checked Nm ago" or, if the most recent poll failed, "Last check failed — Retry."

### Manage repositories panel

Opens as a push view within the same popover, with a `Done` control returning to the main dropdown ([F20](artifacts/team-findings.md#f20-manage-repositories-panel-interaction-model-is-unspecified)). Lists each watched repository as `owner/name` with a mode picker (off / participating / all) and a `Remove` action. Mode changes update the picker value immediately (optimistic config update); downstream effects on the dropdown's section content follow on the next tick.

### Notification

macOS banner-style. Title = event description ("Review requested by @alice", "CI failed on build #3", "New comment by @bob", "Review submitted by @carol"). Subtitle = pull request reference and title (`acme/api#421 — Add OAuth login`) ([D18](artifacts/decision-log.md#d18-notification-format-title-event-subtitle-pr-ref)). Clicking opens the PR URL in the default browser ([D9](artifacts/decision-log.md#d9-click-action-opens-pr-in-default-browser)).

### Accessibility

The dropdown is fully keyboard-navigable: Tab/Shift-Tab moves focus through rows and controls; Return activates a row (opens its PR) or toggles a control. VoiceOver announces ([D19](artifacts/decision-log.md#d19-accessibility-commitment)):

- Each section heading as a heading.
- Each row as a button with its full visible text content as the accessible name.
- The silence toggle as a button with its current state ("Silence notifications, button, off" / "Silenced, button, on").
- The menubar icon with the state-inclusive label shown in the table above.

## Coordinations

| Coordinating System | Direction | Interaction | Ordering / Consistency Requirement |
|---|---|---|---|
| `gh` CLI | outbound | The app shells out to `gh` to read pull-request lists (including `involves:@me` filtering for `participating` mode), review-request lists, CI conclusions, comments, and reviews. For paginated responses, the app fetches all pages before comparing against cursors. The app never writes to GitHub. | At-least-once read semantics are sufficient. Cursors guarantee at-most-once notification firing per event. ([F6](artifacts/team-findings.md#f6-pagination-is-not-addressed--events-on-later-gh-response-pages-are-silently-missed)) |
| GitHub (via `gh`) | inbound (indirect) | All pull-request, CI, comment, and review data observed during a poll. | Event ordering relies on the GitHub-reported `updated_at` timestamp; the unique event ID is the tiebreaker. |
| macOS Notification Center | outbound | The app fires at most one notification per new event when not silenced. | OS delivery is best-effort. Under burst load (e.g., catch-up after a long outage), macOS may coalesce or drop individual notifications; the dropdown remains the authoritative current-state view. ([F3](artifacts/team-findings.md#f3-macos-notification-center-may-silently-drop-events-during-burst-delivery)) |
| macOS Launch services / default browser | outbound | The app opens PR URLs in the default browser on click. | Fire-and-forget. |
| Local saved state | inbound and outbound | The app loads on launch and after external edits; persists after any tick that advances a cursor or changes configuration. | Writes are persisted in a way that a crash mid-write does not leave saved state partially-updated. |
| `gh auth status` | outbound | Queried during first-run handshake and re-queried after auth-related errors. Network failures from this call are distinguished from auth failures. | Best-effort. |
| Other instances of this app on the same Mac | (boundary) | The app enforces single-instance operation. A second launch surfaces the existing instance's dropdown and exits. | At most one instance of the app runs on a given Mac at any time. ([D20](artifacts/decision-log.md#d20-single-instance-enforcement-on-the-same-mac)) |

### Data sources inside the app

Two independent data paths combine to produce the user experience ([D22](artifacts/decision-log.md#d22-dropdown-model-is-a-separate-data-path-from-cursor-driven-notifications)):

- **The notification path** is driven by cursor comparison: each poll determines which events are newer than each (repo, PR, event-type) cursor and fires a notification per new event. The cursors are the only authority for "have we already notified about this?"
- **The dropdown path** is a snapshot of GitHub-reported current state per tick, filtered by per-repo mode. The dropdown does not consult cursors — it reflects what GitHub currently says is outstanding (open PRs with pending review requests; PRs whose aggregate CI is `failing`; comments/reviews within the configured window).

This separation means: silencing or being offline does not lose state visibility (the dropdown catches up automatically); a dropped macOS notification does not vanish from the user's awareness (the dropdown still shows the item); and the cursor model is concerned only with "fire vs. don't fire," not with "is this item still outstanding?"

## Out of Scope

- **Writing to GitHub.** The app never approves a review, submits a comment, merges a PR, dismisses a review request, marks a notification as read on GitHub, or otherwise mutates GitHub state.
- **Multi-account support.** The app uses whichever account is currently active in `gh auth status`. Switching accounts in `gh` is honored on the next launch but the app does not surface a within-app account picker.
- **GitHub Enterprise multi-host support.** Whatever hostname `gh` is configured for is what the app uses.
- **An in-app PR view.** Clicks open the browser. The app never renders PR bodies, diffs, or comment threads itself.
- **Cross-machine state sync.** Two installs of the app on two Macs are emergent — each operates independently with no coordination; no implementation effort is required to make this work, and no implementation effort is spent making them synchronize ([F31](artifacts/team-findings.md#f31-two-macs-edge-case-is-emergent-not-handled)).
- **Notification history / archive.** Once a notification is dismissed by the user or the OS, it is not recoverable from inside the app.
- **Real-time / push-based delivery.** Delivery latency is bounded by the poll interval (~1 minute).
- **Custom notification rules.** No per-author, per-label, per-time-of-day, or per-CI-check filtering beyond the per-repo mode.
- **Snoozing individual items.** Silence is global. Per-PR snooze is not in v1.
- **Auto-detecting repo renames or transfers.** Renamed/transferred repos surface as per-repo "Repository not found" errors; the user removes and re-adds.

## Deferred (YAGNI)

### Per-event-type mute toggles (CI off, comments off, etc.)
- **Why deferred:** simpler-version replacement — the per-repo mode dropdown already gives users coarse on/off control and matches GitHub's own model.
- **Reopen when:** users report specific repos being too noisy on one event type (typically CI) without wanting to silence everything on that repo.
- **Source:** Round 1.

### In-app PR preview / detail view
- **Why deferred:** simpler-version replacement — opening in the browser satisfies the click-through evidence with the minimum surface area.
- **Reopen when:** users complain that browser context-switching is too heavy.
- **Source:** Round 2.

### Scheduled quiet hours
- **Why deferred:** evidence-test failure — macOS Focus modes already provide system-wide quiet hours; the silence toggle covers the ad-hoc case.
- **Reopen when:** users explicitly ask for app-level scheduling, or a Focus-mode integration becomes desirable.
- **Source:** Round 2.

### Digest mode / time-window coalescing
- **Why deferred:** simpler-version replacement — per-event notifications with cursor-based dedup match user expectation for "review requested" urgency.
- **Reopen when:** users report chatty CI loops — particularly from force-push-triggered CI restarts on active PRs — producing too many notifications even with current dedup. ([F27](artifacts/team-findings.md#f27-ci-restart-spam-green--fail--green-from-ref-update--already-deferred-reopen-when-text-vague))
- **Source:** Round 2.

### Notification history view
- **Why deferred:** evidence-test failure — no requirement has been raised for revisiting dismissed notifications.
- **Reopen when:** users ask to see what they missed, or a "what changed today" view would be valuable.
- **Source:** storage-format decision.

### Multi-account / multi-host (`gh auth` with multiple hosts or accounts)
- **Why deferred:** evidence-test failure — the stated v1 user is a single developer on a single account.
- **Reopen when:** the user (or a teammate) operationally needs both `github.com` and a GHE instance, or both a personal and work account, simultaneously visible.
- **Source:** user brief.

### Webhook / push-based delivery
- **Why deferred:** evidence-test failure — 60s polling latency is acceptable and webhooks require either a hosted endpoint or a local tunnel.
- **Reopen when:** sub-minute latency becomes a felt need.
- **Source:** Round 1.

### Cross-machine state sync
- **Why deferred:** evidence-test failure — single-machine use is the assumed v1 audience.
- **Reopen when:** a user reports double notifications across machines as a recurring frustration.
- **Source:** boundary analysis.

### A dedicated Settings panel
- **Why deferred:** evidence-test failure — every configurable surface in v1 is already covered by the per-repo mode picker (in Manage repositories) or the silence toggle. There is no setting that needs its own panel ([F18](artifacts/team-findings.md#f18-settings-is-a-yagni-affordance-with-no-defined-content)).
- **Reopen when:** a setting exists that cannot be expressed in per-repo mode or the silence toggle.
- **Source:** UX review.

### Configurable Recent Activity window
- **Why deferred:** evidence-test failure — 24h (with the silence/offline expansion to 7d) covers known cases. Configurability has no current driver.
- **Reopen when:** users report 24h is consistently the wrong window for their workflow ([F29](artifacts/team-findings.md#f29-oi-1-24h-lookback--close-it)).
- **Source:** prior OI-1.

### Persistent silence across launches
- **Why deferred:** simpler-version replacement — non-persistent silence prevents the user from being permanently muted unexpectedly.
- **Reopen when:** users report losing silence state across a crash or Login Item restart as a frustration.
- **Source:** boundary analysis.

### Detailed scope-revocation diagnostics
- **Why deferred:** simpler-version replacement — generic "re-run `gh auth login`" recovery instruction handles all scope cases without per-scope detection logic ([F28](artifacts/team-findings.md#f28-scope-revocation-recovery-instruction-is-too-specific)).
- **Reopen when:** users report confusion about which scope was lost.
- **Source:** edge case review.

### Optimistic dropdown content updates on mode change
- **Why deferred:** simpler-version replacement — config-level optimistic update on the mode picker is sufficient feedback; recomputing dropdown content on mode-change before the next tick adds complexity.
- **Reopen when:** users report the wait between mode change and dropdown update is confusing.
- **Source:** UX review.

## Open Items

- **OI-3:** Concrete poll-budget number — at what number of watched repositories does a single 60s tick start to risk secondary rate limits?
  - **Resolves when:** an early test against a real account is run.
  - **Blocks implementation:** No, but should be measured before any public release.

## Summary

- **Outcome delivered:** A Mac developer gets timely, deduplicated, native macOS notifications for the GitHub pull-request activity they care about across opted-in repositories, with the dropdown as the authoritative current-state view, driven through their existing `gh` session.
- **Primary actors:** end user (single developer on macOS), GitHub (via `gh` CLI), macOS Notification Center.
- **Decisions settled by evidence:** 8 — see [artifacts/decision-log.md](artifacts/decision-log.md) (D2, D16 trivial; F-driven decisions and clarifications resolved against codebase conventions, macOS HIG, WCAG, and GitHub API documentation).
- **Decisions settled by user input:** 15 — see [artifacts/decision-log.md](artifacts/decision-log.md).
- **Sub-agents consulted:** junior-developer, user-experience-designer, edge-case-explorer, test-engineer — see [artifacts/team-findings.md](artifacts/team-findings.md).
- **Key adjustments from review:** Cursor model clarified to per-(repo, PR, event-type) with explicit timestamp ordering; notification format restructured to title-first event description; pause renamed to silence with post-resume status banner and a 7-day window expansion to surface missed activity; pagination, GUI-app PATH, two-instance enforcement, and macOS rate-limit caveat added; behavioral accessibility commitment added; per-repo errors separated from app-level errors; "Settings…" removed as YAGNI. See [artifacts/team-findings.md](artifacts/team-findings.md).
- **Remaining open items:** 1.
