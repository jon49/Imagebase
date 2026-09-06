TRAILDEPOT := traildepot
ADDRESS    ?= localhost:4000
GUEST_WASM := guests/rust/target/wasm32-wasip2/release/imagebase_guest.wasm
CARGO      ?= $(HOME)/.cargo/bin/cargo
# Object store dir, mounted read-only into the WASM guest so `GET /api/pages/...`
# can stream published HTML files back inline. Must exist before `trail` starts.
UPLOADS    := $(TRAILDEPOT)/uploads

.PHONY: build build-wasm deploy run dev clean

build: deploy

build-wasm:
	cd guests/rust && $(CARGO) build --target wasm32-wasip2 --release

deploy: build-wasm
	mkdir -p $(TRAILDEPOT)/wasm
	cp $(GUEST_WASM) $(TRAILDEPOT)/wasm/imagebase_guest.wasm

run: deploy
	mkdir -p $(UPLOADS)
	trail --data-dir=$(TRAILDEPOT) run --address=$(ADDRESS) --runtime-root-fs=$(UPLOADS)

dev: deploy
	mkdir -p $(UPLOADS)
	trail --data-dir=$(TRAILDEPOT) run --address=$(ADDRESS) --dev --stderr-logging --runtime-root-fs=$(UPLOADS)

clean:
	rm -rf guests/rust/target
	rm -rf $(TRAILDEPOT)/data $(TRAILDEPOT)/secrets $(TRAILDEPOT)/backups $(TRAILDEPOT)/uploads
	rm -f $(TRAILDEPOT)/wasm/imagebase_guest.wasm $(TRAILDEPOT)/metadata.textproto
