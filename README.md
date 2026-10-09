# HA Claude add-on

A Home Assistant add-on that runs Claude Code with Remote Control as an
always-on assistant. See [the add-on documentation](ha-claude/DOCS.md).

## Development

    brew install bats-core shellcheck jq
    bats tests/
    shellcheck -x -s bash ha-claude/rootfs/usr/local/lib/ha-claude/*.sh ha-claude/rootfs/usr/local/bin/*

With Docker available:

    docker build -t ha-claude:dev ha-claude
    tests/container.sh ha-claude:dev
