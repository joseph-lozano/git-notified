---
title: "git-notified — Build Phase Outline"
source_artifact: "feature-specification.md"
audience: "mixed engineering, product, and leadership"
generated: "2026-05-15"
generated_by: "han:plan-a-phased-build"
---

# git-notified — Build Phase Outline

This document describes the order in which **git-notified** will be built. The work is broken into a sequence of **phases**, where each phase is a thin end-to-end deliverable that can be demonstrated to a real person, and each phase builds on the one before it. git-notified is a macOS menubar app that watches a developer's chosen GitHub repositories through their existing `gh` session and surfaces review requests, CI outcomes, comments, and reviews as native notifications and as a categorized summary dropdown.

This document is the companion to [feature-specification.md](feature-specification.md). The source artifact describes *what the shipped app does, end-to-end*. This document describes *the order in which the work will be built to get there*. Every phase below cites the source-artifact sections it covers, so anyone can trace a phase back to source.

## Table of Contents

- [Executive Summary](#executive-summary)
- [Build Phase Index](#build-phase-index)
- [Build Phases](#build-phases)
  - [Phase 1: First end-to-end notification — review requests](#phase-1)
  - [Phase 2: CI failing notifications and section](#phase-2)
  - [Phase 3: New comments and reviews](#phase-3)
  - [Phase 4: Per-repo modes and the Manage repositories panel](#phase-4)
  - [Phase 5: Silence notifications](#phase-5)
  - [Phase 6: Error surfaces and recovery](#phase-6)
  - [Phase 7: First-run, Login Item safety, and crash resilience](#phase-7)
  - [Phase 8: Accessibility commitment](#phase-8)
  - [Phase 9 (Deferred): Carried-forward YAGNI items](#phase-9)
- [Open Questions](#open-questions)
- [Phase Kinds (reference)](#phase-kinds)

---

## Executive Summary {#executive-summary}

**The goal:** A developer on a Mac, signed in to GitHub through `gh`, can opt in a handful of repositories and start receiving timely, deduplicated, native macOS notifications for the four pull-request events that matter — someone requested their review, CI started failing on one of their PRs, a new comment landed, or a new review was submitted. The same activity is available at a glance through a menubar dropdown that stays correct even when notifications are missed.

**The shape of the build (five themes):**

- **Phase 1 is the vertical-slice MVP.** It ships every layer of the system end-to-end for one narrow scenario — review requests on opted-in repositories — including the menubar shell, setup checklist, repository picker, polling, deduplicated notifications, the dropdown, and persistent state.
- **Phases 2 and 3 grow event-type coverage.** Each adds one more event type on top of the working pipeline from Phase 1 — first CI outcomes, then comments and reviews — so the product becomes progressively more useful with each release.
- **Phases 4 and 5 add the user-facing controls** that the spec promises: per-repo on/participating/all modes with a Manage repositories panel, then a silence toggle for ad-hoc quiet time.
- **Phases 6 and 7 are the resilience push.** Phase 6 builds the user-facing error surfaces — the error icon, the structured cause banner, per-repo failure rows, retry and hysteresis. Phase 7 fixes the first-run latency, makes the app safe to run as a Login Item, and guarantees that a crash never corrupts saved state.
- **Phase 8 is the accessibility commitment** — VoiceOver labels, keyboard navigation, accessible icon state — landing once the surfaces it covers are stable.

**Sequencing rationale, in plain language:**

The order is driven by two rules. First, every phase delivers a slice a real user can be shown — even Phase 1, which absorbs the minimum amount of setup-checklist and picker work needed to make a single notification fire end-to-end. Second, capabilities that enrich an already-working core (event-type breadth, mode controls, silence, error UX, hardening, accessibility) land after the core works, so that no phase invalidates an earlier deliverable. The four event types are intentionally split across three phases — review requests first because they are the most urgent, then CI, then comments and reviews — so that each release has a tightly scoped demo and the team learns what's right about the model before adding the next event type.

**Phases deliberately deferred:**

Thirteen capabilities from the source artifact are not built in this plan — covering per-event mute controls, in-app PR views, scheduling, cross-machine sync, dedicated settings, and several smaller refinements. Each is listed in [Phase 9 (Deferred)](#phase-9) with its reopening trigger. One carry-over question from the source — the safe number of watched repos before the polling tick risks secondary rate limits — is recorded under [Open Questions](#open-questions).

**Where to look next:** The [Build Phase Index](#build-phase-index) lists every phase in order. Detailed write-ups follow under [Build Phases](#build-phases). Decisions the team must resolve before Phase 1 can start are at [Open Questions](#open-questions).

---

## Build Phase Index {#build-phase-index}

> The scan view. One row per phase, in build order. Each "Outcome" cell is one short sentence. Detailed write-ups follow under [Build Phases](#build-phases); use the link in the Phase column.

| # | Phase | Kind | Outcome (one sentence) |
|---|---|---|---|
| 1 | [First end-to-end notification — review requests](#phase-1) | Feature slice | A user adds a repo and receives a native notification the next time someone requests their review. |
| 2 | [CI failing notifications and section](#phase-2) | Feature slice | The user gets notified when CI starts failing on their PRs and sees the failing list at a glance. |
| 3 | [New comments and reviews](#phase-3) | Feature slice | Comments and reviews on watched PRs notify the user and appear in a 24-hour activity list. |
| 4 | [Per-repo modes and the Manage repositories panel](#phase-4) | Feature slice | The user switches a repo between off, participating, and all, and the watch list updates accordingly. |
| 5 | [Silence notifications](#phase-5) | Feature slice | The user silences notifications, then on resume sees a summary of what arrived while silent. |
| 6 | [Error surfaces and recovery](#phase-6) | Feature slice | The app shows a clear cause banner and self-recovers when GitHub, the network, or `gh` misbehaves. |
| 7 | [First-run, Login Item safety, and crash resilience](#phase-7) | Feature slice | The first poll fires immediately on setup, the app runs safely as a Login Item, and a crash mid-write does not lose state. |
| 8 | [Accessibility commitment](#phase-8) | Polish | A VoiceOver user can navigate the dropdown by keyboard and hear every state announced correctly. |
| 9 | [Carried-forward YAGNI items (deferred)](#phase-9) | Deferred | Listed for traceability; built only when the named reopening trigger fires. |

> Numbers are assigned in build order and are stable for the life of this outline. Cite them as `Phase N` in tickets, comments, and follow-up reports.

---

## Build Phases {#build-phases}

### Phase 1: First end-to-end notification — review requests {#phase-1}

**Kind.** Feature slice.

**Builds on.** Nothing — this is the starting phase.

**What we build.** The thinnest end-to-end vertical slice of the app, scoped to the single most urgent event type. Concretely:

- The menubar icon appears on the menubar with two visual states: a base icon when nothing is outstanding, and the same icon with a numeric count badge when there is.
- Clicking the icon opens a dropdown popover with one content section — **Reviews requested** — plus a **Quit** control and a footer showing when the last check ran.
- On first launch, the dropdown shows a setup checklist: install `gh`, sign in with `gh auth login`, add a repository. The app does not poll until every checklist row is complete.
- An **Add repository** affordance opens a search-and-paste picker. The user picks a repo and confirms; the repo is added to the watched list. The first watched repo is added with the default mode that asks GitHub "PRs that involve me."
- A recurring tick — roughly every minute, jittered — asks GitHub through `gh` which pull requests in the watched repo currently have a pending review request for the user. The app fetches every page of any paginated response before comparing.
- The app remembers which review requests it has already told the user about, per pull request, so the same review request never produces two notifications even across restarts. When a request is genuinely new, the app fires one native macOS notification with the event description as the title (`Review requested by @alice`) and the repo and PR title as the subtitle.
- Clicking the notification or any row in the dropdown opens the corresponding PR in the user's default browser.
- The watched repository list and the per-PR "already notified" memory persist on disk between launches.

**Why this is Phase 1.** This is the smallest end-to-end strip that produces user-recognizable value. Every layer of the system — gh integration, polling, deduplication, persistence, the menubar, the dropdown, notifications, browser hand-off, the setup checklist — is exercised for exactly one narrow scenario. The setup checklist and picker are folded in because no notification can fire without them; they are not split into separate phases because they are not independently demoable in a useful way. Review requests come first among the four event types because they are the most urgent in the user's workflow and the cleanest to detect (a pending review request is simply present or absent; CI requires tracking a sequence of check outcomes).

**Outcome to demonstrate.**

1. Install and launch the app for the first time. The menubar icon appears; the dropdown shows the setup checklist with "Install `gh`" as the first pending step.
2. With `gh` already installed and signed in, the first two checklist rows complete on their own. The third row, "Add a repository", remains pending.
3. Click "Add a repository", type a few characters of a repo name, pick a result, confirm. The repo appears in the watch list and the checklist is fully complete.
4. Have a teammate request the demo user's review on a pull request in that repo.
5. Within about a minute, a macOS notification appears reading "Review requested by @teammate — owner/repo#123 — PR title."
6. The menubar icon picks up a count badge of 1. Open the dropdown; "Reviews requested" lists the PR with the requester's handle and the time elapsed.
7. Click the row. The PR opens in the default browser.
8. Quit the app and relaunch it. The menubar icon still shows the count badge, the dropdown still shows the same row, and no new notification fires for the already-seen review request.

**Source citations.**
- [Outcome](feature-specification.md#outcome) — the overall user-visible commitment this phase begins to deliver.
- [Primary Flow](feature-specification.md#primary-flow) — every numbered step of the happy path runs end-to-end in this phase, scoped to the review-request event type.
- [Preconditions](feature-specification.md#actors-and-triggers) — the gh-installed and signed-in checks the setup checklist confirms.
- [First-run / setup](feature-specification.md#first-run--setup) — the checklist UX, scoped to the happy path (PATH-edge-case copy lands in [Phase 7](#phase-7)).
- [Adding a repository](feature-specification.md#adding-a-repository) — the picker UX and the no-backfill rule for newly added repos.
- [Menubar icon](feature-specification.md#menubar-icon) — idle and active states only this phase.
- [Dropdown popover](feature-specification.md#dropdown-popover) — the Reviews requested section, the Add repository control, Quit, and the last-checked footer.
- [Notification](feature-specification.md#notification) — the title-first format and click-through behavior.
- [Data sources inside the app](feature-specification.md#data-sources-inside-the-app) — both data paths exist from day one, even though only one event type populates them.

**Connects to.**
- Sets up the polling, dedup, dropdown, and notification machinery that [Phase 2](#phase-2) and [Phase 3](#phase-3) extend to additional event types.
- Establishes the setup checklist that [Phase 7](#phase-7) hardens for the GUI-app path edge case.
- Establishes the menubar icon's base/active states that [Phase 6](#phase-6) extends with an error state and [Phase 8](#phase-8) annotates with VoiceOver labels.

**Preconditions to verify before starting.**
- Confirm that `gh` exposes the data this phase needs — the pending-review-request list per repo, with a stable per-event identifier and an updated-at timestamp — at a granularity that lets the app determine whether a given request has been notified about before. See [OQ-1](#oq-1).
- Decide what happens on the first poll after adding a repo: does the app fire a notification for currently-outstanding review requests, or only for ones that arrive after the add? The source already answers this (no backfill on add), but the phase team should confirm the user-visible expectation before building.
- Decide what level of crash safety the on-disk state needs in this phase. The source commits to crash-safe writes; the team may elect to defer that strict guarantee to [Phase 7](#phase-7) and accept a minor demo risk in the interim. See [OQ-2](#oq-2).

---

### Phase 2: CI failing notifications and section {#phase-2}

**Kind.** Feature slice.

**Builds on.** [Phase 1](#phase-1) — the polling tick, the dedup memory, the dropdown, and the notification format are already in place; this phase adds a second event type on top.

**What we build.**

- A second content section in the dropdown — **CI failing** — listing every watched pull request whose CI is currently in a failing state. Each row shows the repo, PR number, title, the failing check name, and the age of the failure.
- Per-PR detection of CI state. A pull request's CI is treated as **failing** when at least one check on the most recent commit has a failure conclusion and the commit hasn't been superseded. It's **passing** when every check on that commit passes. It's **in progress** otherwise.
- A notification fires once when a PR transitions to **failing** and again when it transitions back to **passing** — not once per failing check, and not while checks are still settling. The "already notified about this transition" memory works the same way as for review requests: per pull request, per event type.
- The "Reviews requested" section from Phase 1 continues to work unchanged. The count badge now reflects the sum across both sections.
- Empty state for the new section reads "No failing CI."

**Why this is Phase 2.** Review requests and CI failures are the two most actionable event types in a developer's day, and CI is the one with non-trivial detection logic — aggregating across multiple checks, recognizing supersession by newer commits, and firing only on aggregate-state transitions. Landing it second means the team has the rest of the pipeline stable from Phase 1 and can focus the entire phase on getting the state-machine right. The same dedup model from Phase 1 generalizes naturally to a second event type, so the work compounds rather than duplicating.

**Outcome to demonstrate.**

1. With the app running and one repo watched from Phase 1, push a commit to a PR in that repo that breaks CI.
2. Within about a minute of the failing check reporting, a macOS notification appears: "CI failed on `check-name` — owner/repo#123 — PR title."
3. The menubar count badge increments. Open the dropdown; "CI failing" lists the PR with the failing check name and the age of the failure.
4. Click the row. The PR opens in the default browser.
5. Push a fix commit. When checks complete and all pass, a second notification appears: "CI passing — owner/repo#123 — PR title." The PR drops off the "CI failing" section.
6. Cause a PR to have a mix of one failing check and several still-running checks. Confirm the PR shows up in "CI failing" immediately — the app does not wait for all checks to settle.
7. Quit and relaunch. Existing failing PRs still appear in the section, and no duplicate notifications fire.

**Source citations.**
- [Primary Flow, step 3](feature-specification.md#primary-flow) — the per-tick CI conclusion query for in-scope PRs.
- [Primary Flow, step 5](feature-specification.md#primary-flow) — the failing / passing / in-progress aggregation rule and the transition-based notification trigger.
- [Dropdown popover](feature-specification.md#dropdown-popover) — the CI failing section, its row format, and empty state.
- [Notification](feature-specification.md#notification) — the title-first format applied to CI events.
- [Edge Cases and Failure Modes](feature-specification.md#edge-cases-and-failure-modes) — the mixed-state check-suite row (one failing while others still run).

**Connects to.**
- Builds directly on the dedup, dropdown, and notification machinery established in [Phase 1](#phase-1).
- The CI-restart-spam pattern (force-push triggering green → fail → green) remains a known deferral; see [Phase 9](#phase-9).

**Preconditions to verify before starting.**
- Confirm that `gh` reports per-check conclusions and the parent commit identifier for each check, so the app can recognize when a newer commit supersedes an earlier failing suite. See [OQ-3](#oq-3).
- Decide whether the count badge in the menubar reflects only outstanding review requests or sums review requests plus failing CI. The source's wording supports the latter; confirm before build.

---

### Phase 3: New comments and reviews {#phase-3}

**Kind.** Feature slice.

**Builds on.** [Phase 2](#phase-2) — the dropdown now has two working sections; this phase adds the third and final section.

**What we build.**

- A third content section in the dropdown — **New comments & reviews** — listing comments and reviews on watched PRs from the last 24 hours. Each row shows the repo, PR number, the author of the comment or review, a short tag (`comment` or `review`), and the age. A footer line on the section reads "Showing activity from the last 24 hours."
- The window is measured against the timestamp GitHub puts on each event, not the user's local clock, so a Mac with a skewed clock still shows a consistent window.
- A notification fires for each new comment ("New comment by @bob — owner/repo#123 — PR title") and each new review ("Review submitted by @carol — owner/repo#123 — PR title"). Notifications continue to be deduplicated per pull request, per event type, the same way Phase 1 and Phase 2 events are.
- Empty state reads "No recent activity in the last 24 hours."
- The count badge now sums all three sections.

**Why this is Phase 3.** Comments and reviews are the highest-volume of the four event types and the most likely to feel noisy. Landing them last among the event types means the team has confidence in the dedup pipeline, can observe real notification volume from the first two phases, and can apply that learning to the comments-and-reviews UX (especially the 24-hour windowing). The 24-hour activity window is also the first piece of UI that introduces a timestamp-based filter, which makes it a natural setup for the silence and offline behavior in [Phase 5](#phase-5).

**Outcome to demonstrate.**

1. With the app running and one or more repos watched, have a teammate leave a comment on a PR in scope.
2. Within about a minute, a notification appears: "New comment by @teammate — owner/repo#123 — PR title."
3. Open the dropdown. "New comments & reviews" shows the row at the top with the teammate's handle, the `comment` tag, and the age.
4. Have a teammate submit a review on a different PR. A new notification fires labeled "Review submitted by @teammate"; a new row appears in the same section with the `review` tag.
5. Confirm the section's footer reads "Showing activity from the last 24 hours."
6. Wait or simulate time passing past the 24-hour boundary. The oldest comment ages out of the section.
7. The count badge in the menubar reflects the combined count of outstanding review requests, failing CI, and recent comments-and-reviews.

**Source citations.**
- [Primary Flow, step 3](feature-specification.md#primary-flow) — the per-tick comment and review fetch for in-scope PRs.
- [Primary Flow, step 5](feature-specification.md#primary-flow) — the dedup-by-cursor rule applied to comments and reviews.
- [Dropdown popover](feature-specification.md#dropdown-popover) — the New comments & reviews section, its row format, empty state, and footer.
- [Notification](feature-specification.md#notification) — the title-first format applied to comment and review events.
- [F39 clock-skew clarification](artifacts/team-findings.md#f39-clock-skew-clarification-recent-activity-window-uses-github-event-timestamps-not-local-clock) — the rule that the 24-hour window is measured against the event timestamp, not the local clock.

**Connects to.**
- Closes the event-type coverage. After this phase, all four notification triggers from the source spec ([Outcome](feature-specification.md#outcome)) are live.
- Establishes the 24-hour window that [Phase 5](#phase-5) extends to cover silenced or offline intervals, up to a 7-day ceiling.

**Preconditions to verify before starting.**
- Confirm that the comment and review feeds available through `gh` carry a stable per-event identifier and timestamp suitable for the same dedup approach used by Phase 1 and Phase 2.
- Decide whether comments on closed or merged PRs continue to surface in the 24-hour window or are filtered out. The source is silent on this; the recommended default is to include them while the PR is still being scanned by the active mode, and drop them when the PR closes or merges.

---

### Phase 4: Per-repo modes and the Manage repositories panel {#phase-4}

**Kind.** Feature slice.

**Builds on.** [Phase 3](#phase-3) — all four event types are notifying and populating the dropdown; this phase gives the user controls to scope what each watched repo contributes.

**What we build.**

- A **Manage repositories** push view inside the dropdown popover, opened from a "Manage repositories…" control on the main view and dismissed by a "Done" control. The view lists every watched repository with its current mode and a remove control.
- Each watched repo now has a **mode** picker with three values: **off**, **participating**, and **all**.
  - **Off** silences the repo entirely. The app makes no GitHub calls for it. Its rows drop out of every dropdown section on the next tick. The repo stays in the watched list so the user can re-enable it without re-adding.
  - **Participating** scans only PRs GitHub considers the user involved in — author, assignee, requested reviewer (direct or via team), @mention recipient, or previous commenter or reviewer.
  - **All** scans every open pull request in the repo.
- The mode picker updates instantly when the user makes a selection — the user does not wait for the next tick to see the new mode value on the picker. The dropdown content (which PRs appear under which sections) updates on the next tick.
- A **remove** control on each repo row removes the repo from the watched list entirely.
- **No-backfill rules** apply consistently:
  - Adding a repo (already supported from Phase 1) does not produce notifications for activity that already existed.
  - Widening a repo's mode (off → participating, off → all, or participating → all) does not produce a notification flood for PRs that newly become in scope.
  - Narrowing a repo's mode (all → participating, participating → off, etc.) drops the no-longer-in-scope PRs from the dropdown on the next tick.
  - Re-widening after a narrow is treated like a fresh add: the newly-in-scope PRs start from current high-water marks, so events that happened during the narrow period do not flood notifications later.
- The **Add repository** picker (already shipped in Phase 1) now sets the new repo's mode to the same default the picker has always implied, and writes the chosen mode into the repo's record.

**Why this is Phase 4.** Once the app reliably notifies for the four event types, the next-most-pressing user need is the controls to dial repos up and down. The mode model also introduces the no-backfill-on-widen rule, which is the most subtle behavior in the source artifact — landing it after the event-type slices means the team has working dedup memory to lean on and can verify the no-backfill rule by direct observation rather than reasoning. Removing this phase from Phase 1 also kept Phase 1 narrow enough to ship.

**Outcome to demonstrate.**

1. Open the dropdown, click **Manage repositories…**. The push view appears with one repo from Phase 1, currently in **participating** mode.
2. Switch the repo's mode to **all**. The picker value flips immediately to **all**. The dropdown's content updates on the next tick: PRs from the repo that the user is *not* involved in start appearing in the dropdown sections — but no notifications fire for them.
3. Switch the repo's mode to **off**. On the next tick, the dropdown sections empty out for that repo and the count badge falls to zero. No `gh` calls happen for the repo during ticks.
4. Switch the repo back to **all**. The dropdown re-populates on the next tick, but the activity that occurred while the repo was off does **not** generate a notification flood. Only events from after the re-enable fire notifications.
5. Click **Remove** on the repo. The repo disappears from the watch list. The dropdown sections empty. If the user adds the same repo again later, the app treats it as a brand-new addition with no backfill.
6. Click **Done**. The push view dismisses and the main dropdown view reappears.

**Source citations.**
- [Primary Flow, step 4](feature-specification.md#primary-flow) — the off / participating / all behavior and the use of GitHub's involvement filter for participating mode.
- [Adding a repository](feature-specification.md#adding-a-repository) — the picker's mode field at add time.
- [Changing a repository's mode](feature-specification.md#changing-a-repositorys-mode) — the widen, narrow, and re-widen rules.
- [Removing a repository](feature-specification.md#removing-a-repository) — the remove flow and the "treat re-add as fresh" rule.
- [Manage repositories panel](feature-specification.md#manage-repositories-panel) — the push-view presentation model.
- [F8 mode narrow → re-widen](artifacts/team-findings.md#f8-mode-narrow--re-widen-behavior-contradicts-the-specs-stated-intent) — the rule that re-widen is treated as a fresh add.

**Connects to.**
- Completes the controls described in the source's user-facing surface. After this phase, every promised configuration affordance for the four notification triggers is live.
- Establishes the watched-list machinery that [Phase 6](#phase-6) extends with per-repo error rows (a watched repo showing "No access" inline rather than tipping the whole app into error state).
- The optimistic dropdown-content updates on mode change remain deferred; see [Phase 9](#phase-9).

**Preconditions to verify before starting.**
- Confirm what "the user is involved in" maps to in GitHub's filter language as expressed through `gh`, and that the filter is supported for the way the app intends to query it.
- Decide whether removing a repo also discards its dedup memory or retains it for a re-add. The source's wording — "treats it as a fresh add: no events that occurred during the removal interval generate notifications" — implies discard; confirm before build.

---

### Phase 5: Silence notifications {#phase-5}

**Kind.** Feature slice.

**Builds on.** [Phase 4](#phase-4) — the dropdown's full set of sections, controls, and Manage repositories panel is in place; this phase adds an ad-hoc quiet-time control.

**What we build.**

- A **Silence notifications** toggle in the main dropdown, presented as a macOS-standard menu item. When the toggle is off, the label reads "Silence notifications." When the toggle is on, the label reads "Silenced — click to resume" with a checkmark.
- While silenced:
  - Polling continues on its normal schedule. The dropdown still reflects new outstanding items as they arrive.
  - macOS notifications do not fire. The app still records that the user has been "told about" each event, so events that arrived during silence will not fire late notifications after resume.
- On resume (toggle off, or quit-and-relaunch — silence does **not** persist across launches):
  - A transient banner appears above the "New comments & reviews" section: "Silenced for N minutes — M new items below." The banner gives the user a single, scannable acknowledgment of what they missed.
  - For silences longer than 24 hours, the "New comments & reviews" section temporarily expands its window to cover the silenced interval, up to a ceiling of 7 days. This makes "what happened while I was muted" legibly visible without an unbounded backlog.
- If the user changes a repo's mode while silenced, the mode change applies on the next tick exactly as in [Phase 4](#phase-4); silence only suppresses the notification surface, not the configuration surface.

**Why this is Phase 5.** Silence is the only user-facing control left after Phase 4 that the source spec promises in v1. It depends on the dropdown's "New comments & reviews" section (where the post-resume banner anchors) being live, so it lands after Phase 3. It also depends on the dedup memory being trustworthy, so events that "happen during silence" are correctly remembered as already-handled — that machinery is mature by Phase 4. The 7-day window expansion is the most novel behavior in this phase, and isolating it makes it easy to verify.

**Outcome to demonstrate.**

1. With the app running and at least one watched repo, click the **Silence notifications** toggle. The toggle picks up a checkmark and the label switches to "Silenced — click to resume."
2. Have a teammate request a review and leave a comment on a PR in scope.
3. Observe: no macOS notifications fire. The dropdown's "Reviews requested" and "New comments & reviews" sections still reflect the new activity. The count badge still increments.
4. Click the toggle again to resume. The checkmark clears; the label switches back to "Silence notifications."
5. A transient banner appears at the top of "New comments & reviews" reading "Silenced for N minutes — M new items below." The banner dismisses on the next user interaction.
6. With the toggle back to silent, leave the app silent for over 24 hours (or simulate). Have several comments and reviews arrive during the silenced interval. On resume, observe that the section's window has expanded to cover the silenced interval (up to 7 days) and the banner reflects the total.
7. Silence, then quit and relaunch the app. On relaunch, the toggle is back to its default off state — silence does not persist.

**Source citations.**
- [Silencing notifications](feature-specification.md#silencing-notifications) — the entire flow including the post-resume banner and 7-day expansion.
- [Triggers](feature-specification.md#actors-and-triggers) — the silence toggle as one of the app's recognized triggers.
- [Dropdown popover](feature-specification.md#dropdown-popover) — the placement and label rules for the silence toggle.
- [F7 24h window vs. long silence](artifacts/team-findings.md#f7-24h-recent-activity-window-vs-long-silence--silent-data-loss) — the rule that the activity window expands to cover the silenced interval up to 7 days.
- [F15 Pause language hides discard](artifacts/team-findings.md#f15-pause-language-hides-permanent-data-discard) — the post-resume banner that makes the discard semantics legible.

**Connects to.**
- Builds on the dropdown sections established in [Phase 1](#phase-1), [Phase 2](#phase-2), and [Phase 3](#phase-3).
- Persistent silence across launches remains deferred; see [Phase 9](#phase-9).

**Preconditions to verify before starting.**
- Decide the exact phrasing of the post-resume banner — "Silenced for N minutes — M new items below" — and whether the banner dismisses on click-outside, on the next click anywhere in the popover, or on a fixed timer. See [OQ-5](#oq-5).
- The 7-day window-expansion ceiling is inherited from the source spec ([Silencing notifications](feature-specification.md#silencing-notifications)) and does not require a team decision before Phase 5 starts.

---

### Phase 6: Error surfaces and recovery {#phase-6}

**Kind.** Feature slice.

**Builds on.** [Phase 5](#phase-5) — the full happy-path experience is in place; this phase makes the app behave gracefully when things break.

**What we build.**

- A new **error state** for the menubar icon, visually distinct from both the idle/active states (Phase 1) and the setup state (Phase 1's checklist). The error icon uses a reactive, warning-style overlay; the setup icon uses a neutral, additive overlay. The two are immediately distinguishable at a glance.
- A **status banner** at the top of the dropdown, present only when the app is in setup or error state, absent in normal operation. The banner carries a **structured cause** drawn from a small named set — *not signed in*, *rate limited*, *network unavailable*, *insufficient scope*, *could not read GitHub response*, *notifications disabled*, *corrupted state* — plus an action label and an action affordance. Examples:
  - "Not signed in to GitHub — Run `gh auth login`"
  - "GitHub rate limit exceeded — Retrying at 14:30"
  - "Network unavailable — Retry now"
  - "Could not read GitHub response — `gh` may have been updated — Retry / Report issue"
  - "Notifications disabled — Open System Settings"
  - "Corrupted state — Open folder / Reset state (you may receive notifications for recent events)"
- A **retry-with-backoff** policy on every poll that fails: short delay first, then progressively longer, with random jitter to avoid synchronized bursts. The ceiling is bounded. **Rate-limit** errors specifically respect the reset time GitHub reports — the app waits until then before retrying. **Parse errors** use the same backoff as everything else; the app does not wedge.
- **Hysteresis** on the icon: the icon flips to error after a single failed poll, but only flips back after **two consecutive** successful polls. This prevents visual flap on flaky networks.
- **Per-repo failure rows** in the dropdown: when a single watched repo is deleted, renamed, transferred, or has access revoked, its rows in the affected sections are replaced by a single **No access** row with a structured cause ("Access revoked", "Repository not found", or "Repository not found — it may have been renamed or transferred") and an inline **Remove** action. The global menubar icon does **not** enter error state for a single-repo failure — it only escalates when every watched repo is failing or the failure is app-level.
- On a poll that recovers events from a long outage, notifications fire for each event missed during the outage, deduplicated as usual. The dropdown remains the authoritative view if individual notifications are coalesced by macOS.
- The first time the app launches and `gh auth status` fails with a network-style error (rather than an auth-style error), the app enters the **error** state, not the setup state, and retries.

**Why this is Phase 6.** Until this phase, the app's error behavior is "everything works in the happy path." Real-world Mac conditions — flaky Wi-Fi, GitHub rate limits, scopes revoked from the side, a teammate renaming a watched repo — start producing wrong behavior the moment a user dogfoods the app. Landing this phase after the four event types and the user-facing controls means the error surfaces have a stable set of UI affordances to slot into, and the user-facing copy can be written once against a complete dropdown. The icon hysteresis and the per-repo-vs-app-level distinction are both subtle rules whose correctness is easier to verify against a working baseline.

**Outcome to demonstrate.**

1. With the app running normally, disconnect the Mac from the network. Within the next polling tick, the menubar icon switches to the error state. The dropdown's status banner reads "Network unavailable — Retry now."
2. Reconnect the network. The first successful poll does not yet clear the error icon. The second consecutive successful poll does — the icon returns to idle or active depending on outstanding items.
3. Simulate `gh` hitting a rate limit. The banner reads "GitHub rate limit exceeded — Retrying at HH:MM." The app does not retry until the reported reset time.
4. Have a teammate rename one of the watched repos on GitHub. On the next tick, that repo's rows in the dropdown sections are replaced by a single "No access — Repository not found — it may have been renamed or transferred — Remove" row. The other watched repos continue to work normally. The menubar icon does not enter error state.
5. Click "Remove" on the per-repo error row. The repo is removed from the watched list.
6. Revoke notification permission for the app in System Settings. The banner reads "Notifications disabled — Open System Settings." Polling and the dropdown continue to function; only notifications are suppressed.
7. Cause the saved state file to become unreadable (rename it, corrupt it). The banner reads "Corrupted state — Open folder / Reset state (you may receive notifications for recent events)." Clicking "Reset state" clears the dedup memory and resumes polling; the user has been warned in the button label that this may produce a catch-up flood.

**Source citations.**
- [Error state](feature-specification.md#error-state-gh-failure-network-failure-rate-limit-parse-error) — the full alternate flow, including hysteresis, structured causes, and the rate-limit handling.
- [Edge Cases and Failure Modes](feature-specification.md#edge-cases-and-failure-modes) — per-repo 404 handling (rename, transfer, access revoked, deleted), notification permission denied, corrupted state, scope revocation, parse errors.
- [Menubar icon](feature-specification.md#menubar-icon) — the error state's visual treatment and accessible label.
- [Dropdown popover](feature-specification.md#dropdown-popover) — the status banner's placement and field structure.
- [F26 icon flap](artifacts/team-findings.md#f26-icon-flap-on-alternating-successfailure) — the two-success hysteresis rule.
- [F12 per-repo error treatment](artifacts/team-findings.md#f12-renamedtransferred-repo-error-treatment-is-per-app-instead-of-per-repo) — per-repo "No access" rows rather than app-level error state.
- [F14 parse error recovery](artifacts/team-findings.md#f14-gh-output-format-change-error-wedges-the-app-permanently) — parse errors use the standard backoff, not a separate wedge state.
- [F30 reset state warning copy](artifacts/team-findings.md#f30-notification-history-reset-state-warning-copy) — the reset-state button's explicit consequence wording.
- [F13 network vs auth at startup](artifacts/team-findings.md#f13-gh-auth-status-failures-cannot-distinguish-not-signed-in-from-network-unavailable) — distinguishing network failures from auth failures at first-run.

**Connects to.**
- Adds the error state to the menubar icon that [Phase 1](#phase-1) established with idle and active states only.
- Adds the per-repo error row alongside the per-repo content rows that [Phase 4](#phase-4) established through Manage repositories.
- Sets up the icon-state and banner surfaces that [Phase 8](#phase-8) annotates with accessibility labels.

**Preconditions to verify before starting.**
- Decide the exact set of cause categories the banner exposes. The source's list of seven (not signed in, rate limited, network unavailable, insufficient scope, parse error, notifications disabled, corrupted state) is recommended; confirm before build.
- Decide what "two consecutive successful polls" means in the rare case where the user manually triggers a retry between scheduled ticks: does a manual retry count toward the consecutive count, or only scheduled ticks?

---

### Phase 7: First-run, Login Item safety, and crash resilience {#phase-7}

**Kind.** Feature slice.

**Builds on.** [Phase 6](#phase-6) — the user-facing error surfaces are in place; this phase hardens the app's behavior in real-world Mac deploy conditions (Login Items, crashes, GUI-app PATH quirks).

**What we build.**

- **Single-instance enforcement on the same Mac.** When the app is launched a second time while already running, the second launch detects the running instance, activates its dropdown, and exits. There are no doubled notifications and no racing state writes. This makes the "Login Item plus manual launch" case safe by default.
- **GUI-app PATH detection in the setup checklist.** When `gh` is installed but not reachable from the app's runtime environment (typically because the app launched as a Login Item with a minimal PATH while `gh` lives in a Homebrew location), the setup checklist's first row shows a distinct message — "`gh` not found in this app's environment — see Troubleshooting if `gh` is already installed" — with a link to a troubleshooting note about GUI-app PATH. This is distinct from the plain "Install `gh`" copy a user with no `gh` at all would see.
- **Crash-safe persistence.** Writes of the watched-repo list and the dedup memory are persisted such that a crash mid-write does not leave the saved state partially updated. After a forced kill, the next launch resumes from the last fully-written state without re-delivering events.
- **Immediate first poll after setup.** When the user completes the last setup checklist row (typically the "Add a repository" step), the app fires its first real poll immediately rather than waiting up to a minute for the next scheduled tick. The first-run experience does not feel broken.
- **Network-vs-auth distinction at first-run.** When the first-run `gh auth status` call fails with a network-style error, the app enters the error state (per [Phase 6](#phase-6)) rather than telling a signed-in user to run `gh auth login`. The setup state is entered only when the auth check returns a conclusive "not signed in" result.
- **Auth-network distinction during normal operation:** the same rule applies whenever the app re-checks auth after a network blip.

**Why this is Phase 7.** Every item in this phase is a real-world failure mode that the source spec calls out by name, but none of them are user-visible features in their own right — they make the app safe to install as a Login Item, safe to leave running for weeks, and safe to recommend to a teammate. They land after the error state in Phase 6 because most of them are described in terms of "this triggers the error state" or "this prevents the setup state from misfiring," so the surfaces they hook into need to exist first. Grouping them in one phase keeps the related deploy concerns together rather than scattering them across earlier phases as polish.

**Outcome to demonstrate.**

1. Set the app as a Login Item. Log out and log back in; the app starts automatically. Launch it again from the Applications folder. The second launch activates the existing instance's dropdown and exits — no second menubar icon appears, no duplicate notifications fire.
2. On a Mac that has `gh` installed via Homebrew, set the app as a Login Item and log in. The setup checklist's first row shows "`gh` not found in this app's environment — see Troubleshooting if `gh` is already installed" with a Troubleshooting link, **not** "Install `gh`."
3. With the app running and outstanding notifications recorded in its dedup memory, force-quit it mid-poll. Relaunch. The next poll resumes from the last fully-written state; no events are double-delivered; no previously-handled event re-fires.
4. From a clean install with `gh` installed and signed in, walk through the setup checklist. The instant the "Add a repository" step is completed, a poll fires immediately and the dropdown populates without waiting a minute for the next scheduled tick.
5. Disconnect from the network, then launch the app. The first-run `gh auth status` call fails with a network error. The app enters the error state (banner reads "Network unavailable — Retry now"), not the setup state. The user is not asked to run `gh auth login`. When the network returns, the app re-checks auth and proceeds normally.

**Source citations.**
- [Edge Cases and Failure Modes](feature-specification.md#edge-cases-and-failure-modes) — the two-instances row, the `gh`-installed-but-not-on-PATH row, the force-quit-mid-poll row, and the network-vs-auth row at app launch.
- [First-run / setup](feature-specification.md#first-run--setup) — the immediate first-poll on setup completion and the distinct PATH troubleshooting copy.
- [Coordinations](feature-specification.md#coordinations) — the local saved state's crash-safety commitment and the single-instance boundary requirement.
- [F4 GUI-app PATH](artifacts/team-findings.md#f4-gh-not-on-the-gui-apps-path-is-misdiagnosed-as-not-installed) — the rule that distinguishes "not installed" from "not reachable from app's environment."
- [F5 two-instances duplicate notifications](artifacts/team-findings.md#f5-two-instances-on-the-same-mac-produce-duplicate-notifications) — the single-instance requirement.
- [F23 first-poll latency gap](artifacts/team-findings.md#f23-first-run--first-poll-has-a-silent-latency-gap) — the immediate first-poll rule.

**Connects to.**
- Builds on the setup checklist from [Phase 1](#phase-1) by adding the GUI-app PATH copy variant and the immediate first-poll trigger.
- Builds on the error-state machinery from [Phase 6](#phase-6) by routing the network-style `gh auth status` failure into it.
- Closes the source spec's "Edge Cases and Failure Modes" table in combination with [Phase 6](#phase-6).

**Preconditions to verify before starting.**
- Decide the user-facing copy for the GUI-app PATH troubleshooting note (the page or in-app section the row's link points to), and where that copy lives.
- Decide whether the single-instance behavior also surfaces a brief "already running" affordance for the user, or whether silently activating the existing dropdown is sufficient.
- Decide whether the immediate-first-poll trigger fires every time the last setup step is completed, or only on the genuine "first ever" setup completion.

---

### Phase 8: Accessibility commitment {#phase-8}

**Kind.** Polish.

**Builds on.** [Phase 7](#phase-7) — every UI surface this phase annotates (menubar icon, dropdown sections, rows, controls, error and setup banners) is stable; this phase makes them accessible.

**What we build.**

- **Menubar icon accessible labels.** The icon exposes a state-inclusive label that screen-reader users hear: "git-notified, no outstanding items" / "git-notified, N outstanding items" / "git-notified, setup required" / "git-notified, error." The state is announced as text, not encoded only in the icon's appearance.
- **Count badge meets WCAG 1.4.1.** The active-state badge is a numeric count rather than a colored dot, so the "outstanding items exist" signal is not conveyed by color alone. (In practice this is true from [Phase 1](#phase-1); this phase verifies and documents the commitment.)
- **Dropdown section headings.** "Reviews requested", "CI failing", and "New comments & reviews" are announced by VoiceOver as headings, not as plain text.
- **Row semantics.** Each PR row in any section is announced as a button whose accessible name is the full visible text of the row.
- **Silence toggle state announcement.** The toggle is announced as a button carrying its current state — "Silence notifications, button, off" or "Silenced, button, on."
- **Keyboard navigation.** Tab and Shift-Tab move focus through the dropdown's rows and controls in a sensible order. Return activates a row (opens its PR) or toggles a control. Escape dismisses the dropdown.
- **Manage repositories panel accessibility.** Each row's mode picker and remove control are reachable by keyboard and announce their current state and action.
- **Error and setup banners.** When present, the banner is announced as a status region; the structured cause is read out as text; the action affordance is announced as a button.

**Why this is Phase 8.** Accessibility lands last because every UI surface it covers needs to be stable. Re-annotating section headings, row semantics, and banner text after each preceding phase would be churn. Doing it once, against a complete surface, also makes the verification pass — running VoiceOver through the full dropdown end-to-end — much faster and more reliable. The behavioral commitments are simple to verify in isolation, so the phase is small and well-scoped despite touching every screen.

**Outcome to demonstrate.**

1. Turn on VoiceOver. Move the cursor to the menubar icon. VoiceOver reads "git-notified, 3 items outstanding" (or the equivalent label for the current state).
2. Open the dropdown. Tab through the rows. VoiceOver reads each section heading as a heading and each row as a button with the row's full visible text.
3. Tab to the silence toggle. VoiceOver reads "Silence notifications, button, off." Press Return to activate. The toggle's label re-announces as "Silenced, button, on."
4. Tab to a PR row. Press Return. The PR opens in the default browser.
5. Tab to "Manage repositories…", press Return. The push view opens. Each repo row's mode picker is keyboard-reachable; the remove control announces its action.
6. Press Escape. The dropdown dismisses.
7. Cause an error condition (disconnect network). The icon flips to error. Open the dropdown. VoiceOver reads the status banner including the cause and the action label.
8. Confirm the active-state count badge is a number, not a colored dot.

**Source citations.**
- [Accessibility](feature-specification.md#accessibility) — the entire commitment, including VoiceOver and keyboard rules.
- [Menubar icon](feature-specification.md#menubar-icon) — the state-inclusive accessible labels.
- [Dropdown popover](feature-specification.md#dropdown-popover) — section headings, row formats, and the silence toggle's label rules.
- [F17 accessibility unspecified](artifacts/team-findings.md#f17-accessibility-behavior-is-completely-unspecified) — the resolution that brought accessibility into v1 as a behavioral commitment.

**Connects to.**
- Annotates surfaces established in every preceding phase — Phase 1 (menubar icon, base dropdown sections), Phase 2 (CI failing section), Phase 3 (New comments & reviews section), Phase 4 (Manage repositories panel), Phase 5 (silence toggle and post-resume banner), Phase 6 (error icon and status banner), Phase 7 (setup checklist edge-case copy).

**Preconditions to verify before starting.**
- Decide whether the accessibility verification is a manual VoiceOver run per release, an automated check against accessibility metadata, or both.
- Confirm the keyboard activation key for rows. Return is the default; the team may want to also support Space.

---

### Phase 9 (Deferred): Carried-forward YAGNI items {#phase-9}

**Kind.** Deferred.

**Builds on.** Not applicable until built — each item below would slot in based on its own dependencies when it is reopened.

**What we would build.** The source artifact's `Deferred (YAGNI)` list, carried forward verbatim with the reopening trigger named for each. None of these are built in the eight-phase plan above.

- **Per-event-type mute toggles (CI off, comments off, etc.).**
  - Why deferred: the per-repo mode picker already gives users coarse on/off control and matches GitHub's own model.
  - Reopen when: users report specific repos being too noisy on one event type (typically CI) without wanting to silence everything on that repo.
- **In-app PR preview / detail view.**
  - Why deferred: opening in the browser satisfies the click-through need with the minimum surface area.
  - Reopen when: users complain that browser context-switching is too heavy.
- **Scheduled quiet hours.**
  - Why deferred: macOS Focus modes already provide system-wide quiet hours, and the silence toggle covers the ad-hoc case.
  - Reopen when: users explicitly ask for app-level scheduling, or a Focus-mode integration becomes desirable.
- **Digest mode / time-window coalescing.**
  - Why deferred: per-event notifications with per-event deduplication match user expectation for "review requested" urgency.
  - Reopen when: users report chatty CI loops — particularly from force-push-triggered CI restarts on active PRs — producing too many notifications even with current dedup.
- **Notification history view.**
  - Why deferred: no requirement has been raised for revisiting dismissed notifications.
  - Reopen when: users ask to see what they missed, or a "what changed today" view would be valuable.
- **Multi-account or multi-host support (multiple `gh` hosts or accounts).**
  - Why deferred: the stated v1 user is a single developer on a single account.
  - Reopen when: the user (or a teammate) operationally needs both `github.com` and an enterprise instance, or both a personal and work account, simultaneously visible.
- **Webhook or push-based delivery.**
  - Why deferred: roughly 60-second polling latency is acceptable, and webhooks require either a hosted endpoint or a local tunnel.
  - Reopen when: sub-minute latency becomes a felt need.
- **Cross-machine state sync.**
  - Why deferred: single-machine use is the assumed v1 audience.
  - Reopen when: a user reports double notifications across machines as a recurring frustration.
- **A dedicated Settings panel.**
  - Why deferred: every configurable surface in v1 is already covered by the per-repo mode picker or the silence toggle. There is no setting that needs its own panel.
  - Reopen when: a setting exists that cannot be expressed in per-repo mode or the silence toggle.
- **Configurable Recent Activity window.**
  - Why deferred: 24 hours (with the silence-or-offline expansion to 7 days) covers known cases. Configurability has no current driver.
  - Reopen when: users report that 24 hours is consistently the wrong window for their workflow.
- **Persistent silence across launches.**
  - Why deferred: non-persistent silence prevents the user from being permanently muted unexpectedly.
  - Reopen when: users report losing silence state across a crash or Login Item restart as a frustration.
- **Detailed scope-revocation diagnostics.**
  - Why deferred: the generic "re-run `gh auth login`" recovery instruction handles all scope cases without per-scope detection logic.
  - Reopen when: users report confusion about which scope was lost.
- **Optimistic dropdown content updates on mode change.**
  - Why deferred: the config-level optimistic update on the mode picker (already in [Phase 4](#phase-4)) is sufficient feedback. Recomputing dropdown content on mode change before the next tick adds complexity for limited gain.
  - Reopen when: users report the wait between mode change and dropdown update is confusing.

**Source citations.**
- [Deferred (YAGNI)](feature-specification.md#deferred-yagni) — every item above is lifted from this section with no change to its reopening trigger.

---

## Open Questions {#open-questions}

> Decisions or verifications the team must resolve before the corresponding phase starts. Each question is presented with realistic options and a recommended answer where one is supportable. Cite open questions as `OQ-N` in follow-up.
>
> **Ordering:** open questions are listed by the lowest-numbered phase they block, ascending. A carry-over question that does not block any specific phase appears at the bottom under "Carry-over notes."

### OQ-1. Does `gh` expose the data Phase 1 needs to deduplicate review requests per PR? {#oq-1}

**Blocks phase(s).** Phase 1.

Phase 1 relies on being able to recognize when a specific review request has already produced a notification, even across restarts. The dedup model wants a stable per-event identifier plus a timestamp for each pending review request, scoped per pull request. If the `gh` query the team chooses for this returns only a coarse snapshot (no stable identifier, no timestamp), Phase 1 cannot deliver its core promise.

- **Option A — Use `gh`'s pull-request search with the per-PR review-request signal and per-event identifiers.** The source artifact assumes this works ([D17](artifacts/decision-log.md#d17-cursor-data-model-per-repo-pr-event-type)). A short verification probe — fetch the relevant data for one repo, inspect the response — confirms it.
- **Option B — Use a coarser data path and reconstruct dedup on the app side.** Adds complexity, may produce missed notifications.
- **Recommendation: Option A**, conditional on a short probe by the engineer kicking off Phase 1. If the probe fails, revisit before committing the phase.

### OQ-2. How strict does the on-disk state's crash safety need to be in Phase 1? {#oq-2}

**Blocks phase(s).** Phase 1.

The source spec commits to crash-safe persistence so a crash mid-write does not corrupt saved state. [Phase 7](#phase-7) is where crash-safe writes formally land. Phase 1 could either implement the strict guarantee from day one or accept a small demo-time risk and defer the strict guarantee to Phase 7.

- **Option A — Implement crash-safe writes from Phase 1.** No further work in Phase 7. Slightly delays Phase 1.
- **Option B — Use plain writes in Phase 1, harden in Phase 7.** Phase 1 lands faster, but a crash mid-demo can corrupt state until Phase 7 closes the gap.
- **Recommendation: Option A.** The strict guarantee adds no material delay to Phase 1 and avoids any risk of corrupted state during a demo or real use.

### OQ-3. Does `gh` expose per-check conclusions and the parent commit identifier for CI? {#oq-3}

**Blocks phase(s).** Phase 2.

Phase 2's CI logic aggregates across multiple checks and recognizes when a newer commit supersedes an earlier failing suite. Both require per-check conclusion data and the commit each check ran against. If `gh` only reports an aggregate conclusion per PR without per-check detail, the supersession rule cannot be implemented as specified.

- **Option A — Use `gh`'s per-check data on the latest commit.** The source artifact assumes this works ([D10](artifacts/decision-log.md#d10-one-notification-per-event-dedup-by-cursor-comparison) and [F9](artifacts/team-findings.md#f9-ci-fail-notification-trigger-is-undefined-for-mixed-state-check-suites)). A probe at the start of Phase 2 confirms.
- **Option B — Notify on aggregate CI conclusion only.** Simpler but loses the "one check failing, others still running" mid-state distinction the source promises.
- **Recommendation: Option A**, conditional on a short probe by the engineer kicking off Phase 2.

### OQ-4. Should comments on closed or merged PRs appear in the 24-hour activity window? {#oq-4}

**Blocks phase(s).** Phase 3.

The source spec defines the "New comments & reviews" section as comments and reviews on in-scope pull requests in the last 24 hours, but is silent on what happens once a PR closes or merges. The closed-PR case is common — teams routinely comment on merged PRs for a few hours afterward, and the user may want to see those.

- **Option A — Include comments and reviews on a PR until it falls out of the active scan window.** Closes are not a special case; the section keeps showing the comment until 24 hours elapse from its timestamp.
- **Option B — Drop comments and reviews the moment the PR closes or merges.** Cleaner, but cuts off legitimately useful post-merge feedback.
- **Recommendation: Option A.** Matches the user's mental model that a comment is fresh for 24 hours regardless of PR state, and is consistent with the dropdown being a current-state snapshot rather than a notification log.

### OQ-5. What is the exact phrasing and dismissal behavior of the post-resume silence banner? {#oq-5}

**Blocks phase(s).** Phase 5.

The source spec commits to a transient banner above "New comments & reviews" on resume, reading "Silenced for N minutes — M new items below." Two sub-decisions are open: the exact phrasing for the time unit (minutes / hours / days as N grows) and the trigger that dismisses the banner.

- **Option A — Auto-scale the time unit ("Silenced for 17 minutes" → "Silenced for 4 hours" → "Silenced for 2 days") and dismiss the banner on the user's next interaction with the dropdown.** Lowest-friction option.
- **Option B — Always show minutes, dismiss on a fixed timer (e.g., 10 seconds after the popover opens).** Predictable but reads awkwardly for long silences ("Silenced for 2880 minutes").
- **Recommendation: Option A.**

### OQ-6. Does a manual retry count toward the "two consecutive successful polls" hysteresis rule? {#oq-6}

**Blocks phase(s).** Phase 6.

Phase 6 commits to flipping the menubar icon back from error state only after two consecutive successful polls. If the user clicks the "Retry now" action on the status banner, the rule has to say whether the manual retry counts toward the consecutive count or whether only scheduled ticks do.

- **Option A — Manual retries count.** A successful manual retry followed by a successful scheduled tick clears the icon.
- **Option B — Only scheduled ticks count.** A manual retry can confirm "the network is back" but does not by itself contribute to clearing the icon; the icon clears only on two consecutive scheduled ticks succeeding.
- **Recommendation: Option A.** Matches user expectation that "I clicked Retry and it worked" should be reflected in the icon state, and avoids the surprise of the icon staying red after a successful manual retry.

### OQ-7. Where does the GUI-app PATH troubleshooting copy live? {#oq-7}

**Blocks phase(s).** Phase 7.

Phase 7's setup-checklist row for the "`gh` installed but not reachable" case carries a link to a troubleshooting note. The decision is whether the note lives inside the app's own dropdown (a Troubleshooting push view), on the project's README, or on an external page (e.g., the project site).

- **Option A — A Troubleshooting push view inside the dropdown.** Self-contained, no network required, but adds a new screen to maintain.
- **Option B — Link out to the project README on GitHub.** Zero in-app surface, but breaks if the user is offline (which is plausible for a network-troubleshooting page).
- **Option C — Link out to a dedicated project site page.** Best presentation for non-technical users, but adds an external dependency.
- **Recommendation: Option A.** The user needing this copy is already in a degraded state; an in-app Troubleshooting push view avoids the offline failure mode and keeps the copy under the team's direct control.

### Carry-over notes

#### OQ-8. What is the concrete poll budget? {#oq-8}

**Blocks phase(s).** None — carry-over note from the source spec's `OI-3`.

The spec leaves open the question of at how many watched repositories a single approximately-60-second polling tick starts to risk secondary rate limits. The source spec marks this as something to measure before public release rather than something to decide up-front.

- **Recommendation:** Plan an early measurement against a real `gh`-authenticated account once Phase 2 or Phase 3 is dogfooded, and use the measurement to set a soft warning threshold in Manage repositories ("you have N watched repos in `all` mode; this may exceed GitHub's rate limit at the chosen interval"). No specific phase blocks on this; the soft warning, if added, would be a small follow-up after Phase 4.

---

---

## Phase Kinds (reference) {#phase-kinds}

> Definitions for the kind labels used in the [Build Phase Index](#build-phase-index) and on each phase entry's `**Kind.**` line. Consult on demand — readers do not need this section to scan the index or read individual phase entries.

- **Foundation** — A capability that does not deliver new user-facing features on its own, but is required for later phases. Must still be demoable in its own right (e.g., "an admin can edit and persist a new setting").
- **Feature slice** — A thin end-to-end strip of new behavior that a real user can experience.
- **Polish** — Branding, refinement, observability, or quality-of-life work that enriches a working core.
- **Deferred** — Listed for traceability; not built in the current plan. Slotted at the end of the index.

---

*End of outline. If you need to cite a specific phase elsewhere, use its `Phase N` number — those numbers are stable for the life of this document. If you need to cite a specific open question, use its `OQ-N` ID.*
