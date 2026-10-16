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
| `repo_url` | Optional. A git repo; the folder `repo_path` names in it becomes Claude's working folder |
| `repo_path` | Optional. The folder of that repo to use, relative to its root; `assistant` when not set. Only this folder is checked out on the device |
| `deploy_key` | A read-only SSH deploy key for that repo, without a passphrase: the private key, pasted as it is or base64-encoded on one line. The field is a single line; the add-on puts the line breaks back. Needed whenever `repo_url` is set |
| `extra_packages` | Optional. Ubuntu packages to install at start |
| `assistant_env` | Values handed to Claude Code as environment variables, one `NAME=value` per entry. Names must start with `ASSISTANT_`; any other entry is refused. Claude can read them, so nothing secret goes here. Use them for addresses that `.mcp.json` refers to as `${ASSISTANT_...}`. Read when the add-on starts. |
| `extra_mcp` | More MCP servers for Claude, one `name=upstream` per entry, for example `tools=http://my-mcp:8000/path`. A name is lowercase letters, digits and `-`; an upstream is `http` or `https` with no query string, and its path is sent as it is (an upstream without a path receives `/mcp/<name>`). The upstream's own secret path, if it has one, is its credential and stays in this option; the add-on keeps the upstream's address out of its log. Read when the add-on starts. See "Home Assistant for Claude". |
| `extra_mcp_auth` | Optional. A token for an `extra_mcp` server, one `name=token` per entry, where the name is that server's name in `extra_mcp`. The listener sends it to that server as `Authorization: Bearer <token>`; Claude never sees it. A token may hold letters, digits and `. _ ~ + / = -`, at most 2048 of them. Give a token only to an `https` server: over `http` it travels unencrypted, and the log says so. Read when the add-on starts. |
| `morning_timeout` | The longest a morning run may take, in seconds. |
| `morning_max_turns` | The most steps Claude may take in a morning run |
| `run_timeout` | The longest a run started with the `run` command may take, in seconds |
| `run_max_turns` | The most steps Claude may take in such a run |

The add-on comes with GitHub's SSH host keys, so a server that answers for
`github.com` with another key is refused. The key of any other host is
remembered the first time it is seen.

## Commands

Send one of these with Home Assistant's add-on stdin action:

| Command | Effect |
|---|---|
| `ping` | Raises the event `ha_claude_outcome` with outcome `ok` |
| `sync` | Fetches the repo again and starts a new chat session. When the fetched commit and `repo_path` are those of the last sync, the working folder is left as it is and the chat is cleared instead (see "A new conversation") |
| `restart-chat` | Ends the chat session and starts a new one |
| `clear-chat` | Starts a new conversation in the running chat session (see "A new conversation") |
| `morning` | Runs the morning briefing, then starts a new conversation that presents the summary. See below |
| `run <agent>` | Runs the agent of that name from the working folder once, without a terminal. The chat session is left alone. See "Running an agent" |
| `report`, or `report YYYY-MM` | Runs the working folder's `.claude/report` and writes what it prints to the add-on's log. See below |

Every command raises the event `ha_claude_outcome` with `command` and
`outcome` in its data. For `restart-chat` and `clear-chat` the outcome is
`ok`, or `failed` when no chat session could be started. For `sync` it is `ok` when the
working folder was renewed or no repo is configured, `kept` when the
working folder could not be renewed and the previous one stays in use, and
`failed` when no chat session could be started. After `kept`, the add-on's log and `ha-claude-status` say
why. For `report`, see below. For `run` the event also carries `agent`,
the name that was asked for, when it is a name the command accepts.

## A new conversation

A restart makes a new session in the Claude app each time. Where it can,
the add-on starts a new conversation in the running session instead: it
sends Escape, Ctrl-U and `/clear` to it, and then the opening, if there is
one. That ends a turn that is running and a line half typed in the panel,
as a restart does. It does so only when all of these hold, and restarts
otherwise:

- The working folder's managed settings (`.claude/managed-settings.json`)
  have a `SessionStart` hook. Claude Code runs it again after `/clear`, so
  it is where the working folder gives the date; the add-on then leaves out
  its own line with the date and the handover file. Without such a hook the
  date would stay that of the day the session started.
- The chat session runs, and Claude Code is what runs in it.
- The hook confirms the clear: the chat's environment holds
  `HA_CLAUDE_SESSION_MARK`, the path of a file, and the hook writes the
  conversation's source and the time in seconds to it, as `clear
  1760000000`. When that line has not come fifteen seconds after `/clear`,
  the add-on restarts.

When the managed settings set `permissions.defaultMode`, the chat starts in
that mode; otherwise it starts with `--permission-mode default`. The runs
without a terminal always do.

## The morning run

On the command `morning` the add-on runs Claude Code once, without a
terminal, as the agent `morning-briefing` from the working folder, with the
turn limit and the time limit from the options and with automatic memory off.
The run is told today's date and the path of today's handover file,
`/data/handover/YYYY-MM-DD.md`, and is expected to write that file.

A run without a terminal cannot ask for permission: a tool that the working
folder's settings do not allow is refused. Give the agent a tool list that
holds only allowed tools.

When the run has ended, the add-on starts a new conversation (see "A new
conversation"). It opens by presenting the day's summary, or by saying that
the run did not finish. The outcome is one of:

| Outcome | Meaning |
|---|---|
| `ok` | The run ended without an error and wrote today's handover file |
| `failed` | The run ended with an error, or today's handover file was not written. A run that Claude Code ends with an error is `failed` also when the file was written |
| `timeout` | The run took longer than `morning_timeout` and was stopped |
| `not_configured` | The working folder has no agent `morning-briefing`; nothing was run and the chat session was left alone |

While a run is in progress the add-on handles no other command; a command
sent in that time is handled when the run has ended. An automation that
waits for the event needs a timeout longer than `morning_timeout` plus a
minute. Nothing is retried.

The add-on's log shows that a run started, how it ended and how long it
took. What Claude printed is kept in `/data/state/morning.log`, because it
can hold what Claude read: only root can read it, which means from the host
and not from the panel, and it is left out of backups. The run keeps no
transcript.

## Running an agent

On the command `run <agent>` the add-on runs Claude Code once, without a
terminal, as the agent of that name from the working folder
(`.claude/agents/<agent>.md`), the way it runs the morning briefing: with
automatic memory off, with no transcript kept, and with the time limit
`run_timeout` and the turn limit `run_max_turns`. The chat session is not
ended or restarted.

A name is a lowercase letter followed by at most 31 lowercase letters,
digits or `-`. The two agents the add-on starts itself, `chat` and
`morning-briefing`, are refused: the chat's agent has the tools of a session
somebody is watching.

The run is told today's date and the path of its result file, and nothing
else. Its environment holds `HA_CLAUDE_UNATTENDED` with the agent's name, as
the morning run's does, so a hook in the working folder can tell a run
nobody is watching from the chat session. The chat session never has that
variable.

As in a morning run, nothing can be asked: a tool that the working folder's
settings do not allow is refused.

| Outcome | Meaning |
|---|---|
| `ok` | The run ended without an error and left a good result file |
| `failed` | The run ended with an error, or its result file is missing, older than the run or not a result. The log gives the reason in a word or two |
| `timeout` | The run took longer than `run_timeout` and was stopped |
| `not_configured` | The name is not one the command accepts, or the working folder has no such agent; nothing was run |

While a run is in progress the add-on handles no other command. What Claude
printed is kept in `/data/state/run-<agent>.log`, which only root can read
and which is left out of backups.

## The result file

An agent that runs without a terminal may leave a short result for Home
Assistant in `/data/results/<agent>.json`: one JSON object with exactly
three fields.

| Field | Holds | Limit |
|---|---|---|
| `count` | A whole number | 0 to 9999 |
| `verdict` | One line of text | 120 characters |
| `text` | Text; line feeds are kept | 4000 characters |

Before a run the add-on removes the agent's result file, so the agent
writes a new one. After the run the add-on checks the file: not older than the start of the
run, at most 32 KiB, one JSON value with these three fields and no others,
of these types and within these limits, the count written as a plain whole
number. Control characters are removed. The add-on's own process never opens
the file where it lies: the Claude user copies it, within a few seconds and
up to the size limit, to a place only root reaches, and the copy is what is
checked. A good result is raised as the event `ha_claude_result` with `agent`, `count`,
`verdict`, `text` and `time`. A file that fails a check is not raised, and
its content is never written to the log.

This is the only way text Claude wrote leaves through the add-on's own
code. What an agent
puts there is readable in Home Assistant by whatever listens for the event,
so tell the agent what may go in it. To turn the event into a sensor, use a
trigger-based template sensor on the event; to keep the text out of Home
Assistant's database, exclude the event type and that sensor from the
recorder.

A run started with `run` must leave a result to be `ok`. The morning run may
leave one as `morning-briefing.json`; it is raised when the run is `ok` and
the file is good, and the run's outcome does not depend on it.

## The report

On the command `report` the add-on runs the file `.claude/report` from the
working folder, as the Claude user, with the scrubbed environment and the
working folder as the current folder. The file is asked to stop after 30
seconds and killed 5 seconds later; an automation that waits for the event
needs a timeout of a minute. With
`report 2026-09` the month is checked (`YYYY-MM`) and passed to the file as
its only argument; any other argument is `failed` and runs nothing. The
file must be a regular file in the working folder's own `.claude` folder,
not a link, and readable and executable by the Claude user; otherwise the
outcome is `not_configured` and nothing runs.

What the file prints on standard output reaches the add-on's log, framed:

```text
[07:15:02] report: begin
[07:15:02] report: | first line
[07:15:02] report: | second line
[07:15:02] report: end, 2 lines
[07:15:02] outcome: report=ok
```

Every line of the output starts with `report: | `, so it can never look like
a line of the add-on's own. At most 200 lines are written, each cut at 200
characters; when there are more, the last line says `report: end, 200
lines, more left out`. A file that prints more than 256 KiB is stopped
there and is `failed`. Control characters are removed, empty lines are left
out. What the file prints on standard error is thrown away. A file that
ends with an error, or is stopped at the time limit (status 124), writes
nothing to the log but one line with the status, and the outcome is
`failed`.

The log is kept by Home Assistant and shown in its UI, so the file must
print nothing personal. While it runs, the output is in
`/data/state/report.out`, which only root can read and which is left out of
backups; it is removed when the command has ended. No other command is
handled while a report runs.

## Home Assistant for Claude

The add-on forwards one address to Home Assistant: the endpoint of the
integration **Model Context Protocol Server**. Inside the container it is

    http://127.0.0.1:7684/mcp

Point Claude Code at it from the working folder's `.mcp.json`, as a server of
type `http`. The add-on adds the token Home Assistant gave it; Claude never
sees the token, and the listener accepts POST to that address, and to the
addresses of `extra_mcp`, and nothing else, from inside the container only.

Through that address Claude reads and controls what you have exposed to
Assist in Home Assistant. Add the integration under Settings, Devices &
services, and review Settings, Voice assistants, Expose before you do:
every exposed entity can be controlled. Whether Claude asks before it acts
is decided by the permission rules in the working folder.

With the option `extra_mcp` the listener forwards more addresses,
`http://127.0.0.1:7684/mcp/<name>`, each to the MCP server you named. The
token Home Assistant gave the add-on is never sent to them. A server that
needs a token of its own gets it from the option `extra_mcp_auth`: the
listener adds it as the `Authorization` header, from a file only root can
read, so Claude uses the server without ever holding its token. What such a
server can reach is what you, or that token, gave it. An `https` server is
sent its own name and must show a certificate the system's authorities
vouch for; one that does not is refused.
Each gets a server of type `http` in `.mcp.json`, and its tools get rules
like any other.

The listener serves every process in the container. A shell in the panel
can use it, and so can any shell command Claude is allowed to run, without
a permission prompt for the tool: through `/mcp` with the add-on's rights
in Home Assistant, and through `/mcp/<name>` with whatever rights that
server has. Keep the shell denied for Claude in the working folder's rules,
or allow only commands that cannot reach it.

When the add-on starts it tries the address once and logs the status code
of the answer, as `proxy: Home Assistant answered NNN through the
listener`:

| Logged | Meaning |
|---|---|
| A code from 200 to 299 | It works |
| 404 | The way works; the integration is not set up |
| 401 | Home Assistant refused the token |
| 502 | Home Assistant could not be reached |
| `nothing` | No answer within fifteen seconds |

When it works, a later line lists the names of the tools Home Assistant
offers, as `proxy: Home Assistant offers these tools: ...`. A script you
have exposed is offered as a tool named after it, so that name is in the
log too. Since Home Assistant 2026.9 every tool carries the name of the
integration that offers it in front, as `intent__HassTurnOn`, and a script
is `script__<name>`. In Claude Code a
tool is called `mcp__<server>__<name>`, with the server's name from
`.mcp.json`; permission rules and an agent's tool list use that form. Each
extra server is tried the same way and logged by its name:
`proxy: <name> answered NNN through the listener` and
`proxy: <name> offers these tools: ...`. For an extra server, 404 means
its path is wrong, 502 that it is down, that its name does not resolve or,
for an `https` server, that its certificate is not one the system's
authorities vouch for, and 401 that it refused its own credential.

On a server that keeps sessions, that try opens one and does not close it:
closing is a `DELETE`, and the listener forwards nothing but a `POST`. The
server lets it run out.

## Is it working?

Run `ha-claude-status` in the panel, under the link **Shell**. It shows whether the chat
session is running, whether Claude is logged in, and when the working folder
last synced.

`claude login: yes` means only that a login has been stored. A login that
has expired or been withdrawn still shows `yes`; the **Claude** link then
shows Claude Code asking you to log in, and `/login` there does it.

## A shell in the panel

The panel has two links at the top: **Claude** shows Claude Code's session,
**Shell** opens a shell as the same user beside it, for looking at files.
Typing `exit` there ends that shell; choose the link again for a new one.

## What Claude can and cannot reach

Claude Code runs as the user `claude`. Its working folder is read-only, it
cannot read the add-on's options (except the values in `assistant_env`) or
the cloned repo, and the token Home Assistant gives the add-on is never in
its environment. The add-on maps no
Home Assistant folders and publishes no ports. Its ways to Home
Assistant, and to any server named in `extra_mcp`, are described under
"Home Assistant for Claude".

If the working folder holds a file `.claude/managed-settings.json`, the add-on
installs it as Claude Code's managed settings at start and on the `sync`
command. Managed settings rank above every other settings file, and Claude
cannot change them. A file that is not one JSON object, or that is a link, is not
installed; the last good one stays, and the log says so.

Outside its home Claude can write in two folders: the handover folder,
`/data/handover`, and the results folder, `/data/results` (see "The result
file"). Whether Claude Code lets it is for the working folder's settings to
say. Files named `YYYY-MM-DD.md` in the handover folder are deleted once
their date is more than 30 days ago. Files that Claude Code could read as
instructions or settings (`CLAUDE.md`, `CLAUDE.local.md`, `.claude`,
`.mcp.json`, in any case and at any depth) are removed from both folders
each time Claude Code is started, for the chat session, for a morning run
or for a run started with `run`. When a session or a run starts, the log says so.
Nothing else in those folders is touched.
