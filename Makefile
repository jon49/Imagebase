TRAILDEPOT := traildepot
ADDRESS    ?= localhost:4000

.PHONY: build build-wasm deploy run dev clean

build: deploy

build-wasm:
	cd guests/typescript && npm install && npm run build

deploy: build-wasm
	mkdir -p $(TRAILDEPOT)/wasm
	cp guests/typescript/dist/component.wasm $(TRAILDEPOT)/wasm/imagebase_guest.wasm

run: deploy
	trail --data-dir=$(TRAILDEPOT) run --address=$(ADDRESS)

dev: deploy
	trail --data-dir=$(TRAILDEPOT) run --address=$(ADDRESS) --dev --stderr-logging

clean:
	rm -rf guests/typescript/dist guests/typescript/node_modules
	rm -rf $(TRAILDEPOT)/data $(TRAILDEPOT)/secrets $(TRAILDEPOT)/backups $(TRAILDEPOT)/uploads
	rm -f $(TRAILDEPOT)/wasm/imagebase_guest.wasm $(TRAILDEPOT)/metadata.textproto
