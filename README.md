# git-notified

A macOS menu-bar app that triages your open GitHub pull requests. It polls
GitHub in the background and shows the queue of PRs you need to do something
about — yours that are ready to merge / failing / waiting on you, and other
people's PRs that are waiting on your review.

The menu-bar title summarizes the queue with a per-state emoji and count
(`GN ✅3 👀2 ⏳1`); clicking opens the dropdown.

## Requirements

- macOS 14 (Sonoma) or later
- [`gh`](https://cli.github.com) (GitHub CLI) installed and on your PATH
- A signed-in `gh` session with `repo` scope (the default)

## Quick start

```bash
# 1. Install gh and sign in if you haven't already
brew install gh
gh auth login

# 2. Clone and build
git clone <this-repo-url> git-notified
cd git-notified
./build-app.sh debug       # or `release` for an optimized build

# 3. Launch
open build/git-notified.app
```

The first launch will prompt for notification permission — grant it so the app
can ping you when a PR moves into an actionable state. After that, the menu
bar will show `GN 🔄` while the first poll runs, then settle into a state
breakdown (or `GN 🎉` if your queue is empty).

## What it watches

Two GitHub-search queries, refreshed every poll:

- **Your PRs** — open PRs you authored, in any state (CI failing, changes
  requested, unanswered comments, approved/ready-to-merge, just sitting
  waiting for review).
- **Awaiting Your Review** — open PRs where you're a requested reviewer.

The dropdown sorts each section by triage priority. Right-click a row for
"Open in browser" or "Hide this PR" — hidden PRs stay hidden across restarts
until you click "Show N hidden" in the footer.

## Day-to-day

- **Clicking a row** opens the PR in your browser.
- **"Silence notifications"** stops popups until you toggle it back on; the
  badge still updates so you can check the queue when you're ready.
- **The status emoji** is the top-priority non-empty bucket (🚨 CI failing →
  📝 changes requested → 💬 unanswered comment → ✅ approved → 👀 review
  requested → ⏳ waiting for review). Numbers next to each emoji are
  per-bucket counts.

## Troubleshooting

**Menu bar shows `GN ⚙️` (setup needed):**

- "Install gh" — run `brew install gh`.
- "gh not found in this app's environment" — gh is installed but not on the
  app's PATH. This happens when launching from Finder / Login Items with a
  minimal PATH. Either symlink gh into `/usr/local/bin` or launch the app
  from a terminal that has gh on PATH.
- "Sign in with gh auth login" — run `gh auth login` in a terminal.

**Menu bar shows `GN ⚠️` (error):**
Click the bar to see the cause (rate-limited, network unavailable, etc).
Most resolve themselves on the next poll.
