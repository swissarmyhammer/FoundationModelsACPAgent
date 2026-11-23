---
position_column: done
position_ordinal: ffffffc180
title: The session import finds sessions whose items have the macOS hidden flag
---
Request from TestudoApp (user decision 2026-11-23). Import/AgentSessionImporter.swift:295 enumerates with .skipsHiddenFiles. iCloud Drive sets the hidden flag on each item under a dot folder, so the import finds no session there. FoundationModelsRouter 2e74f703 had the same defect in its transcript discovery.

Fix: skip dotfiles and dot folders by name, not with .skipsHiddenFiles.

Test: a source folder whose items have the hidden flag is imported.