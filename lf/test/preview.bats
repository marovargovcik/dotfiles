#!/usr/bin/env bats
# lf's previewer: images and PDFs through chafa, text through bat, anything
# else as file describes it.

bats_load_library bats-support
bats_load_library bats-assert

preview=$(realpath "$BATS_TEST_DIRNAME/../.config/lf/preview")

setup() {
    tmp=$BATS_TEST_TMPDIR
    mkdir "$tmp/bin"
    for tool in chafa bat pdftoppm; do
        printf '#!/bin/sh\necho %s "$@"\n' "$tool" >"$tmp/bin/$tool"
        chmod +x "$tmp/bin/$tool"
    done
    PATH=$tmp/bin:$PATH
}

@test "an image fits the preview pane" {
    printf '\x89PNG\r\n\x1a\n\0\0\0\rIHDR\0\0\0\1\0\0\0\1\x08\x06\0\0\0' >"$tmp/a.png"
    run "$preview" "$tmp/a.png" 80 24
    assert_output "chafa --size=80x24 $tmp/a.png"
}

@test "a PDF's first page, as an image" {
    printf '%%PDF-1.4\n' >"$tmp/a.pdf"
    run "$preview" "$tmp/a.pdf" 80 24
    assert_output "pdftoppm -f 1 -l 1 -r 72 -singlefile -png $tmp/a.pdf /tmp/lf-preview
chafa --size=80x24 /tmp/lf-preview.png"
}

@test "text, JSON and the like, highlighted" {
    echo hello >"$tmp/a.txt"
    echo '{"a": 1}' >"$tmp/a.json"
    run "$preview" "$tmp/a.txt" 80 24
    assert_output "bat --color=always --style=numbers --line-range=:200 $tmp/a.txt"
    run "$preview" "$tmp/a.json" 80 24
    assert_output "bat --color=always --style=numbers --line-range=:200 $tmp/a.json"
}

@test "anything else, described" {
    printf '\0\1\2\3\377' >"$tmp/a.bin"
    run "$preview" "$tmp/a.bin" 80 24
    assert_output data
}
