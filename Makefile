DATA     ?= data
ADDRESS  ?= localhost:4000
GOOSE    ?= goose
SERVER   := server/imagebase
SOURCES  := $(wildcard server/*.goose server/*.build server/native/*.c server/native/argon2/*.[ch] \
                       server/native/argon2/blake2/*.[ch] server/migrations/*.sql)

.PHONY: build run dev test check bench clean

build: $(SERVER)

$(SERVER): $(SOURCES)
	cd server && $(GOOSE) build imagebase.goose

check:
	cd server && $(GOOSE) check imagebase.goose

run: build
	./$(SERVER) --data $(DATA) --address $(ADDRESS)

# --dev: emails are logged to stderr instead of being sent.
dev: build
	./$(SERVER) --data $(DATA) --address $(ADDRESS) --dev --access-log

test:
	./tasks/test.sh

bench: build
	./bench/run-imagebase.sh

clean:
	rm -f $(SERVER)
	rm -rf $(DATA)
