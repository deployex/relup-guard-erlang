.PHONY: release

# Tags the current commit as a release and pushes it.
#
# Usage: make release VERSION=1.0.0
#
# Creates an annotated tag vX.Y.Z on the current commit, then moves the
# floating major tag vX to point at the same commit - the convention
# actions/checkout, erlef/setup-beam, and most of the GitHub Actions
# ecosystem use, so a consumer pinned to @v1 picks up new v1.x.y releases
# automatically while a consumer pinned to @v1.0.0 never does. Pushes
# both tags, force-pushing the major one since it's expected to move.
release:
	@if [ -z "$(VERSION)" ]; then \
		echo "Usage: make release VERSION=X.Y.Z"; \
		exit 1; \
	fi
	@case "$(VERSION)" in \
		*.*.*) ;; \
		*) echo "VERSION must be a full semver (X.Y.Z), got: $(VERSION)"; exit 1 ;; \
	esac
	@MAJOR=$$(echo "$(VERSION)" | cut -d. -f1); \
	git tag -a "v$(VERSION)" -m "v$(VERSION)"; \
	git tag -f "v$$MAJOR" "v$(VERSION)"; \
	git push origin "v$(VERSION)"; \
	git push origin "v$$MAJOR" --force; \
	echo "Released v$(VERSION) (and moved v$$MAJOR to point at it)."
