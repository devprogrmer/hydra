# Push & release

## 0. Set your repo path

Edit ONE line in `install.sh`:

    REPO="${HYDRA_REPO:-devprogrmer/hydra}"

and the same placeholder in README.md / README.fa.md.

## 1. Revoke the leaked token
https://github.com/settings/tokens -> delete it, create a new one.
Never paste a token into a chat, a script, or a commit.

## 2. Authenticate locally

    gh auth login                              # stores it in your OS keychain

## 3. Push

    git init -b main
    git add .
    git commit -m "hydra v2.0.0 - menu-driven multi-exit gaming tunnel"
    gh repo create devprogrmer/hydra --public --source=. --remote=origin --push

## 4. Tag and release

    git tag -a v2.0.0 -m "hydra v2.0.0"
    git push origin v2.0.0

The workflow in .github/workflows/release.yml builds the tarball, generates SHA256SUMS,
and publishes the release from docs/RELEASE.md.

## 5. Verify the one-liner works

From any fresh server:

    bash <(curl -fsSL https://raw.githubusercontent.com/devprogrmer/hydra/main/install.sh)
