#!/bin/bash
set -Eeuo pipefail

# Releases are fully scripted. Prevent Git, GitHub CLI, CocoaPods, and subprocesses
# from opening a pager or editor and pausing until terminal input is provided.
export PAGER=cat
export GIT_PAGER=cat
export GH_PAGER=cat
export EDITOR=true
export VISUAL=true
export GIT_EDITOR=true
export GH_EDITOR=true

# End-to-end Digia Engage CleverTap iOS release workflow.
#
# Usage:
#   ./scripts/release.sh [flags] <version>
#   ./scripts/release.sh [flags] -v <version>
#
# Examples:
#   ./scripts/release.sh 1.0.1
#   ./scripts/release.sh --dry-run 1.0.1
#   ./scripts/release.sh --dry-run --allow-dirty --skip-pod-lint 1.0.1
#   ./scripts/release.sh --no-commit 1.0.1
#
# Flags:
#   -v, --version <ver>       Target SemVer version (e.g. 1.0.1 or 1.0.1-beta.1)
#   --dry-run                 Full simulation in a disposable clone; no real writes or publish
#   --no-commit               Bump + test + lint in real checkout, then stop before commit/push/tag/publish
#   --allow-dirty             Skip clean-tree guard (only valid with --dry-run or --no-commit)
#   --skip-tests              Skip running xcodebuild unit tests
#   --skip-pod-lint           Skip running pod lib lint (useful before core is published to trunk)
#   --skip-changelog-check    Proceed even if CHANGELOG.md has no entry for <version>
#   -b, --allow-branch <br>   Allow releasing from branch <br> instead of main
#   -h, --help                Show this help message
#
# This script performs external, irreversible actions in live mode (no --dry-run or --no-commit):
# it commits and pushes release files, tags the release commit, creates a GitHub Release,
# and publishes the pod to CocoaPods trunk.

readonly COMPONENT_NAME="Digia Engage CleverTap iOS"
readonly POD_NAME="DigiaEngageCleverTap"
readonly PODSPEC="DigiaEngageCleverTap.podspec"
readonly SCHEME_NAME="DigiaEngageCleverTap"
readonly CHANGELOG="CHANGELOG.md"

EXPECTED_BRANCH="${RELEASE_BRANCH:-main}"

# Build list of release files. CHANGELOG.md is included if it exists in the repo.
RELEASE_FILES=("$PODSPEC")
if [ -f "$CHANGELOG" ]; then
  RELEASE_FILES+=("$CHANGELOG")
fi
readonly RELEASE_FILES

VERSION=""
VERSION_REGEX=""
DRY_RUN=0
NO_COMMIT=0
ALLOW_DIRTY=0
SKIP_CHANGELOG_CHECK=0
SKIP_TESTS=0
SKIP_POD_LINT=0
TOTAL_STEPS=11
BRANCH=""
GH_REPO=""
BASE_VERSION=""
LATEST_RELEASED_TAG=""
RELEASE_COMMIT=""
RUN_DIR=""
NOTES_FILE=""
ORIGINAL_REPO_ROOT=""
VALIDATION_REPO=""
ORIGINAL_STATUS=""
ORIGINAL_HEAD=""
ORIGINAL_REFS=""
ORIGINAL_FILE_HASHES=""
ORIGINAL_INDEX_HASH=""
CURRENT_STEP="Startup"
NEXT_STEP="Fix the reported problem and rerun the release command."
FAILURE_REASON=""
STEP_NUMBER=0
REPORTING_FAILURE=0
PASSED_STEPS=()

usage() {
  cat <<'EOF'
Usage:
  ./scripts/release.sh [flags] <version>
  ./scripts/release.sh [flags] -v <version>

Examples:
  ./scripts/release.sh 1.0.1
  ./scripts/release.sh --dry-run 1.0.1
  ./scripts/release.sh --dry-run --allow-dirty --skip-pod-lint 1.0.1
  ./scripts/release.sh --no-commit 1.0.1

Flags:
  -v, --version <ver>       New SemVer version (e.g. 1.0.1 or 1.0.1-beta.1). Positional argument also accepted.
  --dry-run                 Simulate the whole release with no persistent writes
                            (runs bump, tests, and lint in a disposable clone).
  --no-commit               Bump files, run tests and lint in this checkout, then stop
                            before commit/push/tag/publish.
  --allow-dirty             Skip the clean working tree guard. Only valid together with
                            --dry-run or --no-commit; never permitted for a live release.
  --skip-tests              Skip running xcodebuild unit tests.
  --skip-pod-lint           Skip running pod lib lint (useful before core is published to trunk).
  --skip-changelog-check    Proceed even if CHANGELOG.md has no entry for <version>.
  -b, --allow-branch <br>   Allow releasing from branch <br> instead of main.
  -h, --help                Show this help message.

Before running:
  - Ensure working branch matches origin.
  - Authenticate GitHub CLI ('gh auth status') and CocoaPods trunk ('pod trunk me').
EOF
}

cleanup() {
  if [ -n "$RUN_DIR" ] && [ -d "$RUN_DIR" ]; then
    rm -rf "$RUN_DIR"
  fi
}

print_passed_steps() {
  if [ "${#PASSED_STEPS[@]}" -eq 0 ]; then
    echo "  None — stopped before the first step completed." >&2
    return
  fi

  local passed
  for passed in "${PASSED_STEPS[@]}"; do
    echo "  ✓ $passed" >&2
  done
}

on_error() {
  local status=$1
  local command=$2

  if [ "$REPORTING_FAILURE" -eq 1 ]; then
    exit "$status"
  fi
  REPORTING_FAILURE=1

  echo "" >&2
  echo "============================================================" >&2
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "DRY RUN FAILED (no release was performed)" >&2
  elif [ "$NO_COMMIT" -eq 1 ]; then
    echo "NO-COMMIT VALIDATION FAILED (no release was performed)" >&2
  else
    echo "RELEASE FAILED" >&2
  fi
  echo "Step: $CURRENT_STEP" >&2
  if [ -n "$FAILURE_REASON" ]; then
    echo "Why: $FAILURE_REASON" >&2
  else
    echo "Why: command exited with status $status: $command" >&2
  fi
  echo "" >&2
  echo "Steps that passed:" >&2
  print_passed_steps
  echo "" >&2
  echo "Suggested next step:" >&2
  echo "  $NEXT_STEP" >&2
  echo "============================================================" >&2
  exit "$status"
}

on_signal() {
  FAILURE_REASON="The release was interrupted by a signal."
  on_error 130 "signal"
}

trap cleanup EXIT
trap 'on_error "$?" "$BASH_COMMAND"' ERR
trap on_signal INT TERM

fail() {
  FAILURE_REASON=$1
  return 1
}

require_live_mode() {
  local operation=$1
  [ "$DRY_RUN" -eq 0 ] || fail "Internal safety guard blocked '$operation' because --dry-run is active."
  [ "$NO_COMMIT" -eq 0 ] || fail "Internal safety guard blocked '$operation' because --no-commit is active."
}

run_step() {
  local label=$1
  local next_step=$2
  local success_reason=$3
  shift 3

  STEP_NUMBER=$((STEP_NUMBER + 1))
  CURRENT_STEP="$label"
  NEXT_STEP="$next_step"
  FAILURE_REASON=""

  echo ""
  echo "[$STEP_NUMBER/$TOTAL_STEPS] $label"
  "$@"
  PASSED_STEPS+=("$label — $success_reason")
  echo "✓ Passed: $success_reason"
}

validate_semver() {
  local version=$1
  local core prerelease major minor patch extra identifier
  local -a identifiers=()

  if [[ "$version" == *+* ]]; then
    return 1
  fi

  core=${version%%-*}
  if [[ "$version" == *-* ]]; then
    prerelease=${version#*-}
  else
    prerelease=""
  fi

  IFS='.' read -r major minor patch extra <<< "$core"
  if [ -n "${extra:-}" ] || [ -z "${major:-}" ] || [ -z "${minor:-}" ] || [ -z "${patch:-}" ]; then
    return 1
  fi

  for identifier in "$major" "$minor" "$patch"; do
    if ! [[ "$identifier" =~ ^(0|[1-9][0-9]*)$ ]]; then
      return 1
    fi
  done

  if [[ "$version" == *-* ]]; then
    if [ -z "$prerelease" ]; then
      return 1
    fi
    IFS='.' read -ra identifiers <<< "$prerelease"
    for identifier in "${identifiers[@]}"; do
      if ! [[ "$identifier" =~ ^[0-9A-Za-z-]+$ ]]; then
        return 1
      fi
      if [[ "$identifier" =~ ^[0-9]+$ ]] && [[ "$identifier" =~ ^0[0-9]+$ ]]; then
        return 1
      fi
    done
  fi

  return 0
}

semver_is_greater() {
  local candidate=$1
  local current=$2
  local candidate_core current_core candidate_pre current_pre
  local candidate_major candidate_minor candidate_patch
  local current_major current_minor current_patch
  local candidate_id current_id
  local index max
  local -a candidate_ids=() current_ids=()

  candidate_core=${candidate%%-*}
  current_core=${current%%-*}
  if [[ "$candidate" == *-* ]]; then candidate_pre=${candidate#*-}; else candidate_pre=""; fi
  if [[ "$current" == *-* ]]; then current_pre=${current#*-}; else current_pre=""; fi

  IFS='.' read -r candidate_major candidate_minor candidate_patch <<< "$candidate_core"
  IFS='.' read -r current_major current_minor current_patch <<< "$current_core"

  if ((10#$candidate_major != 10#$current_major)); then
    ((10#$candidate_major > 10#$current_major))
    return
  fi
  if ((10#$candidate_minor != 10#$current_minor)); then
    ((10#$candidate_minor > 10#$current_minor))
    return
  fi
  if ((10#$candidate_patch != 10#$current_patch)); then
    ((10#$candidate_patch > 10#$current_patch))
    return
  fi

  if [ -z "$candidate_pre" ] && [ -n "$current_pre" ]; then return 0; fi
  if [ -n "$candidate_pre" ] && [ -z "$current_pre" ]; then return 1; fi
  if [ -z "$candidate_pre" ] && [ -z "$current_pre" ]; then return 1; fi

  IFS='.' read -ra candidate_ids <<< "$candidate_pre"
  IFS='.' read -ra current_ids <<< "$current_pre"
  max=${#candidate_ids[@]}
  if [ "${#current_ids[@]}" -gt "$max" ]; then max=${#current_ids[@]}; fi

  for ((index = 0; index < max; index++)); do
    if [ "$index" -ge "${#candidate_ids[@]}" ]; then return 1; fi
    if [ "$index" -ge "${#current_ids[@]}" ]; then return 0; fi
    candidate_id=${candidate_ids[$index]}
    current_id=${current_ids[$index]}
    if [ "$candidate_id" = "$current_id" ]; then continue; fi

    if [[ "$candidate_id" =~ ^[0-9]+$ ]] && [[ "$current_id" =~ ^[0-9]+$ ]]; then
      ((10#$candidate_id > 10#$current_id))
      return
    fi
    if [[ "$candidate_id" =~ ^[0-9]+$ ]]; then return 1; fi
    if [[ "$current_id" =~ ^[0-9]+$ ]]; then return 0; fi
    (
      export LC_ALL=C
      [[ "$candidate_id" > "$current_id" ]]
    )
    return
  done

  return 1
}

greatest_semver_tag() {
  local ls_remote_output=$1
  local object_id ref tag latest=""

  while IFS=$'\t' read -r object_id ref; do
    [ -n "${object_id:-}" ] && [ -n "${ref:-}" ] || continue
    tag=${ref#refs/tags/}
    validate_semver "$tag" || continue
    if [ -z "$latest" ] || semver_is_greater "$tag" "$latest"; then
      latest=$tag
    fi
  done <<< "$ls_remote_output"

  printf '%s\n' "$latest"
}

extract_podspec_version() {
  sed -nE "s/^[[:space:]]*s[.]version[[:space:]]*=[[:space:]]*['\"]([^'\"]+)['\"][[:space:]]*$/\1/p" "$1"
}

extract_top_changelog_version() {
  sed -nE 's/^## \[([^]]+)\].*/\1/p' "$1" | sed -n '1p'
}

extract_latest_released_changelog_version() {
  sed -nE 's/^## \[([0-9]+[.][0-9]+[.][0-9]+(-[0-9A-Za-z.-]+)?)\].*/\1/p' "$1" | sed -n '1p'
}

is_release_file() {
  local path=$1
  case "$path" in
    "$PODSPEC"|"$CHANGELOG") return 0 ;;
    *) return 1 ;;
  esac
}

is_allowed_generated_path() {
  local path=$1
  case "$path" in
    .build/*|.swiftpm/*|Package.resolved) return 0 ;;
    *) return 1 ;;
  esac
}

resolve_test_destination() {
  if [ -n "${TEST_DESTINATION:-}" ]; then
    printf '%s\n' "$TEST_DESTINATION"
    return 0
  fi

  local booted_id
  booted_id=$(xcrun simctl list devices booted -j 2>/dev/null | ruby -rjson -e '
    devices = JSON.parse(STDIN.read)["devices"] rescue {}
    booted = devices.values.flatten.find { |d| d["state"] == "Booted" && d["isAvailable"] }
    puts booted["udid"] if booted
  ' 2>/dev/null || true)
  if [ -n "$booted_id" ]; then
    printf 'id=%s\n' "$booted_id"
    return 0
  fi

  local available_name
  available_name=$(xcrun simctl list devices available -j 2>/dev/null | ruby -rjson -e '
    devices = JSON.parse(STDIN.read)["devices"] rescue {}
    sim = devices.values.flatten.find { |d| d["isAvailable"] && d["name"] =~ /iPhone/ }
    puts sim["name"] if sim
  ' 2>/dev/null || true)
  if [ -n "$available_name" ]; then
    printf 'platform=iOS Simulator,name=%s\n' "$available_name"
    return 0
  fi

  printf 'generic/platform=iOS Simulator\n'
}

assert_no_unrelated_changes() {
  local path

  while IFS= read -r path; do
    [ -z "$path" ] && continue
    if ! is_release_file "$path"; then
      fail "Tracked change '$path' is outside the release files. Commit, stash, or restore it first."
    fi
  done < <(git diff --name-only HEAD --)

  while IFS= read -r path; do
    [ -z "$path" ] && continue
    if ! is_release_file "$path"; then
      fail "Staged change '$path' would contaminate the release commit. Commit or unstage it first."
    fi
  done < <(git diff --cached --name-only --)

  while IFS= read -r path; do
    [ -z "$path" ] && continue
    if ! is_allowed_generated_path "$path"; then
      fail "Untracked path '$path' could affect the build. Commit, move, or remove it first."
    fi
  done < <(git ls-files --others --exclude-standard)

  for path in "${RELEASE_FILES[@]}"; do
    [ -f "$path" ] || fail "Required release file '$path' is missing or is not a regular file."
  done

  git diff --check HEAD -- "${RELEASE_FILES[@]}"
}

assert_exact_release_changes() {
  local path
  local -a changed=()

  while IFS= read -r path; do
    [ -z "$path" ] || changed+=("$path")
  done < <(git diff --name-only HEAD --)

  if [ "${#changed[@]}" -eq 0 ]; then
    fail "Expected release files to be updated; no tracked changes found."
  fi

  for path in "${changed[@]}"; do
    is_release_file "$path" || fail "Unexpected tracked change '$path' appeared during the release."
  done

  if git diff --quiet HEAD -- "$PODSPEC"; then
    fail "Release file '$PODSPEC' is unchanged from HEAD."
  fi

  git diff --check HEAD -- "${RELEASE_FILES[@]}"
}

assert_paths_are_exact_release_files() {
  local description=$1
  shift
  local path
  local -a paths=("$@")

  if [ "${#paths[@]}" -eq 0 ]; then
    fail "$description contains 0 files."
  fi
  for path in "${paths[@]}"; do
    is_release_file "$path" || fail "$description contains unauthorized file '$path'."
  done
}

capture_original_state() {
  local index_path

  ORIGINAL_STATUS=$(git status --porcelain=v2 --untracked-files=all)
  ORIGINAL_HEAD=$(git rev-parse HEAD)
  ORIGINAL_REFS=$(git show-ref || true)
  ORIGINAL_FILE_HASHES=$(shasum -a 256 "${RELEASE_FILES[@]}")
  index_path=$(git rev-parse --git-path index)
  [ -f "$index_path" ] || fail "Could not locate the real checkout's git index for dry-run protection."
  ORIGINAL_INDEX_HASH=$(shasum -a 256 "$index_path" | awk '{print $1}')
}

prepare_dry_run_clone() {
  local path

  VALIDATION_REPO="$RUN_DIR/repository"
  git clone --quiet --no-local "$ORIGINAL_REPO_ROOT" "$VALIDATION_REPO"

  # Crucial: Symlink core so that Package.swift relative dependency `../core` resolves!
  if [ -d "$ORIGINAL_REPO_ROOT/../core" ]; then
    ln -s "$ORIGINAL_REPO_ROOT/../core" "$RUN_DIR/core"
  fi

  for path in "${RELEASE_FILES[@]}"; do
    mkdir -p "$VALIDATION_REPO/$(dirname "$path")"
    cp -p "$ORIGINAL_REPO_ROOT/$path" "$VALIDATION_REPO/$path"
  done

  cd "$VALIDATION_REPO"
  [ "$(git rev-parse HEAD)" = "$ORIGINAL_HEAD" ] || fail "Temporary validation clone does not match the real checkout's HEAD."
}

verify_dry_run_non_mutation() {
  local current_status current_head current_refs current_hashes current_index_hash index_path

  assert_exact_release_changes
  git diff --cached --quiet -- || fail "Dry-run unexpectedly staged files inside the temporary clone."
  [ -s "$NOTES_FILE" ] || fail "Dry-run release notes were not generated."

  cd "$ORIGINAL_REPO_ROOT"
  current_status=$(git status --porcelain=v2 --untracked-files=all)
  current_head=$(git rev-parse HEAD)
  current_refs=$(git show-ref || true)
  current_hashes=$(shasum -a 256 "${RELEASE_FILES[@]}")
  index_path=$(git rev-parse --git-path index)
  current_index_hash=$(shasum -a 256 "$index_path" | awk '{print $1}')

  [ "$current_status" = "$ORIGINAL_STATUS" ] || fail "Dry-run changed the real checkout's worktree status."
  [ "$current_head" = "$ORIGINAL_HEAD" ] || fail "Dry-run changed the real checkout's HEAD."
  [ "$current_refs" = "$ORIGINAL_REFS" ] || fail "Dry-run changed git refs in the real checkout."
  [ "$current_hashes" = "$ORIGINAL_FILE_HASHES" ] || fail "Dry-run changed one of the real release files."
  [ "$current_index_hash" = "$ORIGINAL_INDEX_HASH" ] || fail "Dry-run changed the real checkout's git index."
}

validate_preflight() {
  local command path remote_head remote_tags origin_url repo_hint pod_info
  local base_pod base_changelog top_changelog
  local -a required_commands=(
    awk cat cp curl dirname env find gh git grep head ln mkdir mktemp pod rm
    ruby sed shasum swift tail true xcodebuild
  )

  for command in "${required_commands[@]}"; do
    command -v "$command" >/dev/null 2>&1 || fail "Required command '$command' is not installed or not on PATH."
  done

  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || fail "This is not a git worktree."
  BRANCH=$(git branch --show-current)
  [ "$BRANCH" = "$EXPECTED_BRANCH" ] || fail "Releases must run from '$EXPECTED_BRANCH'; current branch is '${BRANCH:-detached HEAD}'. Use -b/--allow-branch to override."

  origin_url=$(git remote get-url origin) || fail "Git remote 'origin' is not configured."
  git var GIT_AUTHOR_IDENT >/dev/null 2>&1 || fail "Git author identity is not configured."
  git var GIT_COMMITTER_IDENT >/dev/null 2>&1 || fail "Git committer identity is not configured."

  for path in MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD rebase-merge rebase-apply; do
    if [ -e "$(git rev-parse --git-path "$path")" ]; then
      fail "A git operation is in progress ($path). Finish or abort it before releasing."
    fi
  done

  if [ "$ALLOW_DIRTY" -eq 1 ]; then
    echo "    ⚠️  --allow-dirty: Skipping clean working tree check."
  else
    assert_no_unrelated_changes
  fi

  git show "HEAD:$PODSPEC" > "$RUN_DIR/head-podspec"
  base_pod=$(extract_podspec_version "$RUN_DIR/head-podspec")
  [ -n "$base_pod" ] || fail "Could not read podspec version from HEAD:$PODSPEC."
  BASE_VERSION=$base_pod
  validate_semver "$BASE_VERSION" || fail "Current version '$BASE_VERSION' in HEAD is not valid semantic versioning."

  if [ "$VERSION" != "$BASE_VERSION" ]; then
    semver_is_greater "$VERSION" "$BASE_VERSION" || fail "New version $VERSION must be greater than current HEAD version $BASE_VERSION."
  fi

  if [ -f "$CHANGELOG" ]; then
    if git cat-file -e "HEAD:$CHANGELOG" 2>/dev/null; then
      git show "HEAD:$CHANGELOG" > "$RUN_DIR/head-changelog"
      base_changelog=$(extract_latest_released_changelog_version "$RUN_DIR/head-changelog")
      if [ -n "$base_changelog" ] && [ "$base_changelog" != "$BASE_VERSION" ]; then
        fail "HEAD versions are inconsistent: podspec=$BASE_VERSION, latest released changelog=$base_changelog."
      fi
      if grep -Eq "^## \\[$VERSION_REGEX\\]([[:space:]]|$)" "$RUN_DIR/head-changelog"; then
        fail "Version $VERSION already exists in the committed changelog."
      fi
    fi

    top_changelog=$(extract_top_changelog_version "$CHANGELOG")
    case "$top_changelog" in
      Unreleased|"$VERSION")
        ;;
      *)
        if [ "$SKIP_CHANGELOG_CHECK" -eq 1 ]; then
          echo "    ⚠️  --skip-changelog-check: CHANGELOG.md has no [$VERSION] entry — proceeding anyway." >&2
        else
          fail "Top changelog section is [$top_changelog]; expected [Unreleased] or [$VERSION]. Rerun with --skip-changelog-check to bypass."
        fi
        ;;
    esac
  else
    echo "    Note: $CHANGELOG does not exist in this repository; skipping changelog check."
  fi

  if git show-ref --verify --quiet "refs/tags/$VERSION"; then
    fail "Local git tag $VERSION already exists."
  fi

  if [ "$DRY_RUN" -eq 0 ]; then
    git fetch --quiet origin "$BRANCH"
    remote_head=$(git ls-remote origin "refs/heads/$BRANCH" | awk '{print $1}')
    [ -n "$remote_head" ] || fail "Could not resolve origin/$BRANCH after fetching."
    [ "$(git rev-parse HEAD)" = "$remote_head" ] || fail "Local $BRANCH does not match origin/$BRANCH. Pull/push pending commits before releasing."
  fi

  remote_tags=$(git ls-remote --tags --refs origin)
  LATEST_RELEASED_TAG=$(greatest_semver_tag "$remote_tags")
  if [ -n "$LATEST_RELEASED_TAG" ]; then
    echo "    Latest released SemVer tag: $LATEST_RELEASED_TAG"
    semver_is_greater "$VERSION" "$LATEST_RELEASED_TAG" \
      || fail "New version $VERSION must be greater than latest released tag $LATEST_RELEASED_TAG."
  else
    echo "    No existing SemVer tags found on origin."
  fi

  remote_tag=$(git ls-remote --tags origin "refs/tags/$VERSION")
  [ -z "$remote_tag" ] || fail "Remote git tag $VERSION already exists."

  gh auth status >/dev/null 2>&1 || fail "GitHub CLI is not authenticated. Run 'gh auth login' and retry."
  repo_hint=$(printf '%s\n' "$origin_url" | sed -E 's#^(git@[^:]+:|ssh://git@[^/]+/|https?://[^/]+/)##; s#[.]git$##')
  [[ "$repo_hint" == */* ]] || fail "Could not derive a GitHub OWNER/REPO from origin URL '$origin_url'."
  GH_REPO=$(gh repo view "$repo_hint" --json nameWithOwner --jq '.nameWithOwner')
  [ -n "$GH_REPO" ] || fail "Could not resolve the GitHub repository from the current checkout."
  if gh release view "$VERSION" --repo "$GH_REPO" >/dev/null 2>&1; then
    fail "GitHub Release $VERSION already exists in $GH_REPO."
  fi

  if [ "$SKIP_POD_LINT" -eq 0 ]; then
    if ! pod trunk me > "$RUN_DIR/pod-trunk-me.out" 2>&1; then
      fail "CocoaPods trunk is not authenticated. Run: pod trunk register engg@digia.tech 'Digia Engineering'"
    fi

    pod_info=$(pod trunk info "$POD_NAME" 2>/dev/null || true)
    if printf '%s\n' "$pod_info" | grep -Eq "^[[:space:]]*-[[:space:]]+$VERSION_REGEX([[:space:]]|$)"; then
      fail "CocoaPods trunk already contains $POD_NAME $VERSION."
    fi
  fi
}

bump_release_files() {
  local staged_podspec="$RUN_DIR/bumped-podspec"
  local staged_changelog="$RUN_DIR/bumped-changelog"
  local release_heading="## [$VERSION] - $(date +'%Y-%m-%d')"

  awk -v version="$VERSION" '
    /^[[:space:]]*s[.]version[[:space:]]*=/ {
      sub(/\047[^\047]*\047/, "\047" version "\047")
      sub(/"[^"]*"/, "\"" version "\"")
    }
    { print }
  ' "$PODSPEC" > "$staged_podspec"

  [ "$(grep -Ec "^[[:space:]]*s\\.version[[:space:]]*=[[:space:]]*['\"]$VERSION_REGEX['\"][[:space:]]*$" "$staged_podspec" || true)" -eq 1 ] \
    || fail "Failed to stage version $VERSION in $PODSPEC."
  cp "$staged_podspec" "$PODSPEC"

  if [ -f "$CHANGELOG" ]; then
    if grep -q '^## \[Unreleased\]' "$CHANGELOG"; then
      awk -v heading="$release_heading" '
        !updated && /^## \[Unreleased\]/ {
          print heading
          updated = 1
          next
        }
        { print }
      ' "$CHANGELOG" > "$staged_changelog"
      cp "$staged_changelog" "$CHANGELOG"
    fi
  fi
}

create_release_notes() {
  NOTES_FILE="$RUN_DIR/release-notes.md"
  if [ -f "$CHANGELOG" ]; then
    local expected_heading="## [$VERSION] - $(date +'%Y-%m-%d')"
    awk -v heading="$expected_heading" -v version="$VERSION" '
      $0 == heading || $0 ~ "^## \\[" version "\\]" { in_release = 1; found = 1; next }
      in_release && /^## \[[^]]+\]/ { in_release = 0 }
      in_release { lines[++count] = $0 }
      END {
        if (!found) exit 2
        first = 1
        while (first <= count && lines[first] == "") first++
        last = count
        while (last >= first && lines[last] == "") last--
        for (line_number = first; line_number <= last; line_number++) print lines[line_number]
      }
    ' "$CHANGELOG" > "$NOTES_FILE" 2>/dev/null || true
  fi

  if [ ! -s "$NOTES_FILE" ]; then
    cat <<EOF > "$NOTES_FILE"
# $COMPONENT_NAME $VERSION

Release of $COMPONENT_NAME version $VERSION.
EOF
  fi
}

validate_podspec_metadata() {
  local spec_name spec_version spec_source_tag

  pod ipc spec "$PODSPEC" > "$RUN_DIR/podspec.json"
  spec_name=$(ruby -rjson -e 'puts JSON.parse(File.read(ARGV[0]))["name"]' "$RUN_DIR/podspec.json")
  spec_version=$(ruby -rjson -e 'puts JSON.parse(File.read(ARGV[0]))["version"]' "$RUN_DIR/podspec.json")
  spec_source_tag=$(ruby -rjson -e 'puts JSON.parse(File.read(ARGV[0])).dig("source", "tag")' "$RUN_DIR/podspec.json")

  [ "$spec_name" = "$POD_NAME" ] || fail "Podspec name is '$spec_name', expected '$POD_NAME'."
  [ "$spec_version" = "$VERSION" ] || fail "Parsed podspec version is '$spec_version', expected '$VERSION'."
  [ "$spec_source_tag" = "$VERSION" ] || fail "Parsed podspec source tag is '$spec_source_tag', expected '$VERSION'."
}

validate_release_versions() {
  local pod_version

  bump_release_files

  pod_version=$(extract_podspec_version "$PODSPEC")
  if [ "$pod_version" != "$VERSION" ]; then
    fail "Podspec version after bump is '$pod_version', expected '$VERSION'."
  fi

  if [ -f "$CHANGELOG" ]; then
    local top_changelog
    top_changelog=$(extract_top_changelog_version "$CHANGELOG")
    if [ "$top_changelog" != "$VERSION" ] && [ "$SKIP_CHANGELOG_CHECK" -eq 0 ]; then
      fail "Top changelog version after bump is '$top_changelog', expected '$VERSION'."
    fi
  fi

  assert_exact_release_changes
  create_release_notes
  validate_podspec_metadata
}

validate_swift_manifest() {
  swift package dump-package > "$RUN_DIR/package.json"
  assert_exact_release_changes
}

validate_swift_manifest_dry() {
  local cache_path="$RUN_DIR/swift-cache"
  local config_path="$RUN_DIR/swift-config"
  local security_path="$RUN_DIR/swift-security"
  local scratch_path="$RUN_DIR/swift-scratch"

  swift package \
    --cache-path "$cache_path" \
    --config-path "$config_path" \
    --security-path "$security_path" \
    --scratch-path "$scratch_path" \
    dump-package > "$RUN_DIR/package.json"
  assert_exact_release_changes
}

run_tests() {
  if [ "$SKIP_TESTS" -eq 1 ]; then
    echo "    ⚠️  --skip-tests: Skipping xcodebuild unit tests."
    return 0
  fi

  local destination
  destination=$(resolve_test_destination)
  [ -n "$destination" ] || fail "No iOS Simulator destination could be resolved for testing."

  echo "    Running xcodebuild test (destination: $destination)..."
  local test_dd="$RUN_DIR/test-derived-data"
  local test_log="$RUN_DIR/xcodebuild-test.log"
  mkdir -p "$test_dd"

  local status=0
  xcodebuild test \
    -scheme "$SCHEME_NAME" \
    -destination "$destination" \
    -derivedDataPath "$test_dd" \
    > "$test_log" 2>&1 || status=$?

  rm -rf "$test_dd"

  if [ "$status" -ne 0 ]; then
    echo "" >&2
    echo "xcodebuild test failed for $SCHEME_NAME. Diagnostics:" >&2
    tail -n 40 "$test_log" >&2
    fail "xcodebuild test exited with status $status."
  fi

  if [ -f "Package.resolved" ] && git ls-files --error-unmatch "Package.resolved" >/dev/null 2>&1; then
    git checkout -- Package.resolved >/dev/null 2>&1 || true
  fi

  assert_exact_release_changes
}

lint_podspec() {
  if [ "$SKIP_POD_LINT" -eq 1 ]; then
    echo "    ⚠️  --skip-pod-lint: Skipping pod lib lint."
    return 0
  fi

  local pod_val_dir="$RUN_DIR/pod-validation"
  mkdir -p "$pod_val_dir"
  local lint_log="$RUN_DIR/pod-lint.log"
  local status=0

  echo "    Running pod lib lint $PODSPEC --allow-warnings..."
  pod lib lint "$PODSPEC" \
    --allow-warnings \
    --validation-dir="$pod_val_dir" \
    > "$lint_log" 2>&1 || status=$?

  rm -rf "$pod_val_dir"

  if [ "$status" -ne 0 ]; then
    echo "" >&2
    echo "pod lib lint failed for $PODSPEC. Diagnostics:" >&2
    tail -n 40 "$lint_log" >&2
    fail "pod lib lint exited with status $status."
  fi

  assert_exact_release_changes
}

commit_release_files() {
  local path subject
  local -a staged=() committed=()

  require_live_mode "git commit" || return 1
  assert_exact_release_changes
  git add -- "${RELEASE_FILES[@]}"

  while IFS= read -r path; do
    [ -z "$path" ] || staged+=("$path")
  done < <(git diff --cached --name-only --)
  assert_paths_are_exact_release_files "Staged release commit" "${staged[@]}"
  git diff --cached --check

  if ! git diff --quiet --; then
    fail "Unstaged tracked changes remain after staging the release files."
  fi

  git commit -m "chore: release $VERSION"
  RELEASE_COMMIT=$(git rev-parse HEAD)
  subject=$(git log -1 --format=%s)
  [ "$subject" = "chore: release $VERSION" ] || fail "Release commit subject is '$subject', expected 'chore: release $VERSION'."

  while IFS= read -r path; do
    [ -z "$path" ] || committed+=("$path")
  done < <(git diff-tree --no-commit-id --name-only -r "$RELEASE_COMMIT")
  assert_paths_are_exact_release_files "Release commit $RELEASE_COMMIT" "${committed[@]}"
  [ -z "$(git status --porcelain --untracked-files=no)" ] || fail "Tracked changes remain after creating the release commit."
}

push_release_commit() {
  local remote_head
  require_live_mode "git push" || return 1
  git push origin "$BRANCH"
  remote_head=$(git ls-remote origin "refs/heads/$BRANCH" | awk '{print $1}')
  [ "$remote_head" = "$RELEASE_COMMIT" ] || fail "origin/$BRANCH points to $remote_head instead of release commit $RELEASE_COMMIT."
}

create_and_push_tag() {
  local remote_tag
  require_live_mode "git tag and push" || return 1
  git tag "$VERSION" "$RELEASE_COMMIT"
  [ "$(git rev-list -n 1 "$VERSION")" = "$RELEASE_COMMIT" ] || fail "Local tag $VERSION does not resolve to $RELEASE_COMMIT."
  git push origin "refs/tags/$VERSION"
  remote_tag=$(git ls-remote origin "refs/tags/$VERSION" | awk '{print $1}')
  [ "$remote_tag" = "$RELEASE_COMMIT" ] || fail "Remote tag $VERSION points to $remote_tag instead of $RELEASE_COMMIT."
}

create_github_release() {
  require_live_mode "GitHub Release creation" || return 1
  gh release create "$VERSION" \
    --repo "$GH_REPO" \
    --title "$VERSION" \
    --notes-file "$NOTES_FILE" \
    --verify-tag
}

push_cocoapods_trunk() {
  require_live_mode "CocoaPods trunk publication" || return 1
  if ! pod trunk me > "$RUN_DIR/pod-trunk-me-final.out" 2>&1; then
    fail "CocoaPods authentication expired. Run: pod trunk register engg@digia.tech 'Digia Engineering'"
  fi
  pod trunk push "$PODSPEC" --allow-warnings
}

verify_final_state() {
  local remote_head remote_tag

  remote_head=$(git ls-remote origin "refs/heads/$BRANCH" | awk '{print $1}')
  remote_tag=$(git ls-remote origin "refs/tags/$VERSION" | awk '{print $1}')
  [ "$remote_head" = "$RELEASE_COMMIT" ] || fail "Final branch verification failed for origin/$BRANCH."
  [ "$remote_tag" = "$RELEASE_COMMIT" ] || fail "Final tag verification failed for $VERSION."
  gh release view "$VERSION" --repo "$GH_REPO" >/dev/null 2>&1 || fail "GitHub Release $VERSION could not be verified."
  [ -z "$(git status --porcelain --untracked-files=no)" ] || fail "The release left tracked worktree changes behind."
}

print_success() {
  local passed

  echo ""
  echo "============================================================"
  echo "RELEASE PASSED: $COMPONENT_NAME $VERSION"
  echo "Why it passed:"
  for passed in "${PASSED_STEPS[@]}"; do
    echo "  ✓ $passed"
  done
  echo ""
  echo "Release commit: $RELEASE_COMMIT"
  echo "Git tag: $VERSION"
  echo "GitHub Release: https://github.com/$GH_REPO/releases/tag/$VERSION"
  echo "CocoaPods: pod trunk push completed successfully"
  echo ""
  echo "Suggested next step: wait 2–5 minutes for CocoaPods propagation, then run:"
  echo "  pod search $POD_NAME"
  echo "============================================================"
}

print_dry_run_success() {
  local passed

  echo ""
  echo "============================================================"
  echo "DRY RUN PASSED: $COMPONENT_NAME $VERSION is ready to release"
  echo "Why it passed:"
  for passed in "${PASSED_STEPS[@]}"; do
    echo "  ✓ $passed"
  done
  echo ""
  echo "No persistent write was performed:"
  echo "  - real release files, git index, HEAD, and refs are unchanged"
  echo "  - no commit, push, or tag was created"
  echo "  - no GitHub Release was created"
  echo "  - nothing was published to CocoaPods trunk"
  echo "  - temporary validation files were removed at exit"
  if [ -n "$LATEST_RELEASED_TAG" ]; then
    echo "Validated against latest released tag: $LATEST_RELEASED_TAG"
  fi
  echo ""
  echo "Suggested next step:"
  echo "  ./scripts/release.sh $VERSION"
  echo "============================================================"
}

print_no_commit_success() {
  local passed

  echo ""
  echo "============================================================"
  echo "NO-COMMIT VALIDATION PASSED: $COMPONENT_NAME $VERSION"
  echo "Why it passed:"
  for passed in "${PASSED_STEPS[@]}"; do
    echo "  ✓ $passed"
  done
  echo ""
  echo "Working tree has been bumped to $VERSION."
  echo "No commit, push, tag, or publication was performed."
  echo ""
  echo "Modified files:"
  git diff --name-only HEAD --
  echo "============================================================"
}

validate_dry_run_preflight() {
  capture_original_state
  validate_preflight
}

run_dry_run() {
  TOTAL_STEPS=7

  run_step \
    "Read-only release preflight" \
    "Correct the reported prerequisite and rerun with --dry-run; the real checkout and remotes remain unchanged." \
    "tools/auth/git state are valid and the input is greater than the latest remote SemVer tag" \
    validate_dry_run_preflight

  run_step \
    "Create disposable validation clone" \
    "Check temporary-disk capacity and local git readability, then rerun the dry-run; the real checkout remains unchanged." \
    "all simulated writes are isolated from the real checkout and will be deleted at exit" \
    prepare_dry_run_clone

  run_step \
    "Simulate and cross-check release versions" \
    "Fix the real release-file inputs, then rerun the dry-run; no real file was modified by the simulation." \
    "the simulated podspec, dated changelog (if present), and release notes are consistent" \
    validate_release_versions

  run_step \
    "Validate the Swift package manifest in isolation" \
    "Fix the manifest and rerun the dry-run; validation outputs exist only in the disposable clone." \
    "Package.swift parses successfully using temporary caches" \
    validate_swift_manifest_dry

  run_step \
    "Run unit tests in isolation" \
    "Fix test failures, check simulator availability, or use --skip-tests if appropriate." \
    "xcodebuild test succeeded for $SCHEME_NAME" \
    run_tests

  run_step \
    "Lint the podspec in isolation" \
    "Fix CocoaPods lint errors or use --skip-pod-lint before dependencies are on trunk." \
    "pod lib lint passed for $PODSPEC" \
    lint_podspec

  run_step \
    "Prove dry-run non-mutation" \
    "Inspect the reported state mismatch before releasing; do not run the live workflow until resolved." \
    "the planned file diff is exact and the real files, index, HEAD, refs, and status are unchanged" \
    verify_dry_run_non_mutation

  print_dry_run_success
}

run_no_commit() {
  TOTAL_STEPS=5

  run_step \
    "Preflight validation" \
    "Correct the reported prerequisite; no files were changed yet." \
    "tools/auth/git state are valid" \
    validate_preflight

  run_step \
    "Bump and cross-check release versions" \
    "Fix the release files, keeping only the requested version, then rerun." \
    "podspec and changelog (if present) were bumped to $VERSION" \
    validate_release_versions

  run_step \
    "Validate the Swift package manifest" \
    "Fix the manifest and rerun." \
    "Package.swift parses successfully" \
    validate_swift_manifest

  run_step \
    "Run unit tests" \
    "Fix test failures or use --skip-tests if appropriate." \
    "xcodebuild test succeeded for $SCHEME_NAME" \
    run_tests

  run_step \
    "Lint the podspec" \
    "Fix CocoaPods lint errors or use --skip-pod-lint before dependencies are on trunk." \
    "pod lib lint passed for $PODSPEC" \
    lint_podspec

  print_no_commit_success
}

run_live() {
  TOTAL_STEPS=11

  echo "This will commit, push, tag, create a GitHub Release, and publish to CocoaPods trunk."

  run_step \
    "Preflight validation" \
    "Correct the reported prerequisite. No release files were changed yet." \
    "tools/auth/git state are valid and input is greater than latest released tag" \
    validate_preflight

  run_step \
    "Bump and cross-check release versions" \
    "Fix the release files, keeping only the requested version, then rerun." \
    "podspec and changelog (if present) were bumped to $VERSION" \
    validate_release_versions

  run_step \
    "Validate the Swift package manifest" \
    "Fix the manifest and rerun." \
    "Package.swift parses successfully" \
    validate_swift_manifest

  run_step \
    "Run unit tests" \
    "Fix test failures or use --skip-tests if appropriate." \
    "xcodebuild test succeeded for $SCHEME_NAME" \
    run_tests

  run_step \
    "Lint the podspec" \
    "Fix CocoaPods lint errors or use --skip-pod-lint before dependencies are on trunk." \
    "pod lib lint passed for $PODSPEC" \
    lint_podspec

  run_step \
    "Commit exactly the release files" \
    "Inspect git status and 'git log -1'. If no release commit was created, fix the issue and rerun." \
    "the release commit contains only the authorized release files" \
    commit_release_files

  run_step \
    "Push the release commit" \
    "Resolve the push failure, then run: git push origin $BRANCH" \
    "origin/$BRANCH points to the verified release commit" \
    push_release_commit

  run_step \
    "Create and push tag $VERSION" \
    "Inspect local and remote tag $VERSION; if only local, run: git push origin refs/tags/$VERSION" \
    "the local and remote version tag both point to the release commit" \
    create_and_push_tag

  run_step \
    "Create the GitHub Release" \
    "Inspect 'gh release view $VERSION --repo $GH_REPO'; create it before CocoaPods publication." \
    "the release was created on GitHub with version notes and verified tag" \
    create_github_release

  run_step \
    "Push to CocoaPods trunk" \
    "If authentication failed, register with CocoaPods; otherwise resolve the trunk error and rerun: pod trunk push $PODSPEC --allow-warnings" \
    "CocoaPods trunk accepted $POD_NAME $VERSION" \
    push_cocoapods_trunk

  run_step \
    "Final state verification" \
    "Inspect the remote branch, tag, GitHub Release, and local worktree before announcing the release." \
    "remote release state is internally consistent and no tracked changes remain" \
    verify_final_state

  print_success
}

main() {
  local script_dir repo_root

  while [ "$#" -gt 0 ]; do
    case "$1" in
      -h|--help)
        usage
        return 0
        ;;
      --dry-run)
        DRY_RUN=1
        shift
        ;;
      --no-commit)
        NO_COMMIT=1
        shift
        ;;
      --allow-dirty)
        ALLOW_DIRTY=1
        shift
        ;;
      --skip-tests)
        SKIP_TESTS=1
        shift
        ;;
      --skip-pod-lint)
        SKIP_POD_LINT=1
        shift
        ;;
      --skip-changelog-check)
        SKIP_CHANGELOG_CHECK=1
        shift
        ;;
      -b|--allow-branch|--branch)
        [ "$#" -ge 2 ] || { echo "Error: $1 requires an argument." >&2; return 2; }
        EXPECTED_BRANCH="$2"
        shift 2
        ;;
      -v|--version)
        [ "$#" -ge 2 ] || { echo "Error: $1 requires an argument." >&2; return 2; }
        VERSION="$2"
        shift 2
        ;;
      -*)
        echo "Error: Unknown flag '$1'." >&2
        usage >&2
        return 2
        ;;
      *)
        if [ -z "$VERSION" ]; then
          VERSION="$1"
        else
          echo "Error: Unexpected positional argument '$1' (version is already set to '$VERSION')." >&2
          usage >&2
          return 2
        fi
        shift
        ;;
    esac
  done

  if [ -z "$VERSION" ]; then
    echo "Error: Target version is required." >&2
    usage >&2
    return 2
  fi

  if [ "$DRY_RUN" -eq 1 ] && [ "$NO_COMMIT" -eq 1 ]; then
    echo "Error: Cannot combine --dry-run and --no-commit." >&2
    return 2
  fi

  if [ "$ALLOW_DIRTY" -eq 1 ] && [ "$DRY_RUN" -eq 0 ] && [ "$NO_COMMIT" -eq 0 ]; then
    echo "Error: --allow-dirty is only permitted with --dry-run or --no-commit; never for a live release." >&2
    return 2
  fi

  if ! validate_semver "$VERSION"; then
    echo "Error: Invalid version '$VERSION'. Expected SemVer such as 1.0.1 or 1.0.1-beta.1 (build metadata is not supported)." >&2
    return 2
  fi
  VERSION_REGEX=${VERSION//./\\.}

  script_dir=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
  repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
  cd "$repo_root"
  ORIGINAL_REPO_ROOT=$repo_root

  if [ "$DRY_RUN" -eq 1 ]; then
    export GIT_OPTIONAL_LOCKS=0
  fi
  RUN_DIR=$(mktemp -d "${TMPDIR:-/tmp}/digia-release.XXXXXX")

  if [ "$DRY_RUN" -eq 1 ]; then
    echo "$COMPONENT_NAME release dry-run $VERSION"
  elif [ "$NO_COMMIT" -eq 1 ]; then
    echo "$COMPONENT_NAME release no-commit validation $VERSION"
  else
    echo "$COMPONENT_NAME release $VERSION"
  fi
  echo "Repository: $repo_root"

  if [ "$DRY_RUN" -eq 1 ]; then
    echo "The real checkout and all remotes are read-only; test/lint writes are confined to a disposable temporary clone."
    run_dry_run
    return 0
  fi

  if [ "$NO_COMMIT" -eq 1 ]; then
    echo "Bumping version and running local validation; will stop before any commit, push, tag, or publish."
    run_no_commit
    return 0
  fi

  run_live
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
