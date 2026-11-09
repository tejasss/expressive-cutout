#!/usr/bin/env bash
# Versioning and release logic for the Release workflow.
#
#   release.sh --dry-run   print the next version and why; changes nothing
#   release.sh --prepare   dry-run + check signing secrets + decode keystore (CI, no JDK needed)
#   release.sh --release   bump files, changelog, build, verify signature, commit, tag, publish
#
# Environment: BUMP (auto|patch|minor|major), PUBLISH ('true' to push and publish).
set -euo pipefail

# ---- per-app settings ------------------------------------------------------------------
GRADLE_FILE="app/build.gradle.kts"
APP="expressive-cutout"
RELEASE_BRANCH="main"
APK_PATH="app/build/outputs/apk/release/app-release.apk"
AAB_PATH="app/build/outputs/bundle/release/app-release.aab"
# ----------------------------------------------------------------------------------------

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"
KEYWORDS_FILE=".github/release-keywords.conf"
MODE="${1:---dry-run}"
BUMP="${BUMP:-auto}"

die() { echo "error: $*" >&2; exit 1; }

# Print the comma-separated types configured for a bump level, one per line, lowercased.
types_for() {
  grep -iE "^[[:space:]]*$1[[:space:]]*=" "$KEYWORDS_FILE" | head -n1 | cut -d= -f2 \
    | tr ',' '\n' | tr -d ' \t' | tr '[:upper:]' '[:lower:]' | grep -v '^$' || true
}

# Succeeds when $2 is one of the lines in $1.
contains() { grep -qxF -- "$2" <<<"$1"; }

MAJOR_TYPES="$(types_for major)"
MINOR_TYPES="$(types_for minor)"
PATCH_TYPES="$(types_for patch)"

LAST_TAG="$(git describe --tags --match 'v*' --abbrev=0 2>/dev/null || true)"
if [[ -n "$LAST_TAG" ]]; then
  BASE_VERSION="${LAST_TAG#v}"
  RANGE="$LAST_TAG..HEAD"
else
  BASE_VERSION="$(sed -nE 's/^[[:space:]]*versionName = "([0-9]+\.[0-9]+\.[0-9]+).*"/\1/p' "$GRADLE_FILE" | head -n1)"
  RANGE="HEAD"
fi
[[ -n "$BASE_VERSION" ]] || die "cannot read a base version from tags or $GRADLE_FILE"

LEVEL=0                       # 0 none, 1 patch, 2 minor, 3 major
BREAKING_LINES="" FEAT_LINES="" FIX_LINES="" PERF_LINES="" REVERT_LINES=""

# Walk every commit since the last tag and note the highest bump plus changelog lines.
while IFS= read -r -d $'\x1e' record; do
  record="${record#$'\n'}"
  [[ -n "$record" ]] || continue
  subject="${record%%$'\x1f'*}"
  body="${record#*$'\x1f'}"
  [[ "$subject" =~ ^chore\(release\): ]] && continue

  type="" bang="" desc="$subject"
  if [[ "$subject" =~ ^([A-Za-z]+)(\([^\)]*\))?(!)?:[[:space:]]*(.*)$ ]]; then
    type="$(tr '[:upper:]' '[:lower:]' <<<"${BASH_REMATCH[1]}")"
    bang="${BASH_REMATCH[3]}"
    desc="${BASH_REMATCH[4]}"
  fi

  commit_level=0
  if [[ -n "$bang" ]] || grep -qE '^BREAKING[ -]CHANGE:' <<<"$body" || contains "$MAJOR_TYPES" "$type"; then
    commit_level=3; BREAKING_LINES+="- $desc"$'\n'
  elif contains "$MINOR_TYPES" "$type"; then
    commit_level=2; FEAT_LINES+="- $desc"$'\n'
  elif contains "$PATCH_TYPES" "$type"; then
    commit_level=1
    case "$type" in
      perf) PERF_LINES+="- $desc"$'\n' ;;
      revert) REVERT_LINES+="- $desc"$'\n' ;;
      *) FIX_LINES+="- $desc"$'\n' ;;
    esac
  fi
  (( commit_level > LEVEL )) && LEVEL=$commit_level
done < <(git log --format='%s%x1f%b%x1e' "$RANGE")

case "$BUMP" in
  auto) ;;
  patch) (( LEVEL < 1 )) && LEVEL=1 ;;
  minor) (( LEVEL < 2 )) && LEVEL=2 ;;
  major) LEVEL=3 ;;
  *) die "unknown bump '$BUMP'" ;;
esac

COMMIT_COUNT="$(git rev-list --count "$RANGE" 2>/dev/null || echo 0)"
if [[ "$BUMP" != "auto" && "$COMMIT_COUNT" == "0" ]]; then LEVEL=0; fi

IFS=. read -r MA MI PA <<<"$BASE_VERSION"
case "$LEVEL" in
  3) MA=$((MA + 1)); MI=0; PA=0 ;;
  2) MI=$((MI + 1)); PA=0 ;;
  1) PA=$((PA + 1)) ;;
esac
VERSION="$MA.$MI.$PA"
VERSION_CODE=$((MA * 1000000 + MI * 1000 + PA))

SHOULD_RELEASE=false
(( LEVEL > 0 )) && SHOULD_RELEASE=true

emit_outputs() {
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    { echo "should_release=$SHOULD_RELEASE"; echo "version=$VERSION"; } >> "$GITHUB_OUTPUT"
  fi
}

report_plan() {
  echo "last tag:  ${LAST_TAG:-none} (base $BASE_VERSION)"
  echo "commits:   $COMMIT_COUNT since last tag"
  if [[ "$SHOULD_RELEASE" == true ]]; then
    echo "next:      v$VERSION (versionCode $VERSION_CODE)"
  else
    echo "next:      no release (no feat/fix/perf/revert/breaking commit)"
  fi
}

# Fails early when a signing secret is empty, so no build time is wasted.
require_signing_secrets() {
  local missing=()
  [[ -n "${KEYSTORE_BASE64:-}" ]] || missing+=(KEYSTORE_BASE64)
  [[ -n "${KEYSTORE_PASSWORD:-}" ]] || missing+=(KEYSTORE_PASSWORD)
  [[ -n "${KEY_ALIAS:-}" ]] || missing+=(KEY_ALIAS)
  [[ -n "${KEY_PASSWORD:-}" ]] || missing+=(KEY_PASSWORD)
  if (( ${#missing[@]} )); then
    die "missing repository secrets: ${missing[*]}. Run scripts/setup-signing.sh first."
  fi
}

# Writes the next section of CHANGELOG.md, newest on top.
write_changelog() {
  local section="## $VERSION - $(date -u +%Y-%m-%d)"$'\n\n'
  [[ -n "$BREAKING_LINES" ]] && section+="### Breaking changes"$'\n'"$BREAKING_LINES"$'\n'
  [[ -n "$FEAT_LINES" ]] && section+="### Features"$'\n'"$FEAT_LINES"$'\n'
  [[ -n "$FIX_LINES" ]] && section+="### Fixes"$'\n'"$FIX_LINES"$'\n'
  [[ -n "$PERF_LINES" ]] && section+="### Performance"$'\n'"$PERF_LINES"$'\n'
  [[ -n "$REVERT_LINES" ]] && section+="### Reverts"$'\n'"$REVERT_LINES"$'\n'
  printf '%s' "$section" > "$RUNNER_TMP_NOTES"
  { echo "# Changelog"; echo; cat "$RUNNER_TMP_NOTES"; \
    if [[ -f CHANGELOG.md ]]; then tail -n +2 CHANGELOG.md | sed '1{/^$/d}'; fi; } > CHANGELOG.md.new
  mv CHANGELOG.md.new CHANGELOG.md
}

# Locates apksigner in the Android SDK build-tools.
find_apksigner() {
  local sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
  ls "$sdk"/build-tools/*/apksigner 2>/dev/null | sort -V | tail -n1
}

case "$MODE" in
  --dry-run)
    report_plan
    ;;

  --prepare)
    report_plan
    emit_outputs
    if [[ "$SHOULD_RELEASE" == true ]]; then
      require_signing_secrets
      KEYSTORE="${RUNNER_TEMP:-/tmp}/keystore.jks"
      echo "$KEYSTORE_BASE64" | base64 -d > "$KEYSTORE"
      if [[ -n "${GITHUB_ENV:-}" ]]; then echo "RELEASE_STORE_FILE=$KEYSTORE" >> "$GITHUB_ENV"; fi
    fi
    ;;

  --release)
    [[ "$SHOULD_RELEASE" == true ]] || { echo "nothing to release"; exit 0; }
    [[ -n "${RELEASE_STORE_FILE:-}" && -f "$RELEASE_STORE_FILE" ]] || die "no keystore: RELEASE_STORE_FILE is not set"
    report_plan
    RUNNER_TMP_NOTES="$(mktemp)"

    sed -i -E "s/^([[:space:]]*versionCode = ).*/\1$VERSION_CODE/" "$GRADLE_FILE"
    sed -i -E "s/^([[:space:]]*versionName = ).*/\1\"$VERSION\"/" "$GRADLE_FILE"
    write_changelog

    ./gradlew assembleRelease bundleRelease

    APKSIGNER="$(find_apksigner)"
    [[ -n "$APKSIGNER" ]] || die "apksigner not found in the Android SDK build-tools"
    "$APKSIGNER" verify --verbose "$APK_PATH"

    mkdir -p dist
    APK_OUT="dist/$APP-v$VERSION.apk"
    AAB_OUT="dist/$APP-v$VERSION.aab"
    cp "$APK_PATH" "$APK_OUT"
    cp "$AAB_PATH" "$AAB_OUT"
    (cd dist && sha256sum "$(basename "$APK_OUT")" "$(basename "$AAB_OUT")" > "$APP-v$VERSION.sha256")

    if [[ "${PUBLISH:-false}" != "true" ]]; then
      echo "PUBLISH is not 'true': built and verified, nothing committed or published"
      exit 0
    fi

    git config user.name "github-actions[bot]"
    git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
    git add "$GRADLE_FILE" CHANGELOG.md
    git commit -m "chore(release): $VERSION [skip ci]"
    git tag "v$VERSION"
    git push --atomic origin "HEAD:$RELEASE_BRANCH" "v$VERSION"

    gh release create "v$VERSION" "$APK_OUT" "$AAB_OUT" "dist/$APP-v$VERSION.sha256" \
      --title "v$VERSION" --notes-file "$RUNNER_TMP_NOTES"
    ;;

  *)
    die "usage: release.sh --dry-run | --prepare | --release"
    ;;
esac
