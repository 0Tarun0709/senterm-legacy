# senterm

a project-first macos terminal built with swiftui and swiftterm.

## run and install

install the macos command line developer tools and swift 6.2, then run:

```sh
./scripts/run
```

the script builds an optimized release and opens `.build/SenTerm.app`. to install it, quit the app and copy that bundle to your applications folder. rebuild and replace the copy to update it. the app is unsigned and is not distributed through the app store.

## use

- select the sidebar plus or press shift-command-n to open a new session. select a project folder. a new project starts with one shell named `terminal`.
- select a project name to collapse it. use the new terminal button above the terminal to add a shell to the current project. right-click a project or terminal to rename, reorder, or remove it. project removal does not delete files.
- use command-t to open a tab in the selected project. use shift-command-[ and shift-command-] to switch tabs, or command-[ and command-] to cycle panes. use the split controls above a tab to start a new shell to the right or below the focused pane. close a pane with the header button or close its entire tab from the sidebar. both controls ask for confirmation. `exit` closes its own pane. when the last pane closes, the tab closes.
- use command-option-arrow to focus a pane and command-control-arrow to move its split divider. use command-control-= to equalize the splits. use shift-command-return to zoom the focused pane or restore the splits. zoom does not stop any shells.
- use command-f to search the focused pane’s output. use command-e to search from the selection, command-g and shift-command-g to move between matches, and shift-command-f to close search.
- use command-up and command-down to jump between prompts in shells that report prompt marks. the header shows the current directory when the shell reports it.
- open the command palette with shift-command-p. use it to find tabs and change the font size.
- click the waveform button to list local foreground and background processes started in senterm, grouped by project. click a process to see its cpu usage, resident memory, elapsed time, and tcp listening addresses for it and its child processes. click `go to terminal` to focus its pane. this view also shows osc 7501 program reports. click the waveform again to return to projects.

new splits start in the focused shell’s local working directory when it is available. new tabs start in the project folder. closing a pane asks for confirmation and sends a stop signal to jobs in its terminal session; a job that detached or ignores the signal can keep running.

senterm asks before a paste that could run commands immediately. multiline paste does not prompt when the program uses bracketed paste and the text cannot end that mode early.

in **settings → terminal**, set how many lines to keep in scrollback (default: 10,000). use **export scrollback…** in the command palette to save the focused pane’s transcript as plain text. you can also enable **quick terminal** (control-option-t to bring the running app forward) and **long command notifications** (zsh commands of at least 10 seconds that finish in inactive panes; requires macos permission).

projects, names, order and settings are saved locally. terminals start when first selected. commands and scrollback are not restored on app launch. keep important work saved before quitting or removing a terminal.

## side-by-side git diffs

in a new senterm zsh shell, run `git diff` to open the git changes viewer for the shell's current repository. run `git diff --staged` or `git diff --cached` to open staged changes. this requires automatic zsh integration.

piped and redirected diffs still work as usual. diffs with other options or paths still run in the terminal, with delta as the interactive diff pager if it is installed in a standard homebrew location. use `git --no-pager diff` for the original unified format. senterm does not change your git config.

in the diff viewer, click the comment icon next to an old or new line. use **review comments** in the footer to edit or delete saved notes. if the diff changes, use **review comments** to find notes that no longer have an inline marker.

for a handoff without copy and paste, run `./scripts/install-review-cli` once. this installs the read-only `senterm review list` command at `~/.local/bin/senterm` and the `senterm-review` skill in your pi user skills directory. reload pi in the worktree you reviewed. say **“look at my review comments”** or **“address my review comments.”** no project setup is necessary. if pi does not select the skill, use `/skill:senterm-review`. the command needs local read access to the worktree's git directory.

## zsh integration

new zsh tabs and panes in the bundled app report their current directory and prompt positions automatically. senterm loads your normal startup files and does not edit them. to disable the integration for new shells, open **settings → terminal** and turn off **automatic zsh integration**. if you previously added the senterm integration to `.zshrc` manually, remove that line to disable it completely.

## gpu rendering

terminal panes use swiftterm’s metal renderer. if it cannot start, senterm uses core graphics. to turn metal off for troubleshooting, quit senterm and run `open .build/SenTerm.app --args -disableMetal YES` from this directory.

## performance benchmarks

run `python3 scripts/benchmark.py` on macos with ghostty installed in `/Applications` and screen recording permission already granted. keep the display awake and avoid switching spaces during the run. the suite builds a release copy and uses disposable windows and shells, one trial at a time. it prints the temporary directory containing per-trial results and raw logs. no global key events are injected.

three trials per renderer compare pty readiness, idle memory, app cpu, captured tui updates at 8 and 30 hz (with and without scrolling logs), and pty reply time for colored, plain, unicode, and escape-heavy output. the libghostty test hosts the preview view on its own. capture timing includes macos capture delivery; a missing capture does not imply lost terminal output.

use `--split-only` for the senterm probe. it covers local key handling to shell echo, scroll viewport state, split and tab focus, and app resources with six idle projects. it runs smoke checks for `vim`, `tmux`, and `vttest` (the last two must be on `PATH`). see [benchmark results](benchmarks.md).

## output benchmark

run `python3 scripts/benchmark-output.py /tmp/senterm-output.json` from this directory inside senterm. run the same command in ghostty with a different output file and a similar pane size. the test measures time until the terminal answers a cursor position query, with and without 10,000 lines of colored output. it measures output processing, not when pixels appear on screen. use a disposable tab: the test fills its scrollback. pass line counts after the output path to override the defaults, for example `python3 scripts/benchmark-output.py /tmp/senterm-output.json 100000`.

the split-window test also measures shell reply and tab focus while another pane streams logs. these timings do not measure physical keystrokes or screen updates, and are not directly comparable to the output benchmark.

## libghostty preview

relaunch with `./scripts/run`, then choose **file → open libghostty preview…**. this opens a separate terminal window in the selected project folder, or your home folder if no project is selected. it uses libghostty-vt for terminal emulation and a basic appkit renderer. normal project panes still use swiftterm. the preview does not use ghostty’s gpu renderer or include senterm’s project-pane integrations.

for the headless benchmark, run `./scripts/probe-libghostty 0 10000 100000` from this directory. it checks the download against a pinned sha256 checksum and builds a local test against ghostty’s official `libghostty-vt` 1.0.0 macos library. the test feeds colored output from a real 80×24 pseudo-terminal into the library and sends cursor-position replies back. it needs python 3 and the macos command line tools, not xcode or zig.

the benchmark measures output processing, not rendering speed.

## keyboard shortcuts

open **settings → shortcuts** to change command, tab, pane, and search shortcuts. edit an assignment such as `find in terminal = cmd+option+f` and click **save**. use `none` to disable an action's shortcut. these are senterm assignments, not ghostty config files.

## process icons

the sidebar and terminal header show the logo for pi, claude code, codex, deepseek, grok, babuska, pnpm, bun, uv, ngrok, or go when senterm detects that command. other supported agents use sparkles. a foreground process without a logo that listens on a tcp port gets a server icon. the default terminal icon returns when the process stops. hover over the icon for its name.

detection covers local foreground jobs only. senterm cannot tell which model an agent uses or see jobs inside ssh or tmux.

supported terminal agents: [pi](https://pi.dev/), [claude code](https://code.claude.com/docs/en/quickstart), [codex](https://developers.openai.com/codex/cli), [openclaw](https://docs.openclaw.ai/cli), [opencode](https://opencode.ai/docs/cli), [gemini cli](https://geminicli.com/docs/), [qwen code](https://github.com/QwenLM/qwen-code), [aider](https://aider.chat/docs/usage.html), [goose](https://github.com/block/goose), [amp](https://ampcode.com/docs), [cursor cli](https://cursor.com/docs/cli/overview), [github copilot cli](https://docs.github.com/en/copilot/how-tos/copilot-cli), [factory droid](https://docs.factory.com/droid-cli/quickstart), and [kiro cli](https://kiro.dev/docs/cli/).

## shell colors

click the gear at the bottom of the sidebar or press `command-,` to preview and select a terminal theme: high contrast (default), ocean, paper, or original. themes update open panes, the sidebar, toolbar, command palette, settings, and git diff windows. high contrast keeps the original app colors. your selection is saved for future launches. themes change the ansi colors, not which words your shell highlights. programs that set their own rgb colors can keep them.

to use a ghostty theme, click **import ghostty theme…** and select a theme file. senterm imports its foreground, background, cursor and selection colors, and ansi colors 0–15. it does not import other ghostty settings. click **use preset** to return to your built-in theme.

swiftterm displays the colors that programs send. your shell supplies command syntax highlighting.

fish highlights commands by default. for zsh, install [zsh-syntax-highlighting](https://github.com/zsh-users/zsh-syntax-highlighting/blob/0.8.0/INSTALL.md) and load it last in your `.zshrc`. use `TERM_PROGRAM=senterm` to limit it to senterm. do not load it again if your shell already loads it.

## checks

```sh
swift build
swiftc sources/senterm/{projects,activity,agent-processes}.swift tests/senterm-tests/projects-tests.swift -o /tmp/senterm-tests && /tmp/senterm-tests
```

manual smoke check: add two temporary project folders; run `pwd` in each and confirm the correct path. run a long-lived command in one, switch to another and back, and check that it continues. split a tab in both directions, switch away, then return. enter `exit` in one pane and confirm that the other panes stay open. send a report with `printf '\033]7501;state=working:app=demo\033\\'` and check the eye view. close another terminal from the sidebar and check that cancel keeps it open. rename and reorder items, relaunch, and verify the saved layout. finally remove or rename a project folder and verify the missing-folder message.
