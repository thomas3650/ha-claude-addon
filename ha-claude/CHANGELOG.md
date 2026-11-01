# Changelog

## [0.13.2](https://github.com/thomas3650/ha-claude-addon/compare/v0.13.1...v0.13.2) (2026-11-01)


### Bug Fixes

* a refused result file names the check that failed ([#46](https://github.com/thomas3650/ha-claude-addon/issues/46)) ([1a5fb25](https://github.com/thomas3650/ha-claude-addon/commit/1a5fb25fb2f5077e5e7860b03aedc2fd1da0e120))

## [0.13.1](https://github.com/thomas3650/ha-claude-addon/compare/v0.13.0...v0.13.1) (2026-10-16)


### Bug Fixes

* clear-chat finds Claude Code as the child of the pane's shell ([#41](https://github.com/thomas3650/ha-claude-addon/issues/41)) ([af4d075](https://github.com/thomas3650/ha-claude-addon/commit/af4d0758c5538b2ed983c5ab3dcdd30ddb610b96))
* clear-chat looks for Claude Code on the pane's terminal, at any depth ([#43](https://github.com/thomas3650/ha-claude-addon/issues/43)) ([44d42ac](https://github.com/thomas3650/ha-claude-addon/commit/44d42acd21ee406bd519d32de4897996a16cd3b4))

## [0.13.0](https://github.com/thomas3650/ha-claude-addon/compare/v0.12.2...v0.13.0) (2026-10-16)


### Features

* clear-chat, the mode and the date from the workspace's managed settings ([#39](https://github.com/thomas3650/ha-claude-addon/issues/39)) ([b7bac19](https://github.com/thomas3650/ha-claude-addon/commit/b7bac195a64b703a05d589b65638de491ce6893b))

## [0.12.2](https://github.com/thomas3650/ha-claude-addon/compare/v0.12.1...v0.12.2) (2026-10-12)


### Bug Fixes

* Claude Code 2.1.296 ([#34](https://github.com/thomas3650/ha-claude-addon/issues/34)) ([df1e289](https://github.com/thomas3650/ha-claude-addon/commit/df1e289a9b1800d1bcb190ae1ee19d933252ca8c))

## [0.12.1](https://github.com/thomas3650/ha-claude-addon/compare/v0.12.0...v0.12.1) (2026-10-12)


### Bug Fixes

* the probe's requests have their own ids; the base images and the actions are pinned ([#36](https://github.com/thomas3650/ha-claude-addon/issues/36)) ([33f5800](https://github.com/thomas3650/ha-claude-addon/commit/33f58009c7ff35595116e27952609a983a60f3f3))

## [0.12.0](https://github.com/thomas3650/ha-claude-addon/compare/v0.11.0...v0.12.0) (2026-10-12)


### Features

* a token of its own for an extra_mcp server, and https upstreams are verified ([#33](https://github.com/thomas3650/ha-claude-addon/issues/33)) ([5fea05d](https://github.com/thomas3650/ha-claude-addon/commit/5fea05d44a75935586b21e4b5a626f1fe46dead7))
* run an agent by name without a terminal, and raise its result as an event ([#31](https://github.com/thomas3650/ha-claude-addon/issues/31)) ([d417319](https://github.com/thomas3650/ha-claude-addon/commit/d4173197e21c4b88c48d4ec75f6831bcc15b70e8))

## [0.11.0](https://github.com/thomas3650/ha-claude-addon/compare/v0.10.1...v0.11.0) (2026-10-11)


### Features

* extra_mcp forwards more MCP servers through the listener ([#29](https://github.com/thomas3650/ha-claude-addon/issues/29)) ([5f2ddf2](https://github.com/thomas3650/ha-claude-addon/commit/5f2ddf2ed10854e8f6c30e8d53fafa8ba0a15c03))

## [0.10.1](https://github.com/thomas3650/ha-claude-addon/compare/v0.10.0...v0.10.1) (2026-10-11)


### Bug Fixes

* cap what the report file may print, so a flood cannot hold the main loop ([#27](https://github.com/thomas3650/ha-claude-addon/issues/27)) ([be5ac1a](https://github.com/thomas3650/ha-claude-addon/commit/be5ac1abcf657b4344646dcc7eb75c6be46b85c1))

## [0.10.0](https://github.com/thomas3650/ha-claude-addon/compare/v0.9.0...v0.10.0) (2026-10-11)


### Features

* the report command ([#25](https://github.com/thomas3650/ha-claude-addon/issues/25)) ([95e9933](https://github.com/thomas3650/ha-claude-addon/commit/95e9933db1653e884e0cefe59ecb60caa7315755))

## [0.9.0](https://github.com/thomas3650/ha-claude-addon/compare/v0.8.1...v0.9.0) (2026-10-11)


### Features

* repo_path option, and a sparse clone of that folder only ([#23](https://github.com/thomas3650/ha-claude-addon/issues/23)) ([8e609a8](https://github.com/thomas3650/ha-claude-addon/commit/8e609a8af6ad9f5ff70b98172fa0dcd3746ce3f9))

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
