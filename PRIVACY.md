# Privacy Policy

*WatchMan for Mac and WatchMan for iPhone. Last updated: October 2, 2026.*

**WatchMan collects no data.** There are no accounts, no analytics, no ads, no tracking and no servers of ours.

## What stays on your Mac

WatchMan for Mac reads what Claude Code writes on your Mac (its hook events, transcripts in `~/.claude/projects/`
and its session registry) to show your sessions. It keeps its own settings and the last two days of session events
in `~/Library/Application Support/WatchMan/`. None of it leaves your Mac, except as described below.

## The link to your iPhone

If you use WatchMan for iPhone, your sessions, chats, answers, settings and any photos you attach to a reply travel
between your Mac and your iPhone through **your own private iCloud database** (CloudKit). Apple stores it encrypted
under your Apple ID, and the developer has no access to it. You can delete it any time: in iCloud settings, manage
storage, WatchMan, Delete Data. Turning the link off in WatchMan for Mac stops it sharing anything.

## Network requests

- iCloud, for the link above (only if you use the iPhone app).
- Apple's push notification service, which wakes the apps when something changes.
- A check for a newer version on GitHub when WatchMan for Mac starts.
- ntfy.sh, only if you turn on phone alerts through ntfy and enter your own topic.
- If you turn on summaries for the Dev Log, Claude Code summarizes each session through your own Claude account.

## Your Obsidian vault

If you use the Dev Log, WatchMan writes one note a day in the vault and folder you choose, and reads notes that
project-sync links to your projects. Nothing is sent anywhere.

## Children

WatchMan is a tool for developers and isn't directed at children.

## Contact

Questions about privacy: open an issue at https://github.com/A7mdMosa/WatchMan/issues.

Claude and Claude Code are trademarks of Anthropic. WatchMan is an independent app and is not affiliated with Anthropic.
