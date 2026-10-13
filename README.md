# ClaudeUsageBar

A small macOS menu bar app that shows your current Claude usage limits and when they reset.

![ClaudeUsageBar in the menu bar](docs/screenshot.png)

The title shows, from left to right:

- **Limit**: the 5 hour and 7 day usage as a ring and a percentage.
- **Reset on**: the time left until each limit resets.

The app reads the login that Claude Code already stores on your Mac, so there is nothing to configure.

## Requirements

- macOS 13 or later
- Xcode command line tools (provides `swiftc` and `codesign`). Install with `xcode-select --install`.
- Claude Code installed and logged in with a Claude subscription account (Pro or Max)

## Installation

1. Clone or copy this folder to your Mac.

2. Build the app:

   ```bash
   cd ClaudeUsageBar
   ./build.sh
   ```

   This produces `ClaudeUsageBar.app` in the same folder.

3. Move the app to your Applications folder (optional but recommended):

   ```bash
   mv ClaudeUsageBar.app /Applications/
   ```

4. Launch it:

   ```bash
   open /Applications/ClaudeUsageBar.app
   ```

   The usage text appears in the menu bar. There is no Dock icon.

5. On first launch macOS asks whether `security` may access the Keychain item named "Claude Code-credentials". Choose **Always Allow** so it does not ask again.

6. To start it automatically, click the menu bar item and choose **Launch at Login**.

Because the app is signed ad hoc, macOS may block it if you download a prebuilt copy from elsewhere. Building it locally with `build.sh` avoids this. If it is blocked, right-click the app and choose **Open**.

## Usage

Click the menu bar item to open the menu:

| Item | Description |
| --- | --- |
| Updated at ... | Time of the last successful refresh, plus the error if one occurred |
| Refresh Now | Fetch usage immediately (Cmd+R) |
| Launch at Login | Toggle automatic start at login |
| Quit | Close the app (Cmd+Q) |

Usage is fetched every 60 seconds and again after the Mac wakes from sleep. The reset countdowns update every 30 seconds.

Countdown format: under one day it shows hours and minutes (`4h 22m`), otherwise days and hours (`2d 5h`).

### Status messages

| Message | Meaning |
| --- | --- |
| `Limit: Not logged in to Claude Code` | No Claude Code login was found in the Keychain or in `~/.claude/.credentials.json`. Log in with Claude Code. |
| `Limit: Login expired - open Claude Code` | The stored token was rejected. Open Claude Code once so it refreshes the login. |
| `Limit: Offline` | The usage request failed. The app retries on the next refresh. |
| A warning sign after the numbers | The latest refresh failed, so the numbers shown are from the previous successful one. |

### Command line check

To print the title text to the terminal without starting the menu bar app:

```bash
./ClaudeUsageBar.app/Contents/MacOS/ClaudeUsageBar --print
```

Example output:

```
Limit: 5h [░░░░░░░░] 4% 7d [█░░░░░░░] 18%  |  Reset on: 5h 4h 22m 7d 2d 5h
```

## How it works

1. The OAuth access token is read from the Keychain item "Claude Code-credentials" (or `~/.claude/.credentials.json` as a fallback).
2. The app calls `https://api.anthropic.com/api/oauth/usage` and reads the `five_hour` and `seven_day` utilization and reset times.
3. The result is drawn into the menu bar title using colored text and small ring images.

The token is only sent to `api.anthropic.com`. It is not stored or logged by this app.

The usage endpoint is undocumented and may change without notice. If it does, the app will show an error until it is updated.

## Customizing

Everything lives in `main.swift`.

- Colors: `UsageFormatter.attributedTitle` (labels, percentages, reset times) and `UsageFormatter.barImage` (ring)
- Ring size and thickness: `UsageFormatter.barSize` and `lineWidth` in `barImage`
- Refresh interval: the timer in `applicationDidFinishLaunching`

After editing, run `./build.sh` again and relaunch the app.

## Uninstall

Quit the app from its menu, then delete `ClaudeUsageBar.app`. If you enabled Launch at Login, turn it off first from the menu.

## Project layout

```
ClaudeUsageBar/
  main.swift      App source
  build.sh        Builds and signs ClaudeUsageBar.app
  docs/           README screenshot
  README.md
```
