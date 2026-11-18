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
| `morning_job` | Optional, no default. The name of the job file from the working folder that the `morning` command runs. See "The morning run" |
| `morning_timeout`, `morning_max_turns` | No longer used: the morning run's limits are its job file's. Kept so that a saved setting stays valid |
| `run_timeout` | The longest a run of an agent with no job file, started with the `run` command, may take, in seconds; also the limit of a job file from the working folder that sets no `timeout` |
| `run_max_turns` | The most steps Claude may take in such a run; also the limit of a job file from the working folder that sets no `max_turns` |
| `jobs_parallel` | The most runs that may be on when one of the chat's jobs starts, 1 to 10; 3 by default. A fixed job's run always starts, and counts. See "Jobs" |
| `job_timeout` | The longest a job's run may take, in seconds; 1800 by default |
| `job_max_turns` | The most steps Claude may take in a job's run; 60 by default |
| `morning_chat` | On (the default): after a run whose job file has the `after` step `clear_chat` (the morning run), the chat starts a new conversation that presents the run. Off: the chat is left alone, and Home Assistant learns how the run went from the event only |
| `chat_resume` | Off (the default): every start of the chat is a new conversation. On: the chat continues its last conversation after a `sync`, a `restart-chat` and a start of the add-on, so it is ended by `clear-chat`, `/clear` and the morning's opening. See "Keeping the conversation", which also covers the one case where a cleared conversation can come back |

The add-on comes with GitHub's SSH host keys, so a server that answers for
`github.com` with another key is refused. The key of any other host is
remembered the first time it is seen.

## Commands

Send one of these with Home Assistant's add-on stdin action:

| Command | Effect |
|---|---|
| `ping` | Raises the event `ha_claude_outcome` with outcome `ok` |
| `sync` | Fetches the repo again and starts a new chat session. When the fetched commit and `repo_path` are those of the last sync, the working folder is left as it is and the chat is cleared instead (see "A new conversation"). With `chat_resume` on, the new session continues the conversation, and a sync with nothing new leaves the chat alone (see "Keeping the conversation") |
| `restart-chat` | Ends the chat session and starts a new one; with `chat_resume` on, the new one continues the conversation |
| `clear-chat` | Starts a new conversation in the running chat session (see "A new conversation") |
| `morning` | Starts the run of the job file `morning_job` names, in the job runner, and returns at once. See "The morning run" |
| `run <name>` | For a job file from the working folder ("Fixed jobs"): starts its run in the job runner and returns at once. For any other agent: runs it once, without a terminal, and waits. The chat session is left alone. See "Running an agent" |
| `report`, or `report YYYY-MM` | Runs the working folder's `.claude/report` and writes what it prints to the add-on's log. See below |
| `memory` | Writes the chat's memory to the add-on's log. See "The memory" |
| `jobs tick` | Checks the job files and starts the jobs that are due, in the background, and returns at once. Raises no event. See "Jobs" |

Every command raises the event `ha_claude_outcome` with `command` and
`outcome` in its data. For `restart-chat` and `clear-chat` the outcome is
`ok`, or `failed` when no chat session could be started; a `clear-chat`
that had to restart instead is `ok`, and the log says so. For `sync` it is `ok` when the
working folder was renewed or no repo is configured, `kept` when the
working folder could not be renewed and the previous one stays in use, and
`failed` when no chat session could be started. After `kept`, the add-on's log and `ha-claude-status` say
why. For `report`, see below. For `run` and `morning` the event also
carries `agent`, the name that was asked for, when it is a name the command
accepts, and `by`: `command` for a run a command started, `jobs` for one
the tick started (see "Fixed jobs"). A run's event is raised when the run
has ended, not when the command arrived; a command for a run that is on
already raises `running` at once and starts nothing. A fixed job the tick
starts that did not start in its window raises `missed`, with `by` `jobs`
("Fixed jobs").

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

## Keeping the conversation

By default every start of the chat is a new conversation: after `sync`,
`restart-chat`, a start of the add-on, and when Claude Code has exited and
the add-on starts it again. With the option `chat_resume` on, those starts
continue the last conversation in the working folder instead
(`claude --continue`), so the session in the Claude app keeps what was said
and only these end it:

- `clear-chat`, and `/clear` typed in the chat;
- the end of a run whose job file clears the chat (the morning run), when
  `morning_chat` is on: its opening belongs to a new conversation, and a
  start with an opening never continues one;
- a `clear-chat` or such a run whose clear has to be a restart (see "A new
  conversation"): the restart is a new conversation too.

Claude Code saves a conversation only once it has a message. After a clear
with nothing typed since, the last saved conversation is the one before
the clear, so a restart then may bring that one back.

A `sync` that fetched something new restarts the chat, so Claude Code
reads the new instructions, and continues the conversation. A `sync` with
nothing new leaves the chat alone when Claude Code runs in it: nothing is
sent to it. A chat that does not run is started, and one left at a shell
(after three quick exits, or before the login) is restarted; both continue
the conversation.

The runs without a terminal are never continued: Claude Code skips them.
When continuing ends with an error within thirty seconds, most likely
because there was no conversation to continue, the add-on starts a new
conversation at once, and that exit does not count towards the three quick
exits after which the panel is left with a shell. A new conversation that
also ends that quickly does count. When continuing ends with an error
later, the add-on waits ten seconds as after any exit; after two such
failures in a row the next start is a new conversation. Later starts try
to continue again.

## The morning run

The command `morning` is the command `run` of the job file the option
`morning_job` names ("Fixed jobs"): it starts that run now in the job
runner and returns at once, and the outcome event is raised as `command`
`morning`, with `agent` and `by`. A run of that file that the tick starts
is raised as `morning` too. The add-on names no job itself: without the
option, or when it names no job file from the working folder, `morning`
raises `not_configured` and does nothing else.

A morning briefing, for example, is such a file with the `context` lines
`handover` and `jobs` and the `after` step `clear_chat`. With `handover`
the first message names today's handover file, `/data/handover/YYYY-MM-DD.md`,
and the run is `ok` only when it has also written that file since it
started. With `jobs` it has one line naming the chat's jobs that have a
result file, `Jobs: <name>, <name> (old), ...`, where `(old)` marks a
result from before the job's last run, or of a job that is off. Only the
names go into that line, nothing of the files' content; the agent reads the
results in `/data/results/jobs/` itself.

With `clear_chat`, when the run has ended, the add-on starts a new
conversation (see "A new conversation"). It opens by presenting the day's
summary, or by saying that the run did not finish. The runner does not do
this itself: it leaves a request, which only root can read, in
`/data/state/after/`, and the command loop carries it out within five
seconds, and then raises the outcome, so the phone hears of the run after
the briefing is in the chat. The command loop is busy while a command
runs, so a `sync` or another long command delays the chat's clearing and
the outcome until the loop is free; the run's result is raised when the
run ends, whatever the loop is doing. A request a restart left is carried
out at the next start. With the option `morning_chat` off, the chat is left alone: the
conversation in it goes on, and nothing is sent to it. The outcome is raised
either way.

## Running an agent

On the command `run <name>`, when the working folder has a job file of that
name ("Fixed jobs"), the add-on starts that run in the job runner, as the
tick does, and returns at once; the outcome is raised when the run has
ended. It runs whatever the file's `enabled` says, but not when the placed
file is not valid: then the outcome is `failed` at once. When that run is
on already, the outcome is `running` at once and nothing starts.

For any other agent the add-on runs Claude Code once, without a terminal,
as the agent of that name from the working folder
(`.claude/agents/<agent>.md`): with automatic memory off, with no
transcript kept, and with the time limit `run_timeout` and the turn limit
`run_max_turns`. The chat session is not ended or restarted. While such a
run is in progress the add-on handles no other command.

A name is a lowercase letter followed by at most 31 lowercase letters,
digits or `-`. The chat's own agent, `chat`, is refused: it has the tools of
a session somebody is watching.

The run is told today's date and the path of its result file, and nothing
else. Its environment holds `HA_CLAUDE_UNATTENDED` with the agent's name,
as every run without a terminal does, so a hook in the working folder can
tell a run nobody is watching from the chat session. The chat session never
has that variable.

Nothing can be asked: a tool that the working folder's settings do not
allow is refused. Give the agent a tool list that holds only allowed tools.

| Outcome | Meaning |
|---|---|
| `ok` | The run ended without an error and left a good result file |
| `failed` | The run ended with an error, or its result file is missing, older than the run or not a result. The log gives the reason in a word or two |
| `timeout` | The run took longer than `run_timeout` and was stopped |
| `not_configured` | The name is not one the command accepts, or the working folder has no such agent; nothing was run |

What Claude printed is kept in `/data/state/run-<agent>.log`, which only
root can read and which is left out of backups.

## The result file

An agent that runs without a terminal may leave a short result for Home
Assistant in `/data/results/<agent>.json`: one JSON object, the same form
for every run, `/usr/share/ha-claude/schemas/result.schema.json`.

| Field | Holds | Limit |
|---|---|---|
| `verdict` | One line of text | 120 characters |
| `text` | Text; line feeds are kept | 4000 characters |
| `count` | Optional. A whole number | 0 to 9999 |
| `notify` | Optional. `true` or `false`; counted only for a chat's job with a `notify` condition | |

Before a run the add-on removes the agent's result file, so the agent
writes a new one. After the run the add-on checks the file: not older than the start of the
run, at most 32 KiB, one JSON value with `verdict` and `text`, and
`count` and `notify` only besides, of these types and within these limits,
the count written as a plain whole number. Control characters are removed. The add-on's own process never opens
the file where it lies: the Claude user copies it, within a few seconds and
up to the size limit, to a place only root reaches, and the copy is what is
checked. A good result is raised as the event `ha_claude_result` with `agent`, `count`
(0 when the result has none), `verdict`, `text` and `time`. A file that fails a check is not raised, and
its content is never written to the log; the log line
`result: <agent>: <reason>` names the check:

| Reason | Meaning |
|---|---|
| `missing` | No result file |
| `stale` | The file is older than the start of the run |
| `unreadable` | The copy did not finish within a few seconds |
| `too large` | Over 32 KiB |
| `malformed (not json)` | The file is not JSON |
| `malformed (shape)` | Not one JSON object with `verdict` and `text`, and no field but `count` and `notify` besides |
| `malformed (count)` | The count is not a plain whole number from 0 to 9999 |
| `malformed (type)` | The verdict or the text is not a string |
| `malformed (length)` | The verdict or the text is over its limit |
| `malformed (other)` | The check itself could not run |

This is the only way text Claude wrote leaves through the add-on's own
code. What an agent
puts there is readable in Home Assistant by whatever listens for the event,
so tell the agent what may go in it. To turn the event into a sensor, use a
trigger-based template sensor on the event; to keep the text out of Home
Assistant's database, exclude the event type and that sensor from the
recorder.

Every run must leave a result to be `ok`. A run of a job file from the
working folder writes it here, under its agent's name, and it is raised;
a chat's job writes its own (see "Jobs"), which is not raised.

## Jobs

A job is a task for Claude on a schedule, as a file
`/data/jobs/<name>.json` that Claude writes. The name is a lowercase letter
followed by at most 31 lowercase letters, digits or `-`. Home Assistant
keeps the clock: an automation sends `jobs tick`, every 15 minutes for
example, and on each tick the add-on reads the files, checks them and
starts the jobs that are due.

| Field | Holds |
|---|---|
| `agent` | `job-private`, `job-web` or `job-all`: the agent of the working folder the job runs as |
| `task` | The task, as text, at most 4000 characters |
| `schedule` | `{"time": "HH:MM", "days": [...]}`, local time, `days` from `mon` to `sun` and every day when left out; or `{"every_hours": N}`, N from 4 to 24 |
| `end` | The last day it runs, `YYYY-MM-DD`, at most 28 days after `created` |
| `enabled` | `true` or `false` |
| `notify` | Optional. The condition, in words, under which the run sets `notify` in its result, at most 500 characters |
| `created` | The day the file was first written, `YYYY-MM-DD` |

Every job file has one format: one JSON object, with no field written twice
and no field the schemas do not name, so a file in the old form, with `type`
for the agent, is `invalid` (`shape`) and must be written again. The fields,
their types and ranges are in
`/usr/share/ha-claude/schemas/job-fields.schema.json`; a chat's job is
`job-chat.schema.json` (the fields above and no others) and a file from the
working folder is `job-repo.schema.json` ("Fixed jobs"). What a schema cannot
say (the 28 days, the 10 enabled jobs, a key written twice) is listed in the
fields schema and checked by the add-on. Who may set which field:

| Field | The chat's job | A file from the working folder |
|---|---|---|
| `agent` | one of the three | its own name |
| `task`, `schedule`, `enabled` | the chat | the repo gives them; for `run_by` `jobs` the chat's are kept after the first placing |
| `end`, `created`, `notify` | the chat | not allowed |
| `description`, `timeout`, `max_turns`, `context`, `after`, `run_by` | not allowed | the repo alone |

A file with the schema's form but a value outside its range is refused with
the check's word below. A tick reads at most 32 job files, the ones the add-on saw
first; the others are skipped, and the log says so. At most 10 jobs are enabled at once; an 11th is
`invalid`, the one the add-on saw last. The add-on reads a file only
through a copy the Claude user makes, within a few seconds and up to
16 KiB, and keeps its own record of the day it first saw each job: the
28 days count from that day too, so a `created` moved later does not
stretch them, nor does moving the file away for a while: that record is
kept until its 28 days are over. A job past its end, or seen more than 28 days ago, is moved
to `/data/jobs/ended/`.

A daily job runs once on each of its days, at the first tick after its
time; a day the add-on was off is not made up. A job every N hours runs at
the first tick N hours after its last run. The chat's jobs start while
fewer than `jobs_parallel` runs are on, the runs of fixed jobs counted;
the others start at a later tick. A run is Claude Code once, without a
terminal, from the working folder, with automatic memory off, no transcript
kept, the time limit `job_timeout` and the turn limit `job_max_turns`. The
first message comes on standard input, one form for every job: "Today is
<date>. Your result file is <path>. Do your run.", for a chat's job with
its result file `/data/results/jobs/<name>.json`, then the `notify`
condition and the task. Its environment holds `HA_CLAUDE_UNATTENDED` with
the agent's name and `HA_CLAUDE_JOB` with the job's name, for the working
folder's hooks. A chat's job does not touch the chat or the handover.

The result has the form "The result file" describes and is checked so, and
not raised as an event; `notify` is false when it is left out. Unlike
there, the last result is not removed before a run, so the agent can read
it to compare; a result older than the run's start does not count.

`sync` waits until the running jobs have ended, fixed ones included, and
none starts meanwhile, so no job runs under a working folder replaced
halfway. It waits at most the largest time limit among them plus 90
seconds. When the add-on stops, the runs are stopped; at the next start a
job that was running is `failed`.

Each job's state, which only root can read, is in
`/data/state/jobs/<name>.json`: `status` (`idle`, `running`, `ok`, `failed`,
`timeout` or `invalid`), `error` (for `invalid` the check that failed:
`shape`, `name`, `type` (the agent is not one of the three), `task`,
`schedule`, `end`, `limit` or `unreadable`; for `failed`, `agent` when the
working folder has no file for the agent, `lost` or `stopped`), `first_seen`, `last_run`, `last_end` and
`next_run` (seconds since 1970), and from the last good result `finding`
(the verdict), `text`, `notify` and `notify_rose` (`notify` went from false
to true), and for a fixed job `missed` (the last time raised as missed).
What Claude printed is kept in `/data/state/job-<name>.log`, left
out of backups.

### The job tools

`/usr/local/bin/ha-claude-jobs-mcp` is an MCP server over standard input
and output, for the chat's Claude Code inside the add-on only: it serves no
network, and runs as the Claude user, as the chat does. It has three tools:

| Tool | Input | What it does |
|---|---|---|
| `job_list` | none | Every job file in `/data/jobs/` (not `ended/`): its name, whether it is from the repo, `agent`, `schedule`, `enabled`, `end`, its `description` or the first 200 characters of its `task`, and its result file |
| `job_set` | `name`, `job` (the whole file, an object) | Checks the job with `ha-claude-job-check` and writes it whole, to `<name>.json.new` and then in its place. A new chat job has `created` today, one that is there keeps its own; the 10 enabled jobs are counted again under a lock just before the write. For a file from the working folder, only `schedule`, `enabled` and `task` may differ from the file in place, and only when it has `run_by` `jobs` |
| `job_run_now` | `name` | For a chat's job that is there and valid, not a file from the working folder: writes an empty request `/data/jobs/.requests/<name>` for the add-on |

A refusal is one line, `<word>: <field>`, the word as the check's above, or
`created`, `differs`, `run_by`, `repo`, `missing` or `busy`; never the file.
Every call is refused when `HA_CLAUDE_UNATTENDED` or `HA_CLAUDE_JOB` is set,
so a job's run cannot use it. No tool deletes a job: a job ends by
`enabled` false or its `end`.

### The jobs in Home Assistant

The add-on asks the Supervisor for the MQTT broker (the service
`mqtt:want`, which the Mosquitto add-on provides). Without a broker the
add-on works as before: the job files are checked and their state kept, the
log says once that there is no broker, and no job runs. The broker's login
is written for root only into the MQTT clients' own config files, never on a
command line.

Each job is a device entity of "HA Claude jobs", made by MQTT discovery
with retained messages under `homeassistant/<component>/ha_claude_job_<name>_<key>/config`.
In these IDs and in the entity IDs a `-` in the job's name is written `_`
(a name holds no `_`, so two jobs never share an ID); the topics under
`ha_claude/jobs/<name>/` keep the name as it is.

| Entity | Shows |
|---|---|
| `sensor.ha_claude_job_<name>_status` | The status; its attributes hold `type` (the agent without `job-`: `private`, `web` or `all`), `schedule`, `end`, `task`, `description` (the file's own text, which the view shows when the file has no `task`), `run_by`, `error` and `calls`, the last 20 tool calls from `/data/results/jobs/<name>.log.jsonl` (each its tool and its input, at most 200 characters) |
| `sensor.ha_claude_job_<name>_next_run`, `..._last_run` | Timestamps |
| `sensor.ha_claude_job_<name>_finding` | The last result's verdict; the attribute `text` holds its text |
| `binary_sensor.ha_claude_job_<name>_notify` | On when the last good result set `notify` |
| `switch.ha_claude_job_<name>_enabled` | Turns the job on or off |

The state is one retained JSON message on `ha_claude/jobs/<name>/state`,
published after every change. Text in it is cleaned of control characters.
When a job ends or its file is gone, its entities are removed with empty
retained messages; a removal the broker did not take is tried again on
every tick. At start every job is published again and the entities of jobs
whose file has gone are removed. Each publish has 10 seconds; when one fails
in a tick, the broker is taken as down for the rest of that tick and no job
starts in it, so no job runs that Home Assistant does not show.

The switch's commands arrive on `ha_claude/jobs/<name>/enabled/set`. Only
`ON` or `OFF` is taken, only for an existing job file, and `ON` only while
fewer than 10 other jobs are enabled. The add-on then changes `enabled` in
the file and nothing else, as the Claude user. Retained commands are
ignored.

### Fixed jobs

A fixed job is a file `jobs/<name>.json` in the working folder, named after
the agent it runs, for a run that belongs to the house and not to a chat.
The add-on places each one in `/data/jobs/` as a job, so Home Assistant
shows it with the same entities and switches it on and off like any job;
`run_by` in its state says what starts it, and `type` is empty. A file is a
fixed job because the working folder holds it, whatever its fields. A fixed job
is outside the limit of 10 enabled jobs and is never ended after 28 days.
A file with `run_by` `jobs` is started by the tick when it is due, in the
same runner as a chat's job; one with `run_by` `automation` (or none) only
by the commands `run <name>` and `morning`, which Home Assistant's
automations send. A due fixed run always starts: it does not wait for a
place, and it starts also without an MQTT broker; its state is published
when the broker is back. The list of its tool calls is read from
`/data/results/fixed/<name>.log.jsonl` and needs the policy flag
`jobs.fixed_log` in the working folder.

The file has these fields; a file with others, or with a `type`, an `end`,
a `created` or a `notify`, is refused (`shape`). The form is
`/usr/share/ha-claude/schemas/job-repo.schema.json`.

| Field | Value |
|---|---|
| `agent` | the file's name, and a file (not a link) `.claude/agents/<name>.md` must exist |
| `schedule` | `time` as `HH:MM` on a quarter hour, and optionally `days` (`mon` to `sun`; all days when left out); no `every_hours` |
| `enabled` | `true` or `false` |
| `task` | optional: the task, at most 4000 characters |
| `description` | optional: text for the view, at most 500 characters |
| `timeout`, `max_turns` | optional: the run's limits, at most 3600 seconds and 100 turns |
| `context` | optional: any of `handover` and `jobs` |
| `after` | optional: `clear_chat` |
| `run_by` | optional: `automation` or `jobs`; a file without it acts as `automation` |

The placed file is checked against the working folder's: every field but
`enabled` must be the same (`differs` otherwise); while the working folder's
file has `run_by` `jobs`, only `agent`, `description`, `timeout`,
`max_turns`, `context`, `after` and `run_by` must, as `schedule`, `enabled`
and `task` are then the chat's. The check's words are `shape`, `agent`,
`task`, `schedule` and `differs`.

The add-on places the files at start and after every `sync`. A file that
is missing in `/data/jobs/` is placed whole from the working folder. For a
placed file, who owns a field depends on its `run_by`: while it is
`automation` (or has none), every field but `enabled` comes from the working
folder, so an edit in `/data/jobs/` is overwritten at the next placing and
the working folder's change of schedule, task or `run_by` lands. Once it
is `jobs`, placing brings `agent`, `description`, `timeout`, `max_turns`,
`context`, `after` and `run_by` from the working folder and keeps the placed
file's `schedule`, `enabled` and `task`, which are the chat's; a later change
to the working folder's schedule then does not reach the placed file, and is
only the default for a file that is missing. `enabled` is always the
switch's choice. A file the working folder has refused is not
placed. A fixed file removed from the working folder is deleted from
`/data/jobs/` with its entities; a file in its place that is not a valid
fixed file is the chat's, and is moved to `ended/` instead. While a placed
name's agent file is missing, its placed file keeps its `enabled`. A chat job with a fixed job's name is moved
to `ended/` and the fixed job takes its place.

A fixed run is the file's `agent`, with its `timeout` and `max_turns`, or
`run_timeout` and `run_max_turns` when it sets none. Its first message is
"Today is <date>. Your result file is /data/results/<agent>.json. Do your
run.", then a line for each of its `context` lines in their order (see "The
morning run"), then its `task` as "Extra task from the owner: <task>". Its
environment holds `HA_CLAUDE_UNATTENDED` with the agent's name, and
`HA_CLAUDE_JOB` with the job's name when the working folder's
`.claude/policy.json` has `jobs.fixed_log` true. Before the run its last
result is removed. The run is `ok` when it ended without an error and left a
good result, and, with the `context` line `handover`, also today's handover
file. The result is raised as `ha_claude_result` ("The result file"), and
the outcome as `ha_claude_outcome` with `command` `morning` for the file
`morning_job` names and `run` for any other, `outcome` (`ok`, `failed` or
`timeout`), `agent` and `by` (`jobs` or `command`); with the `after` step
`clear_chat`, after the chat is cleared ("The morning run").

A fixed run sets that job's state: the status is `running` at the start,
with `last_run`, then `ok`, `failed` or `timeout`, with `finding` and `text`
(the verdict and text of this run's result; empty when an `ok` run's result
could not be kept) and `next_run` worked out again. The `Jobs:` line leaves
fixed jobs out.

A fixed file's `time` has a window: from the time until its limit
(`timeout`, or `run_timeout`) and 15 minutes later. A file with `run_by`
`jobs` is due at the first tick in its window, and only then: after the
window the run is skipped for that day, so a pause lifted, a restart or a
switch turned on later does not start it. The day is the time's own: a tick
just after midnight still starts yesterday's run at 23:45 while its window
lasts, when yesterday is one of its `days`. A run started by a command sets
`last_run` as well; the tick runs the time when `last_run` is before it, so
a command's run earlier that day does not stand in for it, and one after
the time does. `next_run` of every fixed file skips a time whose window has
passed, so it is never a time that will not start.

When the window of a file with `run_by` `jobs` ends and its run did not
start, while the job is switched on, the tick at which it ends raises
`ha_claude_outcome` with `outcome` `missed`, `command` as for its run,
`agent` and `by` `jobs`, once for that time; nothing is cleared. Only that
tick raises it: as no tick is sent while "Assistent pause" is on, a window
that ended during the pause, before the add-on started or before the switch
went on is not reported at a later tick. A run that started and was then
failed, by a restart for example, is not missed. A file with `run_by`
`automation` is never missed: its automation starts it.

When a run's `notify` goes from false to true, the add-on raises the event
`ha_claude_job_notify` with `job` and `finding`, once for that run: not
again when the next run starts or fails.

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

## The memory

Claude Code keeps a memory for each working folder in the Claude user's
home, as Markdown files in its default project memory folder,
`/data/home/.claude/projects/-data-workspace-assistant/memory/`. That
folder is not in the config share or the working folder's repo. A memory
moved elsewhere with the setting `autoMemoryDirectory` is not followed:
the command reads the default folder only. On the
command `memory` the add-on writes those files to its log, framed as the
report is:

```text
[07:15:02] memory: begin
[07:15:02] memory: | file: MEMORY.md
[07:15:02] memory: | - [The boiler](boiler.md) is serviced in May
[07:15:02] memory: | file: boiler.md
[07:15:02] memory: | ...
[07:15:02] memory: end, 4 lines
[07:15:02] outcome: memory=ok
```

Each file `*.md` comes after a line with its name. At most 2000 lines are
written, each cut at 500 characters; when there are more, the last line
says `more left out`. Control characters are removed and empty lines are
left out. The Claude user reads the files, with a time limit of 30
seconds; a link, a file with more than one name (a hard link), a pipe or
anything else that is not a plain file is passed over. The outcome is
`ok`; `empty` when there is no memory folder or no memory file in it; or
`failed` when the folder is reached through a link or is not a folder, the
folder or a file in it cannot be read, the reading took too long, or it
printed more than 1 MiB. A failed reading writes nothing of the memory to
the log, only a line that says why.

The log is kept by Home Assistant and shown in its UI, so this puts what
Claude has remembered there. Send the command only when you mean to read
it, and leave anything secret out of what Claude is asked to remember.

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
file"). In its home, `/data/home/notes` is a folder for notes Claude keeps
itself. Whether Claude Code lets it is for the working folder's settings to
say. Files named `YYYY-MM-DD.md` in the handover folder are deleted once
their date is more than 30 days ago. Files that Claude Code could read as
instructions or settings (`CLAUDE.md`, `CLAUDE.local.md`, `.claude`,
`.mcp.json`, in any case and at any depth) are removed from those folders
and from the notes folder each time Claude Code is started, for the chat
session, for a run of a job file from the working folder or for a run started with `run`. When a session or a run starts, the log says so.
Nothing else in those folders is touched.
