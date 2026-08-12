# Push and release — devprogrmer/hydra

## Before anything: revoke the leaked token

A GitHub token was pasted into a chat earlier in this project. Treat it as public.
https://github.com/settings/tokens -> delete it.

Then authenticate the safe way, which stores credentials in your OS keychain:

    gh auth login

Never paste a token into a script, a commit, or a chat again.

## Files that must be in the repo ROOT

    hydra.sh        <- install.sh downloads this; missing it causes the 404
    install.sh
    README.md
    README.fa.md
    LICENSE

## Push

    cd hydra
    git add .
    git commit -m "hydra v3.7.0 - high-loss FEC profiles, link tuning, diagnostics"
    git push origin main

First time:

    git init -b main
    git add .
    git commit -m "hydra v3.7.0"
    git remote add origin https://github.com/devprogrmer/hydra.git
    git push -u origin main

## Verify before telling anyone to install

    curl -sI https://raw.githubusercontent.com/devprogrmer/hydra/main/hydra.sh   | head -1
    curl -sI https://raw.githubusercontent.com/devprogrmer/hydra/main/install.sh | head -1

Both must be HTTP 200. Raw URLs cache for a few minutes after a push.

## Tag and release

    git tag -a v3.7.0 -m "hydra v3.7.0"
    git push origin v3.7.0

.github/workflows/release.yml then builds the tarball, generates SHA256SUMS and
publishes the release using docs/RELEASE.md as the body.

Manual alternative:

    gh release create v3.7.0 --title "hydra v3.7.0" --notes-file docs/RELEASE.md

## Repo metadata

    gh repo edit devprogrmer/hydra \
      --description "Multi-exit gaming tunnel: FEC, faketcp, BBR, automatic failover" \
      --add-topic wireguard --add-topic tunnel --add-topic gaming \
      --add-topic fec --add-topic udp2raw --add-topic bbr
