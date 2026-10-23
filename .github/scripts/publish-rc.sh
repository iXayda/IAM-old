#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

version=${1:?Supply the RC version from pom.xml}
directory=${2:-target/rc}
[[ "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)-rc\.(0|[1-9][0-9]*)$ ]] || {
  echo 'Expected an x.y.z-rc.N version.' >&2; exit 1;
}
: "${GH_TOKEN:?A repository token is required}"
: "${GITHUB_REPOSITORY:?The workflow repository is required}"
: "${GITHUB_SHA:?The workflow source commit is required}"
: "${GITHUB_SERVER_URL:?The GitHub server URL is required}"
: "${GITHUB_RUN_ID:?The workflow run ID is required}"

tag="v$version"
api="repos/$GITHUB_REPOSITORY"
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
cd "$directory"

# Bind the downloaded distribution to this run before changing remote state.
sha256sum --check --strict SHA256SUMS
grep -Fx "Version: $version" SOURCE.txt
grep -Fx "Source commit: $GITHUB_SHA" SOURCE.txt
run_url="$GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID"
grep -Fx "Workflow: $run_url" SOURCE.txt
shopt -s dotglob
files=(*)
for file in "${files[@]}"; do
  [[ -f "$file" && ! -L "$file" ]] || { echo "Expected an ordinary file: $file" >&2; exit 1; }
done
sha256sum -- "${files[@]}" | sort > "$work/local-checksums"
sed '/  SHA256SUMS$/d' "$work/local-checksums" > "$work/expected-checksums"
sort SHA256SUMS > "$work/actual-checksums"
cmp "$work/expected-checksums" "$work/actual-checksums"
cat RELEASE-NOTES.md > "$work/notes.md"
printf '\n<!-- %s -->\n' "$run_url" >> "$work/notes.md"

# Published versions are immutable; only a draft from this run can resume.
gh api --paginate --slurp "$api/releases?per_page=100" > "$work/releases.json"
jq --arg tag "$tag" '[.[][] | select(.tag_name == $tag)] |
  if length > 1 then error("Multiple releases use this tag") else .[0] end' \
  "$work/releases.json" > "$work/release.json"
release_id=$(jq -r '.id // empty' "$work/release.json")
if [[ -n "$release_id" ]]; then
  jq -e --arg sha "$GITHUB_SHA" --rawfile notes "$work/notes.md" \
    '.draft == true and .prerelease == true and .target_commitish == $sha and .body == $notes' \
    "$work/release.json" > /dev/null || {
      echo 'Release already published or draft belongs to another run; refusing to modify it.' >&2
      exit 1
    }
fi

verify_tag() {
  local object target
  object=$(gh api "$api/git/ref/tags/$tag" | jq -er \
    '.object | if .type == "tag" then .sha else error("Existing tag is not annotated") end')
  target=$(gh api "$api/git/tags/$object" | jq -er \
    '.object | if .type == "commit" then .sha else error("Tag must point directly to a commit") end')
  [[ "$target" == "$GITHUB_SHA" ]] || {
    echo 'Existing tag points to another commit; refusing to move it.' >&2; return 1;
  }
}

# Create an annotated tag, never a lightweight tag at a moving branch head.
ref=$(gh api "$api/git/matching-refs/tags/$tag" | \
  jq -r --arg ref "refs/tags/$tag" '.[] | select(.ref == $ref) | .object.sha')
if [[ -z "$ref" ]]; then
  object=$(gh api --method POST "$api/git/tags" \
    -f "tag=$tag" -f "message=IAM $version" -f "object=$GITHUB_SHA" -f type=commit \
    -f 'tagger[name]=github-actions[bot]' \
    -f 'tagger[email]=41898282+github-actions[bot]@users.noreply.github.com' --jq .sha)
  gh api --method POST "$api/git/refs" -f "ref=refs/tags/$tag" -f "sha=$object" > /dev/null
fi
verify_tag

if [[ -z "$release_id" ]]; then
  gh release create "$tag" --repo "$GITHUB_REPOSITORY" --target "$GITHUB_SHA" \
    --verify-tag --draft --prerelease --latest=false \
    --title "IAM $version" --notes-file "$work/notes.md"
  gh api --paginate --slurp "$api/releases?per_page=100" > "$work/releases.json"
  release_id=$(jq -er --arg tag "$tag" '.[][] | select(.tag_name == $tag and .draft) | .id' \
    "$work/releases.json")
fi

# A retry uploads missing files only. Never replace or delete existing assets.
gh api --paginate --slurp "$api/releases/$release_id/assets?per_page=100" | \
  jq '[.[][]]' > "$work/assets.json"
for file in "${files[@]}"; do
  digest=$(sha256sum -- "$file"); digest=${digest%% *}
  asset=$(jq -c --arg name "$file" '.[] | select(.name == $name)' "$work/assets.json")
  if [[ -n "$asset" ]]; then
    jq -e --arg digest "sha256:$digest" --argjson size "$(stat -c %s -- "$file")" \
      '.state == "uploaded" and .digest == $digest and .size == $size' <<< "$asset" > /dev/null || {
        echo "Existing asset is incomplete or differs: $file; refusing to overwrite it." >&2; exit 1;
      }
  else
    gh release upload "$tag" "$file" --repo "$GITHUB_REPOSITORY"
  fi
done

gh api --paginate --slurp "$api/releases/$release_id/assets?per_page=100" | jq -r '
  .[][] | if .state == "uploaded" and ((.digest // "") | test("^sha256:[a-f0-9]{64}$"))
  then (.digest | ltrimstr("sha256:")) + "  " + .name
  else error("Incomplete asset or missing SHA256 digest") end' | sort > "$work/remote-checksums"
cmp "$work/local-checksums" "$work/remote-checksums"
verify_tag
gh release edit "$tag" --repo "$GITHUB_REPOSITORY" --draft=false --prerelease --latest=false
