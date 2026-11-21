# senterm legacy

**a project-first terminal for macos, with a built-in git review workflow.**

keep your dev server, coding agent, and shell together under their project folder instead of hunting across terminal windows. when the code is ready, run `git diff`, review it side by side, and leave inline notes for your agent.

[get started](#get-started) · [review a diff](#review-a-diff) · [user guide](docs/usage.md) · [benchmarks](benchmarks.md)

## what you can do

- **organize by project.** group named tabs by folder, split them into independent shell panes, and switch projects without interrupting running jobs.
- **see what’s running.** identify supported agents and servers by their icons. inspect local processes for cpu, memory, elapsed time, and listening tcp ports.
- **review code in a separate window.** browse staged, unstaged, and untracked changes with side-by-side diffs, change totals, and inline review notes.
- **make the terminal yours.** customize shortcuts and whole-window themes, search or export scrollback, and use metal rendering with a core graphics fallback.

## get started

build from source on macos with apple’s command line developer tools and a swift 6.2 or newer toolchain. full xcode is not required.

```sh
git clone https://github.com/0Tarun0709/senterm-legacy.git
cd senterm-legacy
./scripts/run
```

the script builds and opens `.build/SenTerm.app`. to keep the unsigned app in `/Applications`, quit it and copy the bundle there. rebuild and replace the copy to update it.

in senterm, press `shift-command-n` and pick a project folder. it opens one shell named `terminal`. use `command-t` to add a tab, `command-d` to split right, or `shift-command-d` to split down. open the command palette with `shift-command-p`.

project folders, tab names, and settings are saved. running shells and scrollback are not restored after quitting.

## review a diff

1. in a senterm zsh pane with automatic zsh integration enabled, run `git diff` for unstaged changes or `git diff --staged` for staged changes.
2. pick a file in the viewer. hover over a changed line to add a note. use **review comments** in the footer to edit or delete saved notes.
3. to hand off notes to pi, run `./scripts/install-review-cli` once from the senterm source checkout. reload pi in the worktree you reviewed and say **“look at my review comments”** or **“address my review comments.”** if pi doesn’t select the skill, use `/skill:senterm-review`.

review notes are stored locally in the worktree’s git directory. they don’t appear in `git diff`, and senterm doesn’t send them to pi automatically. piped or redirected diffs still work normally; use `git --no-pager diff` to print a unified diff in the pane.

## project status

this repository preserves the original [swiftterm](https://github.com/migueldeicaza/SwiftTerm)-based app. it is not a ghostty fork. the optional libghostty-vt preview uses a separate renderer and is not the default terminal engine.

see the [user guide](docs/usage.md) for settings, troubleshooting, and development checks, and the [benchmark results](benchmarks.md) for measured performance and test limits. report bugs or ask questions in [github issues](https://github.com/0Tarun0709/senterm-legacy/issues).
