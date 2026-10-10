# Changelog

## [0.8.1](https://github.com/thomas3650/ha-claude-addon/compare/v0.8.0...v0.8.1) (2026-10-10)


### Bug Fixes

* say when a sync kept the old working folder, and keep instruction files out of the handover folder ([#21](https://github.com/thomas3650/ha-claude-addon/issues/21)) ([a069787](https://github.com/thomas3650/ha-claude-addon/commit/a069787efbfaa5a531ef87a62c153d3a32a95fb1))

## [0.8.0](https://github.com/thomas3650/ha-claude-addon/compare/v0.7.0...v0.8.0) (2026-10-10)


### Features

* log the names of the tools Home Assistant offers ([#19](https://github.com/thomas3650/ha-claude-addon/issues/19)) ([6d236b7](https://github.com/thomas3650/ha-claude-addon/commit/6d236b7af1b6587cfbc2b1be5563508972959484))

## [0.7.0](https://github.com/thomas3650/ha-claude-addon/compare/v0.6.0...v0.7.0) (2026-10-10)


### Features

* forward Home Assistant's MCP Server endpoint to Claude, with the token kept from it ([#17](https://github.com/thomas3650/ha-claude-addon/issues/17)) ([74dba80](https://github.com/thomas3650/ha-claude-addon/commit/74dba80577c0678dedbfb2ae87dcc5689f186073))

## [0.6.0](https://github.com/thomas3650/ha-claude-addon/compare/v0.5.1...v0.6.0) (2026-10-10)


### Features

* the morning command runs the briefing and starts a new chat session ([#15](https://github.com/thomas3650/ha-claude-addon/issues/15)) ([ed4f169](https://github.com/thomas3650/ha-claude-addon/commit/ed4f169961ce96b060a7c7f969d2036bcd7b22af))

## [0.5.1](https://github.com/thomas3650/ha-claude-addon/compare/v0.5.0...v0.5.1) (2026-10-10)


### Bug Fixes

* do not lose a command that arrives while the wait for input ends ([#13](https://github.com/thomas3650/ha-claude-addon/issues/13)) ([d3248f3](https://github.com/thomas3650/ha-claude-addon/commit/d3248f39247fd37e697dab4b7667e523552472b5))

## [0.5.0](https://github.com/thomas3650/ha-claude-addon/compare/v0.4.0...v0.5.0) (2026-10-10)


### Features

* delete handover files older than 30 days ([#11](https://github.com/thomas3650/ha-claude-addon/issues/11)) ([d4dfe90](https://github.com/thomas3650/ha-claude-addon/commit/d4dfe9024a188416129bf713c8d51416e4990141))

## [0.4.0](https://github.com/thomas3650/ha-claude-addon/compare/v0.3.0...v0.4.0) (2026-10-10)


### Features

* a shell link in the panel, and deploy keys that survive a one-line field ([#9](https://github.com/thomas3650/ha-claude-addon/issues/9)) ([97b103b](https://github.com/thomas3650/ha-claude-addon/commit/97b103b47ad19300f9fc9a853f798ebd7edc6721))

## [0.3.0](https://github.com/thomas3650/ha-claude-addon/compare/v0.2.1...v0.3.0) (2026-10-10)


### Features

* managed settings from the working folder, and named values for Claude Code's environment ([#7](https://github.com/thomas3650/ha-claude-addon/issues/7)) ([44242d6](https://github.com/thomas3650/ha-claude-addon/commit/44242d6ba8d20485e00166e656d9060e9fc326ca))

## [0.2.1](https://github.com/thomas3650/ha-claude-addon/compare/v0.2.0...v0.2.1) (2026-10-10)


### Bug Fixes

* log sessions started from the web terminal; document the login link and the shell ([#5](https://github.com/thomas3650/ha-claude-addon/issues/5)) ([be43ae2](https://github.com/thomas3650/ha-claude-addon/commit/be43ae2cc76946bfe3dc2e58e3ffc41dce48004a))

## [0.2.0](https://github.com/thomas3650/ha-claude-addon/compare/v0.1.0...v0.2.0) (2026-10-09)


### Features

* chat session in tmux with Remote Control, started fresh ([d868897](https://github.com/thomas3650/ha-claude-addon/commit/d8688970ec4b5c4b23e41516a7c1059f5111eebf))
* data layout and workspace sync that never loses the previous copy ([90a47da](https://github.com/thomas3650/ha-claude-addon/commit/90a47da5449f55d8bff3774495f882b64b22a5d3))
* main process, Ingress, image and manifest ([d68ee5b](https://github.com/thomas3650/ha-claude-addon/commit/d68ee5bb7991df9f91cf40a887a4bbadfcf4c74f))
* release pipeline that publishes the image before the manifest ([#3](https://github.com/thomas3650/ha-claude-addon/issues/3)) ([3638994](https://github.com/thomas3650/ha-claude-addon/commit/3638994b37c3d43c28e4aa12519423a350eea27a))
* repo skeleton, paths, logging and option reading ([2ec19ca](https://github.com/thomas3650/ha-claude-addon/commit/2ec19ca5b5d64254116c3977411bbcef57f127df))
* scrubbed environment for the Claude user and time zone fallback ([fc1dd1f](https://github.com/thomas3650/ha-claude-addon/commit/fc1dd1fd94765f745afc2e9fda42fc8bf0c0da72))
* start-up diagnostics ([21c2207](https://github.com/thomas3650/ha-claude-addon/commit/21c22075d1655215206c2400c89c14af9774c26a))
* stdin commands with a morning lock, and outcome events ([07bd4e7](https://github.com/thomas3650/ha-claude-addon/commit/07bd4e7fa8c450f1b7f339ebe088147ac668fa8f))


### Bug Fixes

* keep the token off the command line, and six start-up and status faults ([#2](https://github.com/thomas3650/ha-claude-addon/issues/2)) ([7ea57ed](https://github.com/thomas3650/ha-claude-addon/commit/7ea57ed18ce631def856d143a2c2c66ca09c8baa))
