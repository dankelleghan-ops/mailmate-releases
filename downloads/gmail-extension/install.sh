#!/bin/bash
# MailMate Tracking for Gmail — install or update (macOS). Double-click, or let it run itself:
# safe to run again any time, it just fetches whatever is newest.
#
# WHY THERE'S A BACKGROUND UPDATER: Chrome only auto-updates extensions installed from the
# Chrome Web Store. This one is loaded "unpacked" (Developer mode -> Load unpacked), which
# Chrome never updates on its own — the little (circular arrow) on the extension's card only
# re-reads whatever is already sitting on disk. So the only way a fix or a new feature ever
# reaches this Mac is this script running again. Running it by hand every time isn't realistic,
# so every install also registers a small background job (a per-user LaunchAgent) that re-runs
# this same script with --background every 6 hours and at login. It downloads nothing and
# shows nothing unless a genuinely newer version is out.
#
# WHAT "UPDATED" MEANS IN PRACTICE: once this script has swapped the files on disk, Chrome
# picks up the change the next time it reloads this extension — click the small (circular
# arrow) on the extension's card in chrome://extensions, or it happens automatically the next
# time Chrome itself is restarted. Nothing more is required.
#
# No python3 anywhere in this script on purpose: a Mac without Xcode's Command Line Tools
# pops an "install developer tools" dialog the first time /usr/bin/python3 runs — a bad
# surprise during an easy install, and fatal for a job running silently in the background.
# osascript (JavaScript for Automation) ships on every Mac and does the same JSON-reading job.
#
# Run modes:
#   (no flags)     interactive install/update — dialogs, opens Chrome, copies the folder path
#                  to the clipboard. What a person double-clicks (directly, or via the
#                  installer app inside the DMG).
#   --background   silent — the LaunchAgent calls this. No dialogs, no windows. Only touches
#                  disk if a newer version is actually available, and always exits 0 — even
#                  offline — so it never nags or breaks anything unattended.
#   --uninstall    removes the LaunchAgent (stops automatic checks). Does not remove the
#                  extension from Chrome and does not delete the installed folder.
set -e

LATEST_URL="https://raw.githubusercontent.com/dankelleghan-ops/mailmate-releases/main/downloads/gmail-extension/latest.json"
INSTALL_SH_URL="https://raw.githubusercontent.com/dankelleghan-ops/mailmate-releases/main/downloads/gmail-extension/install.sh"

# A visible, plain path on purpose — the friend has to find and pick this exact folder in
# Chrome's "Load unpacked" file picker, so it needs to be somewhere obvious, not buried in a
# temp or app-support directory.
INSTALL_DIR="$HOME/MailMate Gmail Tracking"
EXT_DIR="$INSTALL_DIR/extension"

LOG_DIR="$HOME/Library/Logs"
LOG_FILE="$LOG_DIR/MailMate-Gmail-Tracking-updater.log"
PLIST_LABEL="com.danielkelleghan.mailmate-gmail.updater"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
PLIST_PATH="$LAUNCH_AGENTS_DIR/$PLIST_LABEL.plist"

BACKGROUND=0
UNINSTALL=0
for arg in "$@"; do
  case "$arg" in
    --background) BACKGROUND=1 ;;
    --uninstall) UNINSTALL=1 ;;
  esac
done

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# One copy at a time. A double-clicked install and a scheduled background check overlapping
# would both try to swap the same folder. mkdir is atomic, so it doubles as the lock; a lock
# older than 10 minutes is a crashed run's leftover and gets taken over.
LOCK_DIR="${TMPDIR:-/tmp}/mailmate-gmail-updater-$(id -u).lock"
take_lock() {
  local waited=0
  while ! mkdir "$LOCK_DIR" 2>/dev/null; do
    if [ -n "$(find "$LOCK_DIR" -maxdepth 0 -mmin +10 2>/dev/null)" ]; then
      rm -rf "$LOCK_DIR"; continue
    fi
    [ "$BACKGROUND" = "1" ] && return 1
    [ "$waited" -ge 120 ] && return 0
    sleep 2; waited=$((waited + 2))
  done
  trap 'rm -rf "$TMP" "$LOCK_DIR"' EXIT
}
if [ "$UNINSTALL" != "1" ] && ! take_lock; then
  exit 0   # another run of this installer is already in flight; the next check catches up
fi

# One line into the update log, trimmed to the last 200 lines. Only used in --background mode.
log() {
  mkdir -p "$LOG_DIR" 2>/dev/null || true
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$LOG_FILE" 2>/dev/null || true
  if [ -f "$LOG_FILE" ]; then
    tail -n 200 "$LOG_FILE" > "$LOG_FILE.tmp" 2>/dev/null && mv "$LOG_FILE.tmp" "$LOG_FILE" 2>/dev/null || true
  fi
}

# Reads one top-level field out of a small JSON file. Uses JXA (JavaScript for Automation,
# built into every Mac) instead of python3 — see the note at the top of this file.
json_field() {
  MMGT_JSON_PATH="$1" MMGT_JSON_FIELD="$2" osascript -l JavaScript <<'JXA'
ObjC.import('Foundation');
function readFile(p) {
  try {
    var s = $.NSString.stringWithContentsOfFileEncodingError(p, $.NSUTF8StringEncoding, null);
    return s === null ? null : s.js;
  } catch (e) { return null; }
}
var env = $.NSProcessInfo.processInfo.environment;
var p = env.objectForKey('MMGT_JSON_PATH').js;
var f = env.objectForKey('MMGT_JSON_FIELD').js;
var c = readFile(p);
var out = '';
if (c !== null) {
  try {
    var m = JSON.parse(c);
    if (m && m[f] !== undefined && m[f] !== null) out = String(m[f]);
  } catch (e) {}
}
out;
JXA
}

# Is dotted version $1 strictly less than dotted version $2? (numeric, per segment)
version_lt() {
  local v1="$1" v2="$2"
  local IFS=.
  local -a a=($v1) b=($v2)
  local n1=${#a[@]} n2=${#b[@]} max i x y
  max=$n1
  [ $n2 -gt $max ] && max=$n2
  for ((i = 0; i < max; i++)); do
    x="${a[i]:-0}"; y="${b[i]:-0}"
    x="${x//[^0-9]/}"; y="${y//[^0-9]/}"
    [ -z "$x" ] && x=0
    [ -z "$y" ] && y=0
    if [ "$x" -lt "$y" ]; then return 0; fi
    if [ "$x" -gt "$y" ]; then return 1; fi
  done
  return 1
}

# Copy SRC over T without Chrome ever seeing T half-written: build the new copy alongside T,
# then swap it in with two fast renames.
swap_install() {
  local T="$1" SRC="$2"
  rm -rf "$T.new" "$T.old"
  mkdir -p "$(dirname "$T")"
  cp -R "$SRC" "$T.new"
  if [ -e "$T" ]; then
    mv "$T" "$T.old"
    mv "$T.new" "$T"
    rm -rf "$T.old"
  else
    mv "$T.new" "$T"
  fi
}

plist_content() {
  cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$PLIST_LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>/bin/bash</string>
		<string>-c</string>
		<string>/usr/bin/curl -fsSL "$INSTALL_SH_URL" | /bin/bash -s -- --background</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>StartInterval</key>
	<integer>21600</integer>
	<key>StandardOutPath</key>
	<string>$HOME/Library/Logs/MailMate-Gmail-Tracking-updater.out.log</string>
	<key>StandardErrorPath</key>
	<string>$HOME/Library/Logs/MailMate-Gmail-Tracking-updater.out.log</string>
	<key>ProcessType</key>
	<string>Background</string>
	<key>LowPriorityIO</key>
	<true/>
</dict>
</plist>
PLIST
}

# Idempotent: only (re)writes and reloads the job when its content actually changed, so a
# background run doesn't restart its own scheduler every 6 hours for no reason. Fetches the
# CURRENTLY PUBLISHED install.sh, not this file — so a fix shipped later reaches everyone who
# already installed, without them ever re-running the installer app by hand.
install_launch_agent() {
  mkdir -p "$LAUNCH_AGENTS_DIR"
  local new_content current_content
  new_content="$(plist_content)"
  if [ -f "$PLIST_PATH" ]; then
    current_content="$(cat "$PLIST_PATH" 2>/dev/null || true)"
    if [ "$current_content" = "$new_content" ]; then
      return 0
    fi
  fi
  printf '%s\n' "$new_content" > "$PLIST_PATH"
  if [ -z "$MMGT_NO_LAUNCHD" ]; then
    launchctl bootout "gui/$(id -u)/$PLIST_LABEL" >/dev/null 2>&1 || true
    launchctl bootstrap "gui/$(id -u)" "$PLIST_PATH" >/dev/null 2>&1 || true
  fi
}

uninstall_launch_agent() {
  if [ -z "$MMGT_NO_LAUNCHD" ]; then
    launchctl bootout "gui/$(id -u)/$PLIST_LABEL" >/dev/null 2>&1 || true
  fi
  rm -f "$PLIST_PATH"
}

# ---- --uninstall -----------------------------------------------------------

if [ "$UNINSTALL" = "1" ]; then
  uninstall_launch_agent
  echo "Removed the background updater. The extension itself is untouched in Chrome — this"
  echo "only stops MailMate Gmail Tracking from checking for a newer version on its own."
  exit 0
fi

# ---- --background (the LaunchAgent calls this) -----------------------------

if [ "$BACKGROUND" = "1" ]; then
  if [ ! -d "$EXT_DIR" ]; then
    log "not installed yet ($EXT_DIR missing) — nothing to update"
    exit 0
  fi

  # Keep the LaunchAgent itself current too; in practice this only writes anything the first
  # time the URL or interval ever changes.
  install_launch_agent

  LATEST_FILE="$TMP/latest.json"
  if ! curl -fsSL "$LATEST_URL" -o "$LATEST_FILE" 2>/dev/null; then
    log "could not reach $LATEST_URL — offline, will try again later"
    exit 0
  fi
  REMOTE_VER="$(json_field "$LATEST_FILE" version)"
  REMOTE_URL="$(json_field "$LATEST_FILE" url)"
  REMOTE_SHA="$(json_field "$LATEST_FILE" sha256)"
  if [ -z "$REMOTE_VER" ] || [ -z "$REMOTE_URL" ] || [ -z "$REMOTE_SHA" ]; then
    log "latest.json was unreadable or incomplete — skipping this check"
    exit 0
  fi

  CUR_VER="$(json_field "$EXT_DIR/manifest.json" version)"
  if [ -n "$CUR_VER" ] && ! version_lt "$CUR_VER" "$REMOTE_VER"; then
    log "already up to date at v$CUR_VER"
    exit 0
  fi

  ZIP="$TMP/extension.zip"
  if ! curl -fsSL "$REMOTE_URL" -o "$ZIP" 2>/dev/null; then
    log "found v$REMOTE_VER available but the download failed — will retry next time"
    exit 0
  fi
  ACTUAL_SHA="$(shasum -a 256 "$ZIP" | awk '{print $1}')"
  if [ "$ACTUAL_SHA" != "$REMOTE_SHA" ]; then
    log "downloaded zip for v$REMOTE_VER failed its checksum — leaving the current install alone, will retry next time"
    exit 0
  fi
  mkdir -p "$TMP/new"
  if ! unzip -oq "$ZIP" -d "$TMP/new" 2>/dev/null || [ ! -f "$TMP/new/manifest.json" ]; then
    log "the downloaded zip for v$REMOTE_VER was unreadable — will retry next time"
    exit 0
  fi
  swap_install "$EXT_DIR" "$TMP/new"
  log "updated $CUR_VER -> $REMOTE_VER"
  exit 0
fi

# ---- interactive install/update --------------------------------------------

echo "MailMate Tracking for Gmail — installer"
echo "Downloading the newest version..."

LATEST_FILE="$TMP/latest.json"
if ! curl -fsSL "$LATEST_URL" -o "$LATEST_FILE"; then
  echo "Could not reach the download server. Check your internet connection and try again." >&2
  exit 1
fi
REMOTE_VER="$(json_field "$LATEST_FILE" version)"
REMOTE_URL="$(json_field "$LATEST_FILE" url)"
REMOTE_SHA="$(json_field "$LATEST_FILE" sha256)"
if [ -z "$REMOTE_VER" ] || [ -z "$REMOTE_URL" ] || [ -z "$REMOTE_SHA" ]; then
  echo "The download information looked wrong. Try again in a few minutes." >&2
  exit 1
fi

ZIP="$TMP/extension.zip"
curl -fsSL "$REMOTE_URL" -o "$ZIP"
ACTUAL_SHA="$(shasum -a 256 "$ZIP" | awk '{print $1}')"
if [ "$ACTUAL_SHA" != "$REMOTE_SHA" ]; then
  echo "The download did not match what it should be (a checksum mismatch). Please try running this again." >&2
  exit 1
fi
mkdir -p "$TMP/new"
unzip -oq "$ZIP" -d "$TMP/new"
if [ ! -f "$TMP/new/manifest.json" ]; then
  echo "The download looks wrong (no manifest.json inside) — stopping without changing anything." >&2
  exit 1
fi

FIRST_RUN=0
[ -d "$EXT_DIR" ] || FIRST_RUN=1

swap_install "$EXT_DIR" "$TMP/new"
echo "Installed MailMate Tracking for Gmail v$REMOTE_VER into:"
echo "  $EXT_DIR"

# From here on a LaunchAgent keeps this current automatically — see the comment block at the
# top of this file for what it does and why.
install_launch_agent

# Put the folder path on the clipboard so the "Load unpacked" dialog is paste-and-go.
printf '%s' "$EXT_DIR" | pbcopy 2>/dev/null || true

CHROME_OPENED=1
open -a "Google Chrome" "chrome://extensions" 2>/dev/null || CHROME_OPENED=0

if [ "$FIRST_RUN" = "0" ]; then
  osascript -e "display dialog \"MailMate Tracking for Gmail updated to v$REMOTE_VER.

It will switch over the next time Chrome reloads it — click the small circular-arrow icon on its card in chrome://extensions, or it happens on its own the next time Chrome starts.\" with title \"MailMate Tracking for Gmail — updated\" buttons {\"OK\"} default button 1" >/dev/null 2>&1 || true
  exit 0
fi

# First-time setup. If Chrome could not be opened directly (not installed, or "open -a" failed
# on this particular Mac), fall back to a plain local page with the same steps rather than
# silently doing nothing.
if [ "$CHROME_OPENED" = "0" ]; then
  NEXT_STEPS="$TMP/next-steps.html"
  cat > "$NEXT_STEPS" <<HTML
<!doctype html>
<meta charset="utf-8">
<title>MailMate Tracking for Gmail — next steps</title>
<body style="font:16px/1.6 -apple-system,sans-serif;max-width:34rem;margin:40px auto;padding:0 16px">
<h1>Almost done</h1>
<p>The extension is downloaded. Now add it to Chrome:</p>
<ol>
<li>Open Google Chrome, then go to <code>chrome://extensions</code></li>
<li>Top-right: turn on <b>Developer mode</b></li>
<li>Top-left: click <b>Load unpacked</b>, press <b>Cmd+Shift+G</b>, paste the folder path (already copied), press Return, then click <b>Select</b></li>
<li>On the new card: click <b>Details</b>, then <b>Extension options</b>, and paste your tracker address and secret (find both in MailMate on the Mac -&gt; Settings -&gt; Email Tracking)</li>
</ol>
<p>Folder to select: <code>$EXT_DIR</code></p>
</body>
HTML
  open "$NEXT_STEPS" 2>/dev/null || true
fi

osascript <<APPLESCRIPT >/dev/null 2>&1 || true
display dialog "MailMate Tracking for Gmail v$REMOTE_VER is downloaded. Now add it to Chrome — 4 steps on the page that just opened (chrome://extensions):

1. Top-right: turn on  \"Developer mode\".
2. Top-left: click  \"Load unpacked\".
3. In the window that opens press  Cmd+Shift+G, then  Cmd+V (the folder path is already copied), then Return, then click  Select.
4. On the new card: click Details, then Extension options, and paste your tracker address and secret — find both in MailMate on the Mac, under Settings -> Email Tracking.

You will not need this installer again — it checks for updates on its own from here." with title "MailMate Tracking for Gmail — add it to Chrome" buttons {"OK"} default button 1
APPLESCRIPT

exit 0
