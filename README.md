# Running Claude Code against a DDEV project

Two guides for getting [Claude Code](https://code.claude.com/docs/en/claude-code-on-the-web)
sessions working against a [DDEV](https://ddev.com) project (`ddev start`,
`ddev drush`, `ddev composer`, ...), with the session able to check its own
work against the running site (curl, Playwright screenshots, or a browser at
a real URL).

- [**Cloud environment**](docs/cloud-environment.md) — Anthropic-hosted
  sandbox. Fresh container per session, root user, restricted network. Works
  out of the box for any Team/Enterprise/Pro plan with cloud sessions enabled.
- [**Self-hosted runner**](docs/self-hosted-runner.md) — a runner you host
  yourself (for example in a [coder.ddev.com](https://ddev.com/blog/coder-ddev-com-announcement/)
  workspace). Sessions run on your own machine as your own user, with your
  own network and a persistent DDEV database between sessions. Public beta,
  Team/Enterprise only.

Both guides work through the same worked example: DDEV's own
[Drupal 11 quickstart](https://docs.ddev.com/en/stable/users/quickstart/#drupal),
a minimal `drupal/recommended-project` install. Neither guide nor this repo
commits that project's files. The cloud guide builds it fresh in the checkout;
the self-hosted guide builds it in a persistent sibling directory so runner
branch resets cannot alter it. The pattern applies to any DDEV-managed PHP
project. Where a step is genuinely project-specific (a project name, a
docroot, an install profile), swap in your own.

## Does an environment need a repository?

Yes. Both Claude Code on the web and self-hosted environments are created
**for a specific GitHub repository** — the cloud sandbox checks it out at
`/workspace/<repo>`; a self-hosted runner clones it under its `--base-dir`.
There's no way to point a session at "just a directory" with no repo behind
it.

That's what this repo is for: a minimal, generic anchor repo you can attach
an environment to. It carries no project of its own — just these two guides
— and its instructions build a throwaway DDEV/Drupal project inside the
checkout on first run. If you already have a DDEV project in its own repo,
attach the environment to that instead and adapt the project-specific
details (project name, docroot, install command) in these guides to it.

## Which guide should I use?

| | Cloud environment | Self-hosted runner |
| --- | --- | --- |
| Where it runs | Anthropic's sandbox | Your own host |
| Setup effort | One setup script, pasted into environment settings | A runner process, a startup script, a Coder (or other) workspace |
| Network | Full, but only ports 80/443 | Whatever your host allows |
| Seeing the site yourself | Not possible — only curl/Playwright from inside the session | Yes, at a real URL |
| State between sessions | None — fresh container each time | Persists — same checkout, same DDEV database |
| Who can use it | Any Pro/Team/Enterprise plan with cloud sessions | Team/Enterprise only, and you host the compute |

Start with the cloud environment guide if you're not sure which you need —
it has no infrastructure to stand up.
