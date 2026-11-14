#!/usr/bin/env bash
# Publish graywolf-container images to GHCR.
#
# Release tags look like YYYY-MM-DD-NN (NN = serial for that day, 01, 02, ...).
# Each architecture is built natively on its own machine and pushed as
#   <image>:<tag>-amd64   and   <image>:<tag>-arm64
# then one machine publishes the multi-arch manifest as
#   <image>:<tag>   <image>:latest   <image>:gw-<graywolf version>
#
# Usage:
#   scripts/publish.sh [--dry-run] next                 print the next free tag
#   scripts/publish.sh [--dry-run] amd64|arm64 [TAG]    build + push one arch
#   scripts/publish.sh [--dry-run] manifest TAG         publish multi-arch tags
#
# Environment:
#   IMAGE   override the image name (e.g. a throwaway package for a test run)
#
# See docs/releases.qmd for the full process.

set -euo pipefail

IMAGE=${IMAGE:-ghcr.io/kf8eez/graywolf-container}
SOURCE_URL=https://github.com/KF8EEZ/graywolf-container
DOCS_URL=https://KF8EEZ.github.io/graywolf-container/
TAG_RE='^[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{2}$'
DRY_RUN=0

die()  { echo "error: $*" >&2; exit 1; }
warn() { echo "warning: $*" >&2; }
info() { echo "==> $*" >&2; }

# Print the command in dry-run mode, run it otherwise.
run() {
    if (( DRY_RUN )); then
        printf '[dry-run]'; printf ' %q' "$@"; echo
    else
        "$@"
    fi
}

registry_host() { echo "${IMAGE%%/*}"; }

# Version of graywolf that the Containerfile installs (single source of truth).
graywolf_version() {
    sed -n 's/^ARG GRAYWOLF_VERSION=//p' Containerfile | head -n1
}

# Read tags on stdin, print the next free release tag for date $1.
# Per-arch tags count too, so a half-finished release is never reused.
next_tag_from_stdin() {
    local date=$1 max=0 t n
    while read -r t; do
        if [[ $t =~ ^${date}-([0-9]{2})(-amd64|-arm64)?$ ]]; then
            n=$((10#${BASH_REMATCH[1]}))
            if (( n > max )); then max=$n; fi
        fi
    done
    (( max < 99 )) || die "serial for $date already at 99"
    printf '%s-%02d\n' "$date" $((max + 1))
}

# Print every tag currently in the registry for $IMAGE, one per line.
# A package that does not exist yet (first publish) yields no tags.
list_tags() {
    local out
    if out=$(podman search --list-tags --limit 1000 --format '{{.Tag}}' "$IMAGE" 2>&1); then
        printf '%s\n' "$out"
    elif [[ $out == *403* || $out == *404* || $out == *"name unknown"* || $out == *NAME_UNKNOWN* ]]; then
        info "no existing tags found for $IMAGE (package may not exist yet)"
    elif (( DRY_RUN )); then
        warn "could not list tags (dry run, assuming none): $out"
    else
        die "could not list tags for $IMAGE: $out"
    fi
}

require_login() {
    (( DRY_RUN )) && return 0
    podman login --get-login "$(registry_host)" >/dev/null 2>&1 \
        || die "not logged in to $(registry_host). Run:
  gh auth refresh -s write:packages
  gh auth token | podman login $(registry_host) -u \"\$(gh api user -q .login)\" --password-stdin"
}

require_clean_tree() {
    if [[ -n $(git status --porcelain) ]]; then
        (( DRY_RUN )) && { warn "uncommitted changes (ignored in dry run)"; return 0; }
        die "uncommitted changes; commit first so the release matches a commit"
    fi
    if ! git branch -r --contains HEAD 2>/dev/null | grep -q .; then
        warn "HEAD is not on any remote branch; push it so the release can be traced"
    fi
}

host_arch() {
    case $(uname -m) in
        x86_64)         echo amd64 ;;
        aarch64|arm64)  echo arm64 ;;
        *)              echo "unsupported:$(uname -m)" ;;
    esac
}

cmd_next() {
    require_login
    next_tag_from_stdin "$(date +%F)" < <(list_tags)
}

cmd_build() {
    local arch=$1 tag=${2:-} tags
    tags=$(list_tags)

    if [[ -z $tag ]]; then
        tag=$(next_tag_from_stdin "$(date +%F)" <<<"$tags")
        info "chose tag $tag; pass it to the other architecture's run:"
        info "  scripts/publish.sh $([[ $arch == amd64 ]] && echo arm64 || echo amd64) $tag"
    fi
    [[ $tag =~ $TAG_RE ]] || die "tag must look like YYYY-MM-DD-NN, got '$tag'"

    local ref="$IMAGE:$tag-$arch"
    if grep -qx -- "$tag-$arch" <<<"$tags"; then
        die "$ref already exists in the registry; refusing to overwrite"
    fi

    if [[ $(host_arch) != "$arch" ]]; then
        (( DRY_RUN )) && warn "host is $(host_arch), not $arch (ignored in dry run)" \
            || die "host is $(host_arch); build $arch on an $arch machine (native builds only)"
    fi

    require_login
    require_clean_tree

    local rev created
    rev=$(git rev-parse HEAD)
    created=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    info "building $ref (graywolf $(graywolf_version), commit ${rev:0:8})"
    run podman build --pull=newer --platform "linux/$arch" -f Containerfile \
        --label "org.opencontainers.image.revision=$rev" \
        --label "org.opencontainers.image.created=$created" \
        -t "$ref" .
    info "pushing $ref"
    run podman push "$ref"
}

cmd_manifest() {
    local tag=${1:-}
    [[ $tag =~ $TAG_RE ]] || die "usage: publish.sh manifest YYYY-MM-DD-NN"

    local tags a
    tags=$(list_tags)
    for a in amd64 arm64; do
        grep -qx -- "$tag-$a" <<<"$tags" \
            || { (( DRY_RUN )) && warn "$IMAGE:$tag-$a not in registry (ignored in dry run)" \
                 || die "$IMAGE:$tag-$a not found; build and push both architectures first"; }
    done

    require_login
    require_clean_tree

    local ver ml="localhost/graywolf-release:$tag"
    ver=$(graywolf_version)
    [[ -n $ver ]] || die "could not read GRAYWOLF_VERSION from Containerfile"

    info "creating manifest for $tag (graywolf $ver)"
    run podman manifest rm "$ml" 2>/dev/null || true
    run podman manifest create "$ml"
    for a in amd64 arm64; do
        run podman pull --platform "linux/$a" "$IMAGE:$tag-$a"
        run podman manifest add "$ml" "$IMAGE:$tag-$a"
    done
    local t
    for t in "$tag" latest "gw-$ver"; do
        info "pushing $IMAGE:$t"
        run podman manifest push --all "$ml" "docker://$IMAGE:$t"
    done
    info "done. Pull with: podman pull $IMAGE:$tag"
}

main() {
    local args=() a
    for a in "$@"; do
        if [[ $a == --dry-run ]]; then DRY_RUN=1; else args+=("$a"); fi
    done
    set -- "${args[@]+"${args[@]}"}"

    cd "$(dirname "${BASH_SOURCE[0]}")/.."
    case ${1:-} in
        next)         cmd_next ;;
        amd64|arm64)  cmd_build "$1" "${2:-}" ;;
        manifest)     cmd_manifest "${2:-}" ;;
        *)            sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 2 ;;
    esac
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi
