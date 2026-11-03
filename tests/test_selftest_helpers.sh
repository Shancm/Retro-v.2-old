#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SELFTEST="${ROOT}/scripts/99_selftest.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

eval "$(sed -n '/^lightdm_pam_clean() {/,/^}/p' "${SELFTEST}")"
eval "$(sed -n '/^gh_version() {/,/^}/p' "${SELFTEST}")"

PASS=0
FAIL=0
report() {
    local label="$1" ok="$2"
    if [[ "${ok}" == 1 ]]; then
        PASS=$((PASS + 1))
        printf 'PASS %s\\n' "${label}"
    else
        FAIL=$((FAIL + 1))
        printf 'FAIL %s\\n' "${label}" >&2
    fi
}

PAM_DIR="${TMP}/pam"
mkdir -p "${PAM_DIR}"
RETRO_SELFTEST_PAM_DIR="${PAM_DIR}"

# Start from the minimum package-owned PAM files required by the helper.
printf '@include common-auth\\n' > "${PAM_DIR}/lightdm"
printf 'auth required pam_permit.so\\n' > "${PAM_DIR}/lightdm-autologin"
printf 'auth required pam_permit.so\\n' > "${PAM_DIR}/lightdm-greeter"
if lightdm_pam_clean; then report "package greeter pam_permit allowed" 1; else report "package greeter pam_permit allowed" 0; fi
if lightdm_pam_clean; then report "package autologin pam_permit allowed" 1; else report "package autologin pam_permit allowed" 0; fi
printf 'auth required pam_permit.so\\n' > "${PAM_DIR}/lightdm"
if lightdm_pam_clean; then report "primary lightdm pam_permit rejected" 0; else report "primary lightdm pam_permit rejected" 1; fi
printf '@include common-auth\\n' > "${PAM_DIR}/lightdm"
printf 'auth required pam_succeed_if.so user ingroup nopasswdlogin\\n' > "${PAM_DIR}/lightdm-greeter"
if lightdm_pam_clean; then report "nopasswdlogin in greeter rejected" 0; else report "nopasswdlogin in greeter rejected" 1; fi
printf 'auth required pam_permit.so\\n' > "${PAM_DIR}/lightdm-greeter"
printf 'auth required pam_succeed_if.so user ingroup nopasswdlogin\\n' > "${PAM_DIR}/lightdm-autologin"
if lightdm_pam_clean; then report "nopasswdlogin in autologin rejected" 0; else report "nopasswdlogin in autologin rejected" 1; fi

MOCKBIN="${TMP}/bin"
mkdir -p "${MOCKBIN}"
cat > "${MOCKBIN}/dpkg-query" <<'MOCK'
#!/usr/bin/env bash
[[ "${1:-}" == "-W" ]] || exit 1
[[ -n "${TEST_DPKG_VERSION:-}" ]] || exit 1
printf '%s\\n' "${TEST_DPKG_VERSION}"
MOCK
cat > "${MOCKBIN}/gh" <<'MOCK'
#!/usr/bin/env bash
[[ "${1:-}" == "--version" && -n "${TEST_GH_VERSION:-}" ]] || exit 1
printf 'gh version %s (test)\\n' "${TEST_GH_VERSION}"
MOCK
chmod +x "${MOCKBIN}/dpkg-query" "${MOCKBIN}/gh"
OLD_PATH="$PATH"
PATH="${MOCKBIN}:/usr/bin:/bin"
export PATH

TEST_DPKG_VERSION="2.103.3"
v="$(gh_version)"
if [[ "$v" == "2.103.3" ]] && dpkg --compare-versions "$v" ge 2.67.0; then report "dpkg version 2.103.3 accepted" 1; else report "dpkg version 2.103.3 accepted" 0; fi

TEST_DPKG_VERSION="2.66.1"
v="$(gh_version)"
if [[ "$v" == "2.66.1" ]] && ! dpkg --compare-versions "$v" ge 2.67.0; then report "dpkg version 2.66.1 rejected" 1; else report "dpkg version 2.66.1 rejected" 0; fi

TEST_DPKG_VERSION="1:2.103.3-1"
v="$(gh_version)"
if [[ "$v" == "1:2.103.3-1" ]] && dpkg --compare-versions "$v" ge 2.67.0; then report "epoch version parsed and accepted" 1; else report "epoch version parsed and accepted" 0; fi

TEST_DPKG_VERSION="2.67.0"
v="$(gh_version)"
if [[ "$v" == "2.67.0" ]] && dpkg --compare-versions "$v" ge 2.67.0; then report "minimum supported version accepted" 1; else report "minimum supported version accepted" 0; fi

TEST_DPKG_VERSION=""
TEST_GH_VERSION="2.103.3"
v="$(gh_version)"
if [[ "$v" == "2.103.3" ]]; then report "gh --version fallback parsed" 1; else report "gh --version fallback parsed" 0; fi

TEST_GH_VERSION=""
if gh_version >/dev/null 2>&1; then report "missing version detected" 0; else report "missing version detected" 1; fi

PATH="$OLD_PATH"
printf '\nSelf-test helper tests: %d passed, %d failed\\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
