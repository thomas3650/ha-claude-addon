# HA Claude

Runs Claude Code with Remote Control as an unprivileged user, so you can talk
to it from the Claude app. The add-on's sidebar panel shows the same session in
a web terminal.

## First run

1. Start the add-on and open its panel.
2. Run `claude`, follow the login link, and accept the prompts it shows.
3. Exit Claude and type `exit`. The add-on starts the chat session within a
   minute, and it appears in the Claude app under the session name.

Remote Control needs a claude.ai subscription login. API keys are not supported.

## Options

| Option | Meaning |
|---|---|
| `session_name` | The name the session has in the Claude app |
| `repo_url` | Optional. A git repo whose `assistant/` folder becomes Claude's working folder |
| `deploy_key` | Optional. A read-only SSH deploy key for that repo, as text or base64 |
| `extra_packages` | Optional. Ubuntu packages to install at start |

## Commands

Send one of these with Home Assistant's add-on stdin action:

| Command | Effect |
|---|---|
| `ping` | Raises the event `ha_claude_outcome` with outcome `ok` |
| `sync` | Fetches the repo again and starts a new chat session |
| `restart-chat` | Starts a new chat session |

Every command raises the event `ha_claude_outcome` with `command` and
`outcome` in its data.

## What Claude can and cannot reach

Claude Code runs as the user `claude`. Its working folder is read-only, it
cannot read the add-on's options or the cloned repo, and the token Home
Assistant gives the add-on is never in its environment. The add-on maps no
Home Assistant folders and publishes no ports.
