# ContextD — Build & Development Makefile
# Usage: make <target>
# Run `make help` to see all available targets.

PRODUCT     := ContextD
BUNDLE_ID   := com.contextd.app
BUILD_DIR   := .build
DEBUG_BIN   := $(BUILD_DIR)/debug/$(PRODUCT)
RELEASE_BIN := $(BUILD_DIR)/release/$(PRODUCT)
APP_BUNDLE  := $(BUILD_DIR)/$(PRODUCT).app
DB_PATH     := $(HOME)/Library/Application Support/ContextD/contextd.sqlite

# Colors
GREEN  := \033[0;32m
YELLOW := \033[0;33m
RED    := \033[0;31m
CYAN   := \033[0;36m
RESET  := \033[0m

.PHONY: help build release run clean resolve lint test benchmark db-shell db-stats db-recent db-search \
        db-keyframes reset-permissions reset-db logs install uninstall check-permissions watch

# ─────────────────────────────────────────
#  Help
# ─────────────────────────────────────────

help: ## Show this help
	@echo "$(CYAN)ContextD Development Commands$(RESET)"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  $(GREEN)%-22s$(RESET) %s\n", $$1, $$2}'
	@echo ""

# ─────────────────────────────────────────
#  Build
# ─────────────────────────────────────────

build: ## Build debug binary
	@echo "$(CYAN)Building debug...$(RESET)"
	@swift build 2>&1
	@echo "$(GREEN)Build complete: $(DEBUG_BIN)$(RESET)"

release: ## Build optimized release binary
	@echo "$(CYAN)Building release...$(RESET)"
	@swift build -c release 2>&1
	@echo "$(GREEN)Release build complete: $(RELEASE_BIN)$(RESET)"

resolve: ## Resolve Swift package dependencies
	@echo "$(CYAN)Resolving packages...$(RESET)"
	@swift package resolve

clean: ## Remove build artifacts
	@echo "$(YELLOW)Cleaning build directory...$(RESET)"
	@swift package clean
	@rm -rf $(BUILD_DIR)
	@echo "$(GREEN)Clean.$(RESET)"

# ─────────────────────────────────────────
#  Run
# ─────────────────────────────────────────

run: build ## Build and run (debug)
	@echo "$(CYAN)Running ContextD...$(RESET)"
	@echo "$(YELLOW)Press Ctrl+C to stop$(RESET)"
	@$(DEBUG_BIN)

run-release: release ## Build and run (release)
	@echo "$(CYAN)Running ContextD (release)...$(RESET)"
	@$(RELEASE_BIN)

# ─────────────────────────────────────────
#  Development
# ─────────────────────────────────────────

watch: ## Rebuild on file changes (requires fswatch: brew install fswatch)
	@command -v fswatch >/dev/null 2>&1 || { echo "$(RED)fswatch not found. Install with: brew install fswatch$(RESET)"; exit 1; }
	@echo "$(CYAN)Watching for changes... (Ctrl+C to stop)$(RESET)"
	@fswatch -o -r ContextD/ --include '\.swift$$' --exclude '.*' | while read -r _; do \
		echo ""; \
		echo "$(YELLOW)Change detected, rebuilding...$(RESET)"; \
		swift build 2>&1; \
		if [ $$? -eq 0 ]; then \
			echo "$(GREEN)Build succeeded$(RESET)"; \
		else \
			echo "$(RED)Build failed$(RESET)"; \
		fi; \
	done

test: ## Run unit tests
	@echo "$(CYAN)Running tests...$(RESET)"
	@swift test 2>&1
	@echo "$(GREEN)Tests complete.$(RESET)"

benchmark: ## Run ImageDiffer benchmarks (scalar vs SIMD)
	@echo "$(CYAN)Running ImageDiffer benchmarks...$(RESET)"
	@swift test --filter "ImageDifferTests/testBenchmark" 2>&1
	@echo "$(GREEN)Benchmarks complete.$(RESET)"

lint: ## Check for common issues (unused imports, formatting)
	@echo "$(CYAN)Checking for issues...$(RESET)"
	@echo "--- Unused variables ---"
	@swift build 2>&1 | grep -i "warning:" || echo "  No warnings."
	@echo ""
	@echo "--- TODO/FIXME markers ---"
	@grep -rn "TODO\|FIXME\|HACK\|XXX" ContextD/ --include="*.swift" || echo "  None found."
	@echo ""
	@echo "--- File sizes ---"
	@find ContextD -name "*.swift" -exec wc -l {} + | sort -rn | head -15

loc: ## Count lines of code
	@echo "$(CYAN)Lines of code:$(RESET)"
	@find ContextD -name "*.swift" -exec cat {} + | wc -l | xargs echo "  Total Swift lines:"
	@echo ""
	@echo "$(CYAN)By directory:$(RESET)"
	@for dir in App Capture Storage Summarization Enrichment LLMClient UI Permissions Utilities; do \
		count=$$(find ContextD/$$dir -name "*.swift" -exec cat {} + 2>/dev/null | wc -l | tr -d ' '); \
		printf "  %-20s %s lines\n" "$$dir/" "$$count"; \
	done

# ─────────────────────────────────────────
#  Database
# ─────────────────────────────────────────

db-shell: ## Open SQLite shell on the ContextD database
	@if [ -f "$(DB_PATH)" ]; then \
		echo "$(CYAN)Opening database: $(DB_PATH)$(RESET)"; \
		sqlite3 "$(DB_PATH)"; \
	else \
		echo "$(RED)Database not found at: $(DB_PATH)$(RESET)"; \
		echo "Run the app first to create the database."; \
	fi

db-stats: ## Show database statistics (row counts, size)
	@if [ -f "$(DB_PATH)" ]; then \
		echo "$(CYAN)Database: $(DB_PATH)$(RESET)"; \
		SIZE=$$(ls -lh "$(DB_PATH)" | awk '{print $$5}'); \
		echo "  Size: $$SIZE"; \
		echo ""; \
		echo "$(CYAN)Row counts:$(RESET)"; \
		sqlite3 "$(DB_PATH)" "SELECT '  captures:   ' || COUNT(*) FROM captures; \
			SELECT '  keyframes:  ' || COUNT(*) FROM captures WHERE frameType = 'keyframe'; \
			SELECT '  deltas:     ' || COUNT(*) FROM captures WHERE frameType = 'delta'; \
			SELECT '  summaries:  ' || COUNT(*) FROM summaries; \
			SELECT '  summarized: ' || COUNT(*) FROM captures WHERE isSummarized = 1;"; \
		echo ""; \
		echo "$(CYAN)Time range:$(RESET)"; \
		sqlite3 "$(DB_PATH)" "SELECT '  Oldest: ' || datetime(MIN(timestamp), 'unixepoch', 'localtime') FROM captures; \
			SELECT '  Newest: ' || datetime(MAX(timestamp), 'unixepoch', 'localtime') FROM captures;"; \
		echo ""; \
		echo "$(CYAN)Top apps:$(RESET)"; \
		sqlite3 "$(DB_PATH)" "SELECT '  ' || appName || ': ' || COUNT(*) FROM captures GROUP BY appName ORDER BY COUNT(*) DESC LIMIT 10;"; \
	else \
		echo "$(RED)Database not found. Run the app first.$(RESET)"; \
	fi

db-recent: ## Show the 10 most recent captures
	@if [ -f "$(DB_PATH)" ]; then \
		sqlite3 -header -column "$(DB_PATH)" \
			"SELECT id, datetime(timestamp, 'unixepoch', 'localtime') AS time, \
			frameType AS type, appName AS app, \
			substr(fullOcrText, 1, 80) AS text_preview \
			FROM captures ORDER BY timestamp DESC LIMIT 10;"; \
	else \
		echo "$(RED)Database not found. Run the app first.$(RESET)"; \
	fi

db-summaries: ## Show the 10 most recent summaries
	@if [ -f "$(DB_PATH)" ]; then \
		sqlite3 -header -column "$(DB_PATH)" \
			"SELECT id, \
			datetime(startTimestamp, 'unixepoch', 'localtime') AS start, \
			datetime(endTimestamp, 'unixepoch', 'localtime') AS end, \
			appNames AS apps, \
			substr(summary, 1, 100) AS summary_preview \
			FROM summaries ORDER BY endTimestamp DESC LIMIT 10;"; \
	else \
		echo "$(RED)Database not found. Run the app first.$(RESET)"; \
	fi

db-search: ## Full-text search captures (usage: make db-search Q="search term")
	@if [ -z "$(Q)" ]; then \
		echo "$(RED)Usage: make db-search Q=\"search term\"$(RESET)"; \
		exit 1; \
	fi
	@if [ -f "$(DB_PATH)" ]; then \
		echo "$(CYAN)Searching for: $(Q)$(RESET)"; \
		sqlite3 -header -column "$(DB_PATH)" \
			"SELECT captures.id, datetime(captures.timestamp, 'unixepoch', 'localtime') AS time, \
			captures.appName AS app, captures.windowTitle AS window, \
			substr(captures.fullOcrText, 1, 120) AS text_preview \
			FROM captures \
			JOIN captures_fts ON captures.id = captures_fts.rowid \
			WHERE captures_fts MATCH '\"$(Q)\"' \
			ORDER BY rank LIMIT 20;"; \
	else \
		echo "$(RED)Database not found. Run the app first.$(RESET)"; \
	fi

db-search-summaries: ## Full-text search summaries (usage: make db-search-summaries Q="search term")
	@if [ -z "$(Q)" ]; then \
		echo "$(RED)Usage: make db-search-summaries Q=\"search term\"$(RESET)"; \
		exit 1; \
	fi
	@if [ -f "$(DB_PATH)" ]; then \
		echo "$(CYAN)Searching summaries for: $(Q)$(RESET)"; \
		sqlite3 -header -column "$(DB_PATH)" \
			"SELECT summaries.id, \
			datetime(summaries.startTimestamp, 'unixepoch', 'localtime') AS start, \
			summaries.appNames AS apps, \
			substr(summaries.summary, 1, 150) AS summary_preview \
			FROM summaries \
			JOIN summaries_fts ON summaries.id = summaries_fts.rowid \
			WHERE summaries_fts MATCH '\"$(Q)\"' \
			ORDER BY rank LIMIT 20;"; \
	else \
		echo "$(RED)Database not found. Run the app first.$(RESET)"; \
	fi

db-keyframes: ## Show keyframes with delta counts
	@if [ -f "$(DB_PATH)" ]; then \
		sqlite3 -header -column "$(DB_PATH)" \
			"SELECT k.id, datetime(k.timestamp, 'unixepoch', 'localtime') AS time, \
			k.appName AS app, COUNT(d.id) AS deltas, \
			substr(k.fullOcrText, 1, 80) AS text_preview \
			FROM captures k LEFT JOIN captures d ON d.keyframeId = k.id \
			WHERE k.frameType = 'keyframe' \
			GROUP BY k.id ORDER BY k.timestamp DESC LIMIT 20;"; \
	else \
		echo "$(RED)Database not found. Run the app first.$(RESET)"; \
	fi

# ─────────────────────────────────────────
#  Permissions & Reset
# ─────────────────────────────────────────

check-permissions: ## Check if required macOS permissions are granted
	@echo "$(CYAN)Checking permissions for ContextD...$(RESET)"
	@echo ""
	@echo "Screen Recording:"
	@if sqlite3 "/Library/Application Support/com.apple.TCC/TCC.db" \
		"SELECT allowed FROM access WHERE service='kTCCServiceScreenCapture' AND client='$(BUNDLE_ID)'" 2>/dev/null | grep -q 1; then \
		echo "  $(GREEN)Granted$(RESET)"; \
	else \
		echo "  $(YELLOW)Not granted (or cannot read TCC database — this is normal)$(RESET)"; \
		echo "  Check: System Settings > Privacy & Security > Screen Recording"; \
	fi
	@echo ""
	@echo "Accessibility:"
	@if sqlite3 "/Library/Application Support/com.apple.TCC/TCC.db" \
		"SELECT allowed FROM access WHERE service='kTCCServiceAccessibility' AND client='$(BUNDLE_ID)'" 2>/dev/null | grep -q 1; then \
		echo "  $(GREEN)Granted$(RESET)"; \
	else \
		echo "  $(YELLOW)Not granted (or cannot read TCC database — this is normal)$(RESET)"; \
		echo "  Check: System Settings > Privacy & Security > Accessibility"; \
	fi

reset-permissions: ## Reset Screen Recording and Accessibility permissions (requires restart)
	@echo "$(YELLOW)Resetting permissions for $(BUNDLE_ID)...$(RESET)"
	@tccutil reset ScreenCapture $(BUNDLE_ID) 2>/dev/null || true
	@tccutil reset Accessibility $(BUNDLE_ID) 2>/dev/null || true
	@echo "$(GREEN)Permissions reset. Restart the app to re-trigger permission prompts.$(RESET)"

reset-db: ## Delete the local database (destructive!)
	@echo "$(RED)This will delete all captured data!$(RESET)"
	@read -p "Are you sure? (y/N) " confirm; \
	if [ "$$confirm" = "y" ] || [ "$$confirm" = "Y" ]; then \
		rm -f "$(DB_PATH)"; \
		rm -f "$(DB_PATH)-wal"; \
		rm -f "$(DB_PATH)-shm"; \
		echo "$(GREEN)Database deleted.$(RESET)"; \
	else \
		echo "Cancelled."; \
	fi

# ─────────────────────────────────────────
#  Logs
# ─────────────────────────────────────────

logs: ## Stream ContextD logs from unified logging (live)
	@echo "$(CYAN)Streaming logs for com.contextd.app... (Ctrl+C to stop)$(RESET)"
	@log stream --predicate 'subsystem == "com.contextd.app"' --style compact

logs-recent: ## Show recent ContextD log entries
	@echo "$(CYAN)Recent logs for com.contextd.app:$(RESET)"
	@log show --predicate 'subsystem == "com.contextd.app"' --style compact --last 5m

logs-errors: ## Show only error-level log entries
	@echo "$(RED)Error logs for com.contextd.app:$(RESET)"
	@log show --predicate 'subsystem == "com.contextd.app" AND messageType == error' --style compact --last 1h

# ─────────────────────────────────────────
#  App Bundle (for proper permissions)
# ─────────────────────────────────────────

bundle: build ## Create a .app bundle (needed for proper permission prompts)
	@echo "$(CYAN)Creating app bundle...$(RESET)"
	@mkdir -p "$(APP_BUNDLE)/Contents/MacOS"
	@mkdir -p "$(APP_BUNDLE)/Contents/Resources"
	@cp $(DEBUG_BIN) "$(APP_BUNDLE)/Contents/MacOS/$(PRODUCT)"
	@./scripts/gen-info-plist.sh > "$(APP_BUNDLE)/Contents/Info.plist"
	@echo "$(GREEN)App bundle created: $(APP_BUNDLE)$(RESET)"
	@echo "Run with: open $(APP_BUNDLE)"

run-bundle: bundle ## Build app bundle and launch it
	@echo "$(CYAN)Launching $(APP_BUNDLE)...$(RESET)"
	@open "$(APP_BUNDLE)"

# ─────────────────────────────────────────
#  Install
# ─────────────────────────────────────────

install: release ## Install release binary to /usr/local/bin
	@echo "$(CYAN)Installing to /usr/local/bin/$(PRODUCT)...$(RESET)"
	@cp $(RELEASE_BIN) /usr/local/bin/$(PRODUCT)
	@echo "$(GREEN)Installed. Run with: $(PRODUCT)$(RESET)"

uninstall: ## Remove installed binary
	@rm -f /usr/local/bin/$(PRODUCT)
	@echo "$(GREEN)Uninstalled.$(RESET)"
