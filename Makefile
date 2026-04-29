TRAILDEPOT := traildepot
ADDRESS    ?= localhost:4000
GUEST_WASM := guests/rust/target/wasm32-wasip2/release/imagebase_guest.wasm
CARGO      ?= $(HOME)/.cargo/bin/cargo

.PHONY: build build-wasm deploy run dev clean

build: deploy

build-wasm:
	cd guests/rust && $(CARGO) build --target wasm32-wasip2 --release

deploy: build-wasm
	mkdir -p $(TRAILDEPOT)/wasm
	cp $(GUEST_WASM) $(TRAILDEPOT)/wasm/imagebase_guest.wasm

run: deploy
	trail --data-dir=$(TRAILDEPOT) run --address=$(ADDRESS)

dev: deploy
	trail --data-dir=$(TRAILDEPOT) run --address=$(ADDRESS) --dev --stderr-logging

clean:
	rm -rf guests/rust/target
	rm -rf $(TRAILDEPOT)/data $(TRAILDEPOT)/secrets $(TRAILDEPOT)/backups $(TRAILDEPOT)/uploads
	rm -f $(TRAILDEPOT)/wasm/imagebase_guest.wasm $(TRAILDEPOT)/metadata.textproto
