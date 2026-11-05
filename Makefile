# Local development loop for the Firebase -> Vapor migration.
#
#   make emulators   # terminal 1: auth 9099, firestore 9002, functions 9001 (forwarders only)
#   make run-local   # terminal 2: Vapor on :8080 against the emulators
#   make harness     # terminal 3: black-box parity suite (HARNESS_ARGS=smoke for one file)

FIREBASE_DIR ?= ../show-menu-firebase
FIREBASE_PROJECT ?= show-menu-dev
HARNESS_ARGS ?=

.PHONY: build test forwarders emulators run-local harness

build:
	swift build

test:
	swift test

# `--config` is supported by firebase-tools 15.x (verified in S01; see roadmap §7).
# Runs from the firebase repo because the config's relative paths resolve there.
# The functions emulator loads forwarders/lib, which is gitignored: build it first.
forwarders:
	npm --prefix $(FIREBASE_DIR)/forwarders install --no-audit --no-fund
	npm --prefix $(FIREBASE_DIR)/forwarders run build

emulators: forwarders
	cd $(FIREBASE_DIR) && firebase emulators:start --config firebase.vapor.json --only auth,firestore,functions --project $(FIREBASE_PROJECT)

run-local:
	PORT=8080 GCP_PROJECT_ID=$(FIREBASE_PROJECT) FIRESTORE_EMULATOR_HOST=127.0.0.1:9002 FIREBASE_AUTH_EMULATOR_HOST=127.0.0.1:9099 swift run Run serve

harness:
	npm --prefix $(FIREBASE_DIR)/test-harness run test:vapor:local $(if $(HARNESS_ARGS),-- $(HARNESS_ARGS),)
