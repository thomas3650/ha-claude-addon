#!/usr/bin/env python3
"""validate-schema.py <schema-name> <file> - exit 0 when the file is valid
against ha-claude/schemas/<schema-name>.schema.json (draft 2020-12, with
$ref to the other schemas by relative file name), 1 when it is not, 2 on
a usage error. Needs the Python package jsonschema (pip install jsonschema)."""
import json
import sys
from pathlib import Path

from jsonschema import Draft202012Validator
from referencing import Registry, Resource

SCHEMAS = Path(__file__).resolve().parent.parent / "ha-claude" / "schemas"


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    resources = []
    for p in SCHEMAS.glob("*.schema.json"):
        doc = json.loads(p.read_text())
        resources.append((p.name, Resource.from_contents(doc)))
    registry = Registry().with_resources(resources)
    schema = json.loads((SCHEMAS / f"{sys.argv[1]}.schema.json").read_text())
    Draft202012Validator.check_schema(schema)
    validator = Draft202012Validator(schema, registry=registry)
    try:
        instance = json.loads(Path(sys.argv[2]).read_text())
    except ValueError:
        return 1
    errors = list(validator.iter_errors(instance))
    for e in errors[:3]:
        print(e.message[:200], file=sys.stderr)
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
