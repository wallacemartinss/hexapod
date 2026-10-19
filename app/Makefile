# Pilot app shortcuts. `make help` lists them.
FLUTTER ?= flutter
ADB     ?= adb
APP_ID  := com.wallacemartinss.hexapod_app
APK     := build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
# Same version as the robot: last tag, commit count and git describe.
VERSION_FLAGS = $(shell ./version.sh)

.DEFAULT_GOAL := help
.PHONY: help gen brand screenshots run analyze test golden apk wait-device install crash

help: ## List the commands
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  make %-12s %s\n", $$1, $$2}'

gen: ## Generate the Dart protobuf code (proto/ -> lib/gen)
	cd ../proto && buf generate --template buf.gen.app.yaml

brand: ## Regenerate the app icon and splash from assets/brand/
	dart run flutter_launcher_icons
	dart run flutter_native_splash:create

run: ## Run on the PC (Linux), against hexsim/hexd or the robot
	$(FLUTTER) run -d linux $(VERSION_FLAGS)

analyze: ## Static analysis
	$(FLUTTER) analyze

test: ## Unit + integration tests (needs Go for hexd/hexsim)
	$(FLUTTER) test --exclude-tags golden

screenshots: ## Render every screen in every language into ../docs/screenshots/ (README)
	$(FLUTTER) test --update-goldens test/screenshots_test.dart

golden: ## Re-render the screen captures in test/goldens/
	$(FLUTTER) test --update-goldens test/pilot_screen_golden_test.dart

apk: ## Build the release APK (arm64)
	$(FLUTTER) build apk --release --split-per-abi --target-platform android-arm64 $(VERSION_FLAGS)

# Some phones (e.g. Redmi) take ~30 s to show up after the adb server starts:
# wait instead of restarting the server.
wait-device:
	@$(ADB) start-server >/dev/null 2>&1
	@echo "Esperando o celular (cabo de dados + Depuração USB)..."
	@for i in $$(seq 1 30); do \
	  st=$$($(ADB) get-state 2>/dev/null); \
	  [ "$$st" = device ] && exit 0; \
	  sleep 2; \
	done; \
	echo "Celular não apareceu. Se estiver 'unauthorized', aceite o aviso na tela dele."; \
	$(ADB) devices; exit 1

install: apk wait-device ## Build, install on the USB phone and open the app
	$(ADB) install -r $(APK)
	$(ADB) shell am start -n $(APP_ID)/.MainActivity

crash: wait-device ## Show the phone's last native/Java crash
	$(ADB) logcat -d -b crash
