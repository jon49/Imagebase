# Sourced by the task scripts (from the repo root): use the Goose built in
# ../goose when there is one, else whatever `goose` is on PATH. The Makefile
# reads GOOSE, and it cds into server/, so the path is made absolute.
if [ -x ../goose/build/goose ]; then
    GOOSE="$(cd ../goose/build && pwd)/goose"
    export GOOSE
fi
