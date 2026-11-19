load helpers

# ha-claude-docs-mcp: the text of a document the owner uploaded in the chat.
# Driven as the chat's Claude Code drives it. The documents are made
# here with Python's zipfile; their text is made up.

SERVER="$BATS_TEST_DIRNAME/../ha-claude/rootfs/usr/local/bin/ha-claude-docs-mcp"
INIT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}'

eval "_base_setup() $(declare -f setup | tail -n +2)"
setup() {
  _base_setup
  unset HA_CLAUDE_UNATTENDED HA_CLAUDE_JOB
  export HC_UPLOADS="$BATS_TEST_TMPDIR/uploads"
  UP="$HC_UPLOADS/0eb44175-e060-4914-a34c-d178edbb9682"
  mkdir -p "$UP"
}

rpc() { printf '%s\n' "$@" | "$SERVER"; }

# read_doc <path> - the tool's text; fails on a refusal.
read_doc() {
  local out
  out="$(rpc "$INIT" "$(jq -cn --arg p "$1" \
    '{jsonrpc: "2.0", id: 2, method: "tools/call", params: {name: "read_document", arguments: {path: $p}}}')")"
  jq -r 'select(.id == 2) | .result.content[0].text' <<<"$out"
  [ "$(jq -r 'select(.id == 2) | .result.isError // false' <<<"$out")" = false ]
}

# zipped <file> <name=content>... - a zip archive with those entries.
zipped() {
  local file="$1"; shift
  python3 - "$file" "$@" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w", zipfile.ZIP_DEFLATED) as z:
    for arg in sys.argv[2:]:
        name, _, content = arg.partition("=")
        z.writestr(name, content)
PY
}

W='xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"'

@test "the server is executable in git and lists one tool" {
  [ "$(git -C "$BATS_TEST_DIRNAME/.." ls-files -s -- ha-claude/rootfs/usr/local/bin/ha-claude-docs-mcp | cut -c1-6)" = 100755 ]
  run rpc "$INIT" '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
  [ "$(jq -c 'select(.id == 2) | [.result.tools[].name]' <<<"$output")" = '["read_document"]' ]
  [ "$(jq -r 'select(.id == 1) | .result.serverInfo.name' <<<"$output")" = documents ]
}

@test "a .docx gives its paragraphs, tabs, line breaks and entities" {
  zipped "$UP/move.docx" "word/document.xml=<w:document $W><w:body><w:p><w:r><w:t>Move the</w:t></w:r><w:r><w:t xml:space=\"preserve\"> hypervisor</w:t></w:r></w:p><w:p><w:r><w:t>A</w:t><w:tab/><w:t>B &amp; C</w:t><w:br/><w:t>&#230;bler</w:t></w:r></w:p></w:body></w:document>"
  run read_doc "$UP/move.docx"
  [ "$status" -eq 0 ]
  [ "$output" = $'Move the hypervisor\nA\tB & C\næbler' ]
}

@test "an .xlsx gives each sheet by its name, cells by tabs, shared and inline strings" {
  zipped "$UP/budget.xlsx" \
    'xl/workbook.xml=<workbook><sheets><sheet name="Mad" sheetId="1"/><sheet name="Hus" sheetId="2"/></sheets></workbook>' \
    'xl/sharedStrings.xml=<sst><si><t>Brød</t></si><si><r><t>Mæl</t></r><r><t>k</t></r></si></sst>' \
    'xl/worksheets/sheet1.xml=<worksheet><sheetData><row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1"><v>25</v></c></row><row r="2"><c r="A2" t="s"><v>1</v></c><c r="B2" t="inlineStr"><is><t>ti</t></is></c></row></sheetData></worksheet>' \
    'xl/worksheets/sheet2.xml=<worksheet><sheetData><row r="1"><c r="A1"><v>1</v></c></row></sheetData></worksheet>'
  run read_doc "$UP/budget.xlsx"
  [ "$status" -eq 0 ]
  [ "$output" = $'--- Mad ---\nBrød\t25\nMælk\tti\n\n--- Hus ---\n1' ]
}

@test "a .pptx gives each slide in order, and an .odt its paragraphs" {
  zipped "$UP/talk.pptx" \
    'ppt/slides/slide2.xml=<p:sld><a:p><a:r><a:t>Second</a:t></a:r></a:p></p:sld>' \
    'ppt/slides/slide10.xml=<p:sld><a:p><a:r><a:t>Tenth</a:t></a:r></a:p></p:sld>' \
    'ppt/slides/slide1.xml=<p:sld><a:p><a:r><a:t>First</a:t></a:r></a:p><a:p><a:r><a:t>line</a:t></a:r></a:p></p:sld>'
  run read_doc "$UP/talk.pptx"
  [ "$output" = $'--- Slide 1 ---\nFirst\nline\n\n--- Slide 2 ---\nSecond\n\n--- Slide 3 ---\nTenth' ]
  zipped "$UP/note.odt" 'content.xml=<office:document-content><office:body><office:text><text:h>Title</text:h><text:p>One <text:span>two</text:span><text:tab/>three</text:p><text:p>Four</text:p></office:text></office:body></office:document-content>'
  run read_doc "$UP/note.odt"
  [ "$output" = $'Title\nOne two\tthree\nFour' ]
}

@test "a .pdf goes through pdftotext from the open file on its standard input, not by its path" {
  stub="$BATS_TEST_TMPDIR/pdftotext"
  printf '#!/bin/sh\nprintf "%%s\\n" "$@" > "%s/args"\nhead -c 8 > "%s/input"\necho "Side 1 tekst"\n' \
    "$BATS_TEST_TMPDIR" "$BATS_TEST_TMPDIR" > "$stub"
  chmod +x "$stub"
  printf '%%PDF-1.4\n' > "$UP/a.pdf"
  HC_PDFTOTEXT="$stub" run read_doc "$UP/a.pdf"
  [ "$status" -eq 0 ]
  [ "$output" = "Side 1 tekst" ]
  [ "$(tail -n 2 "$BATS_TEST_TMPDIR/args" | head -n 1)" = /dev/stdin ]
  grep -qx -- -- "$BATS_TEST_TMPDIR/args"
  ! grep -qF "$UP" "$BATS_TEST_TMPDIR/args"
  [ "$(cat "$BATS_TEST_TMPDIR/input")" = "%PDF-1.4" ]
}

@test "a real PDF's text comes through the image's pdftotext" {
  command -v pdftotext >/dev/null || skip "no pdftotext here"
  python3 - "$UP/real.pdf" <<'PY'
import sys
objs = ["<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 100] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
        None, "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"]
stream = b"BT /F1 12 Tf 10 50 Td (Hej fra PDF) Tj ET"
objs[3] = "<< /Length %d >>\nstream\n%s\nendstream" % (len(stream), stream.decode())
out = b"%PDF-1.4\n"; offs = []
for i, o in enumerate(objs):
    offs.append(len(out)); out += ("%d 0 obj\n%s\nendobj\n" % (i + 1, o)).encode()
x = len(out); out += ("xref\n0 %d\n0000000000 65535 f \n" % (len(objs) + 1)).encode()
for o in offs: out += ("%010d 00000 n \n" % o).encode()
out += ("trailer << /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (len(objs) + 1, x)).encode()
open(sys.argv[1], "wb").write(out)
PY
  run read_doc "$UP/real.pdf"
  [ "$status" -eq 0 ]
  [ "$output" = "Hej fra PDF" ]
}

@test "an office file whose parsing takes too long is refused as slow, and the server goes on" {
  python3 - "$UP/slow.docx" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w", zipfile.ZIP_DEFLATED) as z:
    z.writestr("word/document.xml", "<a" * (4 * 1024 * 1024))
PY
  zipped "$UP/ok.docx" "word/document.xml=<w:p><w:t>fine</w:t></w:p>"
  out="$(HC_PARSE_SECONDS=0.2 rpc "$INIT" \
    "$(jq -cn --arg p "$UP/slow.docx" '{jsonrpc: "2.0", id: 2, method: "tools/call", params: {name: "read_document", arguments: {path: $p}}}')" \
    "$(jq -cn --arg p "$UP/ok.docx" '{jsonrpc: "2.0", id: 3, method: "tools/call", params: {name: "read_document", arguments: {path: $p}}}')")"
  [ "$(jq -r 'select(.id == 2) | .result.content[0].text' <<<"$out")" = "slow: path" ]
  [ "$(jq -r 'select(.id == 3) | .result.content[0].text' <<<"$out")" = fine ]
}

@test "outside the uploads folder, through a link, a relative path or another kind: refused" {
  zipped "$BATS_TEST_TMPDIR/secret.docx" "word/document.xml=<w:document $W><w:body><w:p><w:r><w:t>secret</w:t></w:r></w:p></w:body></w:document>"
  run read_doc "$BATS_TEST_TMPDIR/secret.docx"
  [ "$status" -ne 0 ]; [ "$output" = "outside: path" ]
  run read_doc "$UP/../../secret.docx"
  [ "$status" -ne 0 ]; [ "$output" = "outside: path" ]
  ln -s "$BATS_TEST_TMPDIR/secret.docx" "$UP/link.docx"
  run read_doc "$UP/link.docx"
  [ "$status" -ne 0 ]; [ "$output" = "link: path" ]
  ln -s "$BATS_TEST_TMPDIR" "$HC_UPLOADS/dir"
  run read_doc "$HC_UPLOADS/dir/secret.docx"
  [ "$status" -ne 0 ]; [ "$output" = "link: path" ]
  run read_doc "uploads/x.docx"
  [ "$status" -ne 0 ]; [ "$output" = "path: path" ]
  printf 'x' > "$UP/a.txt"
  run read_doc "$UP/a.txt"
  [ "$status" -ne 0 ]; [ "$output" = "kind: path" ]
  run read_doc "$UP/missing.docx"
  [ "$status" -ne 0 ]; [ "$output" = "missing: path" ]
  mkdir "$UP/folder.docx"
  run read_doc "$UP/folder.docx"
  [ "$status" -ne 0 ]; [ "$output" = "unreadable: path" ]
}

@test "a broken archive, one that unpacks too large, and another argument: refused" {
  printf 'not a zip' > "$UP/bad.docx"
  run read_doc "$UP/bad.docx"
  [ "$status" -ne 0 ]; [ "$output" = "format: path" ]
  python3 - "$UP/bomb.docx" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w", zipfile.ZIP_DEFLATED) as z:
    z.writestr("word/document.xml", "<w:t>" + "a" * (40 * 1024 * 1024) + "</w:t>")
PY
  run read_doc "$UP/bomb.docx"
  [ "$status" -ne 0 ]; [ "$output" = "size: path" ]
  out="$(rpc "$INIT" '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"read_document","arguments":{"path":"/x","more":1}}}')"
  [ "$(jq -r 'select(.id == 2) | .result.content[0].text' <<<"$out")" = "shape: arguments" ]
}

@test "the text is cut at 200000 characters, and control characters are dropped" {
  python3 - "$UP/long.docx" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w", zipfile.ZIP_DEFLATED) as z:
    z.writestr("word/document.xml", "<w:p><w:t>\x1b[31m" + "b" * 250000 + "</w:t></w:p>")
PY
  run read_doc "$UP/long.docx"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[cut at 200000 characters]" ]]
  [[ "$output" != *$'\x1b'* ]]
}

@test "every call is refused to an unattended run, and nothing is written" {
  zipped "$UP/move.docx" "word/document.xml=<w:p><w:t>x</w:t></w:p>"
  before="$(cd "$HC_UPLOADS" && find . | sort)"
  HA_CLAUDE_UNATTENDED=job-web run read_doc "$UP/move.docx"
  [ "$status" -ne 0 ]; [ "$output" = "unattended: HA_CLAUDE_UNATTENDED" ]
  HA_CLAUDE_JOB=price run read_doc "$UP/move.docx"
  [ "$status" -ne 0 ]; [ "$output" = "unattended: HA_CLAUDE_JOB" ]
  run read_doc "$UP/move.docx"
  [ "$output" = x ]
  [ "$(cd "$HC_UPLOADS" && find . | sort)" = "$before" ]
}
