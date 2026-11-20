# The cosmic-bundle-validator release to use.
validator_version := "0.3.2"
validator_sha256 := "7a2ec5af7b11e2a61d3858c75232120198432733a08fbbbcf7ee97fbee4cc5f7"
validator_url := "https://github.com/pop-os/cosmic-bundle-validator/releases/download/v" + validator_version + "/cosmic-bundle-validator-x86_64-linux"
validator := env("VALIDATOR", ".cache/cosmic-bundle-validator-" + validator_version)

build id: fetch-validator
    #!/usr/bin/env bash
    set -eo pipefail
    mkdir -p "log/bundle/{{id}}"
    "{{validator}}" build "bundle/{{id}}/{{id}}.xml" --out out 2>&1 | tee "log/bundle/{{id}}/build.txt"

# Build every new or changed pin, then write out/catalog.xml listing those that built
repo base_url: fetch-validator
    #!/usr/bin/env bash
    set -e
    mkdir -p bundle out log
    ls -1 bundle | while read id
    do
        # A pin names a fixed commit, so its zip only changes when the pin or the validator does.
        stamp="$({ cat "bundle/${id}/${id}.xml"; echo "{{validator_version}}"; } | sha256sum | cut -d ' ' -f 1)"
        if [ -f "out/${id}.zip" ] && [ "$(cat "out/${id}.stamp" 2>/dev/null)" = "${stamp}" ]
        then
            echo "${id} unchanged, skipping"
            continue
        fi
        # A failed rebuild leaves no zip, so the catalog drops the bundle instead of listing a stale one.
        rm -f "out/${id}.zip" "out/${id}.stamp"
        if just build "${id}"
        then
            echo "${stamp}" > "out/${id}.stamp"
        else
            echo "failed to build ${id}"
        fi
    done
    # Drop zips whose pin was removed.
    for zip in out/*.zip
    do
        id="$(basename "${zip}" .zip)"
        [ ! -e "${zip}" ] || [ -f "bundle/${id}/${id}.xml" ] || rm -f "${zip}" "out/${id}.stamp"
    done
    "{{validator}}" catalog bundle out "{{base_url}}" 2>&1 | tee log/catalog.txt

# Build pins changed from origin/master
build-changed:
    #!/usr/bin/env bash
    set -e
    shopt -s lastpipe
    git fetch origin master
    fail=0
    git diff --name-only origin/master...HEAD | grep '^bundle/' | cut -d / -f2 | sort | uniq | while read id
    do
        if [ -f "bundle/${id}/${id}.xml" ]
        then
            just build ${id} || fail=1
        else
            echo "${id} pin removed, nothing to build"
        fi
    done
    exit "${fail}"

# Download the pinned validator release, unless $VALIDATOR points at one
[private]
fetch-validator:
    #!/usr/bin/env bash
    set -eo pipefail
    [ -z "${VALIDATOR:-}" ] || exit 0
    bin="{{validator}}"
    if [ ! -x "${bin}" ]; then
        [ -n "{{validator_sha256}}" ] || { echo "no validator release pinned yet; set VALIDATOR=/path/to/cosmic-bundle-validator" >&2; exit 1; }
        mkdir -p .cache
        curl -fsSL -o "${bin}.part" "{{validator_url}}"
        echo "{{validator_sha256}}  ${bin}.part" | sha256sum --check --quiet >&2
        chmod +x "${bin}.part"
        mv "${bin}.part" "${bin}"
    fi

# Copy out/ to the server (any rsync destination).
sync dest:
    rsync -rt --include='*.svg' --include='*.zip' --exclude='*' out/ "{{dest}}/"
    rsync -rt out/catalog.xml "{{dest}}/"
    rsync -rt --delete --include='*.svg' --include='*.zip' --include=catalog.xml --exclude='*' out/ "{{dest}}/"

clean:
    rm -rf log out

distclean: clean
    rm -rf .cache
