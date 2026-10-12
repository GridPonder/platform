# Public release boundary

This repository distributes a generic engine, DSL, tools, and intentionally
public example packs. Evaluation corpora, identifiers, pack-specific solver
plugins, regression inventories, and run evidence belong in separate storage.
Do not describe withheld tasks in commit messages, branches, PRs, issues, or
review comments. Renaming a copied level or game-specific fixture does not make
its content public.

The benchmark tools write reports into local results directories by default.
Gameplay anonymity is an experimental setting, not an export policy.
Do not copy raw reports, prompts, actions, notebooks, or images into the website.

`python3 tools/check_public_inputs.py` checks the reviewed example-pack tree,
Flutter asset configuration, and public leaderboard against
`tools/public-release-inputs.json`. It rejects unknown pack files, changed
report bytes, submodules, and data-path overrides. Both the Makefile and Astro
configuration run this check before building.

The checksums are a review boundary, not a content classifier. Update them only
after reviewing the actual content being added, including identifiers,
metadata, assets, and complete generated reports. Never regenerate the
inventory automatically as part of a build to make a failing check pass.

Before publishing a generated web bundle, inspect its asset manifest and verify
that it contains only the reviewed public inputs. Retain the reviewed source
snapshot and its checksums with the release evidence. Git history and hosting
discussions require their own review; a clean working tree does not sanitize
earlier commits or remote records.
