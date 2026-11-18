load helpers

# The JSON Schemas of the job files and the result (ha-claude/schemas), held
# together with the add-on's checks by example files: a valid example passes,
# an invalid one fails, and an invalid one is named <word>-<what>.json after
# the word the check gives (the result's check is run here; the job files'
# check agrees with the same examples in jobs.bats). Needs the Python
# package jsonschema: without it these tests fail, they do not skip.

SCHEMAS="$BATS_TEST_DIRNAME/../ha-claude/schemas"
VALIDATE="$BATS_TEST_DIRNAME/validate-schema.py"

valid() { python3 "$VALIDATE" "$1" "$2"; }

@test "the validator is installed" {
  python3 -c 'import jsonschema, referencing'
}

@test "every schema is itself a valid draft 2020-12 schema and has an id" {
  local f
  for f in "$SCHEMAS"/*.schema.json; do
    python3 -c 'import json,sys; from jsonschema import Draft202012Validator as V; s=json.load(open(sys.argv[1])); V.check_schema(s); assert s["$schema"].endswith("2020-12/schema"); assert s["$id"]==sys.argv[2]' \
      "$f" "$(basename "$f")"
  done
}

@test "every schema has an example of each kind, and every example sits under a schema" {
  local s
  for s in result job-chat job-repo; do
    [ -f "$SCHEMAS/$s.schema.json" ]
    [ -n "$(ls "$SCHEMAS/examples/valid/$s")" ]
    [ -n "$(ls "$SCHEMAS/examples/invalid/$s")" ]
  done
  [ -f "$SCHEMAS/job-fields.schema.json" ]
  [ "$(ls "$SCHEMAS/examples/valid" | tr '\n' ' ')" = "job-chat job-repo result " ]
  [ "$(ls "$SCHEMAS/examples/invalid" | tr '\n' ' ')" = "job-chat job-repo result " ]
}

@test "every valid example passes its schema" {
  local f s
  for f in "$SCHEMAS"/examples/valid/*/*.json; do
    s="$(basename "$(dirname "$f")")"
    run valid "$s" "$f"
    [ "$status" -eq 0 ] || { echo "valid example refused: $f: $output"; false; }
  done
}

@test "every invalid example fails its schema, and is named after a word" {
  local f s
  for f in "$SCHEMAS"/examples/invalid/*/*.json; do
    s="$(basename "$(dirname "$f")")"
    [[ "$(basename "$f")" =~ ^(shape|schedule|count|type|task|length)-[a-z0-9-]+\.json$ ]] \
      || { echo "bad name: $f"; false; }
    run valid "$s" "$f"
    [ "$status" -eq 1 ] || { echo "invalid example accepted: $f"; false; }
  done
}

@test "job-chat and job-repo take the fields of job-fields by reference" {
  grep -q 'job-fields.schema.json#/\$defs/' "$SCHEMAS/job-chat.schema.json"
  grep -q 'job-fields.schema.json#/\$defs/' "$SCHEMAS/job-repo.schema.json"
}

@test "the result examples agree with result_body, and give its word" {
  load_lib options env result
  local f w out
  for f in "$SCHEMAS"/examples/valid/result/*.json; do
    run result_body "$f"
    [ "$status" -eq 0 ] || { echo "result_body refused $f"; false; }
  done
  for f in "$SCHEMAS"/examples/invalid/result/*.json; do
    w="$(basename "$f")"; w="${w%%-*}"
    run result_body "$f"
    [ "$status" -ne 0 ] || { echo "result_body accepted $f"; false; }
    printf '%s\n' "$output" > "$BATS_TEST_TMPDIR/err"
    [ "$(_result_reason "$BATS_TEST_TMPDIR/err")" = "$w" ] \
      || { echo "$f: gave $(_result_reason "$BATS_TEST_TMPDIR/err")"; false; }
  done
}

@test "HC_SCHEMAS defaults to where the Dockerfile copies the schemas" {
  load_lib
  [ "$HC_SCHEMAS" = /usr/share/ha-claude/schemas ]
  grep -qF "COPY schemas/ $HC_SCHEMAS/" "$BATS_TEST_DIRNAME/../ha-claude/Dockerfile"
}
