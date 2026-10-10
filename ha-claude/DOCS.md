# HA Claude

Runs Claude Code with Remote Control as an unprivileged user, so you can talk
to it from the Claude app. The add-on's sidebar panel shows the same session in
a web terminal.

## Install

In Home Assistant, add this repository to the add-on store:

    https://github.com/thomas3650/ha-claude-addon#release

Then install "HA Claude". The `#release` part matters: that branch only ever
points at a version whose image has been published.

## First run

1. Start the add-on and open its panel. It shows the link **Claude**.
2. Run `claude`, follow the login link, and accept the prompts it shows.
   The link is longer than one line. Copy all of it and take out the line
   breaks before opening it; a link that is cut short is answered with
   "Unknown scope".
3. Exit Claude and type `exit`. The add-on starts the chat session within a
   minute, and it appears in the Claude app under the session name.

Remote Control needs a claude.ai subscription login. API keys are not supported.

## Options

| Option | Meaning |
|---|---|
| `session_name` | The name the session has in the Claude app |
| `repo_url` | Optional. A git repo whose `assistant/` folder becomes Claude's working folder |
| `deploy_key` | A read-only SSH deploy key for that repo, without a passphrase: the private key, pasted as it is or base64-encoded on one line. The field is a single line; the add-on puts the line breaks back. Needed whenever `repo_url` is set |
| `extra_packages` | Optional. Ubuntu packages to install at start |
| `assistant_env` | Values handed to Claude Code as environment variables, one `NAME=value` per entry. Names must start with `ASSISTANT_`; any other entry is refused. Claude can read them, so nothing secret goes here. Use them for addresses that `.mcp.json` refers to as `${ASSISTANT_...}`. Read when the add-on starts. |

## Commands

Send one of these with Home Assistant's add-on stdin action:

| Command | Effect |
|---|---|
| `ping` | Raises the event `ha_claude_outcome` with outcome `ok` |
| `sync` | Fetches the repo again and starts a new chat session |
| `restart-chat` | Starts a new chat session |
| `morning` | Not implemented yet; the outcome is `not_implemented` |

Every command raises the event `ha_claude_outcome` with `command` and
`outcome` in its data.

## Is it working?

Run `ha-claude-status` in the panel, under the link **Shell**. It shows whether the chat
session is running, whether Claude is logged in, and when the working folder
last synced.

## A shell in the panel

The panel has two links at the top: **Claude** shows Claude Code's session,
**Shell** opens a shell as the same user beside it, for looking at files.
Typing `exit` there ends that shell; choose the link again for a new one.

## What Claude can and cannot reach

Claude Code runs as the user `claude`. Its working folder is read-only, it
cannot read the add-on's options (except the values in `assistant_env`) or
the cloned repo, and the token Home Assistant gives the add-on is never in
its environment. The add-on maps no
Home Assistant folders and publishes no ports.

If the working folder holds a file `.claude/managed-settings.json`, the add-on
installs it as Claude Code's managed settings at start and on the `sync`
command. Managed settings rank above every other settings file, and Claude
cannot change them. A file that is not one JSON object, or that is a link, is not
installed; the last good one stays, and the log says so.

The handover folder, `/data/handover`, is the one place outside its home
where Claude can write. Files named `YYYY-MM-DD.md` there are deleted once
their date is more than 30 days ago. Nothing else in that folder is touched.
