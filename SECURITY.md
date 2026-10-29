# Security and public contributions

Do not place credentials, real network inventories, session logs, home paths or private operational notes in issues, examples or commits. Use reserved documentation addresses and obvious placeholders. Redact exported diagnostics before sharing; local logs may include power/session timestamps and application paths.

Enable the staged secret check with `git config core.hooksPath .githooks`. Install scanners using `brew install gitleaks trufflehog`. Run both working-tree and all-ref history scans before publishing. Automated scanners are not proof that a repository contains no sensitive information. Do not validate unknown credentials against a remote provider without authorization.

No CI workflow is shipped in this snapshot. If adding one, use least-privilege permissions and never execute untrusted pull-request code with secrets or a privileged `pull_request_target` context.
