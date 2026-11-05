# Linux Terminal, Shortcuts and Useful Commands (Ubuntu, bash)

A practical reference for daily embedded work: moving around the command line, editing commands quickly, finding things, controlling processes, talking to serial devices, and driving the toolchain.

Assumptions: Ubuntu with GNOME Terminal, **bash** (default), GNU coreutils. Most things also work in other distros and terminals. Keys written `Ctrl+A` mean "hold Ctrl and press A"; `Alt+B` means "hold Alt and press B" (some terminals send `Esc` then `B` instead).

---

## 1. Moving the cursor and editing the command line (readline)

Bash uses the **readline** library in "emacs mode" by default. These shortcuts work in bash, in `gdb`, in `python`, in `psql`, and in many other programs that use readline.

### 1.1 Move

| Keys | Action |
|---|---|
| `Ctrl+A` or `Home` | Start of line |
| `Ctrl+E` or `End` | End of line |
| `Ctrl+B` or `Left` | One character back |
| `Ctrl+F` or `Right` | One character forward |
| `Alt+B` or `Ctrl+Left` | One word back |
| `Alt+F` or `Ctrl+Right` | One word forward |
| `Ctrl+X Ctrl+X` | Toggle between the start of line and the current position |
| `Ctrl+L` | Clear the screen (the line you are editing stays) |

### 1.2 Delete, cut and paste ("kill ring")

Things you delete with the "kill" commands are stored and can be pasted back (`yank`).

| Keys | Action |
|---|---|
| `Ctrl+U` | Cut from the cursor to the **start** of the line |
| `Ctrl+K` | Cut from the cursor to the **end** of the line |
| `Ctrl+W` | Cut the **word before** the cursor (space-delimited) |
| `Alt+Backspace` | Cut the word before the cursor (punctuation-delimited, e.g. stops at `/`) |
| `Alt+D` | Cut the word **after** the cursor |
| `Ctrl+D` | Delete the character under the cursor (on an empty line: exit the shell or send EOF) |
| `Ctrl+H` or `Backspace` | Delete the character before the cursor |
| `Ctrl+Y` | Paste (yank) the last cut text |
| `Alt+Y` | After `Ctrl+Y`: cycle through older cuts |
| `Ctrl+_` or `Ctrl+X Ctrl+U` | Undo |
| `Alt+R` | Revert all changes made to this history line |

### 1.3 Transform text

| Keys | Action |
|---|---|
| `Ctrl+T` | Swap the character before the cursor with the one under it (fix typos like `sl` → `ls`) |
| `Alt+T` | Swap the two words around the cursor |
| `Alt+U` | Uppercase from the cursor to the end of the word |
| `Alt+L` | Lowercase from the cursor to the end of the word |
| `Alt+C` | Capitalize the word |
| `Ctrl+V` then a key | Insert the next key literally (e.g. `Ctrl+V` `Tab` inserts a real TAB, needed in Makefiles at the command line) |
| `Alt+#` | Comment out the line and press Enter (saves it in history without running it) |

### 1.4 Edit in your editor

`Ctrl+X Ctrl+E` opens the current line in `$EDITOR` (set `export EDITOR=nano` or `vim`). When you save and quit, the command runs. Perfect for long commands or multi-line scripts.

### 1.5 History and search

| Keys | Action |
|---|---|
| `Up` / `Ctrl+P` | Previous command |
| `Down` / `Ctrl+N` | Next command |
| **`Ctrl+R`** | **Reverse incremental search**: type part of an old command; `Ctrl+R` again for the next older match; `Enter` to run, `Right`/`Esc` to edit, `Ctrl+G` to cancel |
| `Ctrl+S` | Forward search (needs `stty -ixon`, see section 1.9) |
| `Alt+<` / `Alt+>` | First / last history entry |
| **`Alt+.`** (or `Alt+_`) | Insert the **last argument of the previous command**; press again to go further back |
| `Alt+Ctrl+Y` | Insert the **first argument** of the previous command |
| `Alt+*` | Expand the glob before the cursor (shows what `*.c` expands to) |
| `Alt+?` or `Tab Tab` | List possible completions |
| `Alt+/` | Complete the file name |
| `Ctrl+O` | Run the current line and bring up the next history line (replay a sequence) |

### 1.6 Completion (Tab)

- `Tab` completes commands, files, variables (`$HO<Tab>` → `$HOME`), and with the `bash-completion` package also options and arguments for `git`, `apt`, `systemctl`, `cmake`, `ssh`, etc. (`sudo apt install bash-completion`).
- `Tab Tab` shows the alternatives.
- `Alt+!` completes command names, `Alt+~` user names, `Alt+@` host names, `Alt+$` variables.

### 1.7 Control keys (not readline: they talk to the terminal and the running program)

| Keys | Action |
|---|---|
| **`Ctrl+C`** | Interrupt (SIGINT) the running program |
| **`Ctrl+Z`** | Suspend (SIGTSTP) the program and return to the prompt; then `bg` or `fg` |
| `Ctrl+D` | End of input (EOF). Exits a shell |
| `Ctrl+\` | Quit (SIGQUIT, with core dump): when `Ctrl+C` does not stop a program |
| `Ctrl+S` / `Ctrl+Q` | Freeze / resume terminal output (XOFF/XON). If the terminal "hangs", press `Ctrl+Q` |
| `Ctrl+L` | Clear the screen |
| `Ctrl+Shift+U` then hex code and Enter/Space | Type a Unicode character in GTK terminals (e.g. `Ctrl+Shift+U` `00e9` → é) |

### 1.8 History expansion with `!`

| Syntax | Meaning |
|---|---|
| `!!` | The whole previous command |
| **`sudo !!`** | Repeat the previous command with `sudo` |
| `!$` | Last argument of the previous command |
| `!^` | First argument of the previous command |
| `!*` | All arguments of the previous command |
| `!n` | Command number `n` in `history` |
| `!-2` | Two commands back |
| `!make` | The most recent command starting with `make` |
| `!?cmake?` | The most recent command containing `cmake` |
| `^old^new` | Repeat the previous command replacing the first `old` with `new` |
| `!!:s/old/new/` | Same, written fully; `:gs/old/new/` replaces all |
| `!!:0`, `!!:1`, `!!:2` | Command name, first argument, second argument |
| `mkdir foo && cd !$` | Create a directory and enter it |
| `history \| grep openocd` | Search the history |
| `history -d N` | Delete an entry |

To preview without running: add `:p` (e.g. `!!:p`).

### 1.9 Make the terminal behave better (`~/.bashrc` and `~/.inputrc`)

`~/.bashrc`:

```bash
stty -ixon                         # free Ctrl+S for forward history search, no accidental freeze
shopt -s histappend                # append to history instead of overwriting
shopt -s checkwinsize              # update LINES/COLUMNS after resizing
shopt -s globstar                  # ** matches directories recursively
shopt -s cdspell                   # fix small typos in cd
HISTSIZE=50000
HISTFILESIZE=100000
HISTCONTROL=ignoreboth:erasedups   # no duplicates, no commands starting with a space
HISTTIMEFORMAT='%F %T  '           # timestamps in `history`
export EDITOR=nano
```

`~/.inputrc` (applies to all readline programs):

```
set show-all-if-ambiguous on        # list completions with one Tab
set completion-ignore-case on
set colored-stats on
set mark-symlinked-directories on
"\e[A": history-search-backward     # Up arrow searches history by the typed prefix
"\e[B": history-search-forward
```

With the last two lines, type `git c` and press `Up`: it cycles only through history lines starting with `git c`.

Reload: `source ~/.bashrc`. For `~/.inputrc`: `bind -f ~/.inputrc` or open a new terminal.

A command typed with a **leading space** is not saved in history (with `ignorespace`/`ignoreboth`): useful for commands containing secrets.

### 1.10 Vi mode (optional)

```bash
set -o vi            # in the shell (or: set editing-mode vi in ~/.inputrc)
set -o emacs         # back to the default
```

In vi mode: `Esc` for command mode, then `h l w b 0 $` to move, `x dw dd` to delete, `i a` to insert, `/text` to search history. Choose one style and stick to it.

---

## 2. Terminal emulator and desktop shortcuts

### 2.1 GNOME Terminal (Ubuntu)

| Keys | Action |
|---|---|
| `Ctrl+Alt+T` | Open a terminal (Ubuntu desktop) |
| **`Ctrl+Shift+C` / `Ctrl+Shift+V`** | Copy / paste (plain `Ctrl+C` interrupts!) |
| `Shift+Insert` | Paste |
| Select text with the mouse, **middle click** | Paste the selection (X11 primary selection) |
| Double-click / triple-click | Select a word / a whole line |
| `Ctrl+Shift+T` | New tab |
| `Ctrl+Shift+N` | New window |
| `Ctrl+Shift+W` | Close tab |
| `Ctrl+Shift+Q` | Close window |
| `Alt+1` ... `Alt+9` | Go to tab 1..9 |
| `Ctrl+PageUp` / `Ctrl+PageDown` | Previous / next tab |
| `Ctrl+Shift+PageUp` / `PageDown` | Move the tab left / right |
| `Shift+PageUp` / `Shift+PageDown` | Scroll the output |
| `Ctrl+Shift+F` | Search in the output |
| `Ctrl+Shift+G` / `Ctrl+Shift+H` | Find next / previous (after a search) |
| `Ctrl+Shift+A` | Select all |
| `Ctrl++`, `Ctrl+-`, `Ctrl+0` | Zoom in, out, reset |
| `F11` | Full screen |
| `F10` | Menu |

### 2.2 Ubuntu / GNOME desktop

| Keys | Action |
|---|---|
| `Super` (Windows key) | Activities overview, type to launch or search |
| `Alt+Tab` / `Alt+Shift+Tab` | Switch application |
| ``Alt+` `` (key above Tab) | Switch between windows of the same application |
| `Super+Left` / `Right` | Tile the window left / right |
| `Super+Up` / `Down` | Maximize / restore |
| `Ctrl+Alt+Left` / `Right` (or `Super+PageUp/PageDown`) | Switch workspace |
| `Ctrl+Alt+Shift+Left` / `Right` | Move the window to another workspace |
| `Super+L` | Lock the screen |
| `Alt+F2` | Run a command |
| `Alt+F4` | Close window |
| `PrtSc` | Screenshot tool |

### 2.3 Typing special characters on a Spanish (ES) keyboard

| Character | Keys |
|---|---|
| `\|` | `AltGr+1` |
| `@` | `AltGr+2` |
| `#` | `AltGr+3` |
| `~` | `AltGr+4` (then press the space bar to produce a standalone `~`) |
| `\` | `AltGr+º` |
| `[` / `]` | `AltGr+` `` ` `` (the grave key right of P) / `AltGr++` |
| `{` / `}` | `AltGr+´` (the acute key) / `AltGr+ç` |
| `` ` `` | The grave key (right of P), then space |
| `<` / `>` | The key left of Z / with Shift |
| `&` `/` `(` `)` `=` | `Shift+6/7/8/9/0` |
| `$` | `Shift+4` |
| `_` `:` `;` | `Shift+-`, `Shift+.`, `Shift+,` |
| `'` | The key right of 0 |
| `"` | `Shift+2` |

If one of these is a problem in a terminal, check the layout in Settings, or use `Ctrl+Shift+U` + the Unicode code.

---

## 3. Navigating the file system

| Command | What it does |
|---|---|
| `pwd` | Print the current directory |
| `cd dir` | Enter a directory |
| `cd` or `cd ~` | Go home |
| **`cd -`** | Go back to the previous directory |
| `cd ..` / `cd ../..` | Up one / two levels |
| `pushd dir` / `popd` / `dirs -v` | Directory stack: jump and come back |
| `ls` | List |
| `ls -la` | Long format, including hidden files |
| `ls -lh` | Human-readable sizes |
| `ls -lt` / `ls -ltr` | Sort by time (newest first / oldest first) |
| `ls -lS` | Sort by size |
| `ls -R` | Recursive |
| `ls -d */` | Only directories |
| `tree -L 2` | Tree view, two levels (`sudo apt install tree`) |
| `du -sh *` | Size of each item in the current directory |
| `du -ah . \| sort -h \| tail -20` | The 20 largest files/dirs |
| `df -h` | Free space on each filesystem |
| `ncdu` | Interactive disk usage viewer (`sudo apt install ncdu`) |
| `stat file` | Detailed info (size, permissions, times) |
| `file name` | Detect the file type (e.g. `ELF 32-bit LSB executable, ARM`) |
| `which cmd` / `type cmd` / `command -v cmd` | Where a command comes from |
| `realpath file` / `readlink -f link` | Absolute path, resolving links |
| `basename path` / `dirname path` | Last component / directory part |

Special paths: `.` current dir, `..` parent, `~` home, `-` previous dir (with `cd`), `/` root.

Handy quoting rule for paths: **always quote variables** that may contain spaces, `"$dir/file"`.

---

## 4. Files and directories

### 4.1 Create, copy, move, delete

```bash
mkdir -p a/b/c                 # create nested directories, no error if they exist
touch file.txt                 # create empty file / update timestamp
cp file copy                   # copy
cp -r dir dir_copy             # copy a directory recursively
cp -a src/ dst/                # archive copy (keeps permissions, times, links)
cp -u -v a b                   # only newer, verbose
mv old new                     # rename or move
mv -n a b                      # do not overwrite
rm file                        # delete a file
rm -r dir                      # delete a directory (careful)
rm -rf build                   # recursive, no questions (careful!)
rm -i file                     # ask first
rmdir empty_dir               # delete an empty directory
ln -s target linkname          # symbolic link
ln target hardlink             # hard link
```

**Safety**: there is no trash in the terminal. Check with `ls` or `echo rm -rf build/*` first. Be extremely careful with `rm -rf` and variables (`rm -rf "$DIR/"` with an empty `$DIR` becomes `rm -rf /`). In scripts use `set -u`.

### 4.2 Permissions

```bash
ls -l file                     # -rwxr-xr-- : type, owner rwx, group r-x, others r--
chmod +x script.sh             # make executable
chmod 644 file                 # rw-r--r--
chmod 755 dir_or_script        # rwxr-xr-x
chmod u+rw,go-w file           # symbolic form
chmod -R g+rX dir              # recursive; X = x only for directories/already-executable
sudo chown user:group file
sudo chown -R $USER: dir       # take ownership of a directory
umask                          # default permission mask
```

Octal: `r=4 w=2 x=1`; `755 = rwx r-x r-x`, `644 = rw- r-- r--`, `600 = rw- --- ---`. Avoid `chmod 777`.

### 4.3 Viewing files

| Command | Use |
|---|---|
| `cat file` | Print the file |
| `cat -A file` | Show tabs (`^I`), line ends (`$`): ideal for Makefile tab problems |
| `less file` | Page through a file (see below) |
| `head -n 20 file` / `tail -n 20 file` | First / last lines |
| **`tail -f file`** | Follow a growing file (logs) |
| `tail -F file` | Follow and re-open on rotation |
| `wc -l file` | Count lines (`-w` words, `-c` bytes) |
| `nl file` | Print with line numbers |
| `bat file` | Colorized viewer (Ubuntu command is `batcat`) |
| `xxd file \| head` / `hexdump -C file \| head` | Hex dump (inspect a `.bin`) |
| `od -An -tx4 -N 16 file` | First 16 bytes as 32-bit hex words |
| `strings file` | Printable strings inside a binary |
| `column -t file` | Align columns |

`less` keys: `Space`/`b` page down/up, `j`/`k` or arrows line, `g` / `G` start / end, `/text` search forward, `?text` backward, `n` / `N` next / previous match, `&pattern` show only matching lines, `-N` toggle line numbers, `-S` toggle line wrapping, `F` follow (like `tail -f`, `Ctrl+C` to stop), `v` edit in `$EDITOR`, `q` quit.

### 4.4 Compare and checksum

```bash
diff -u old.c new.c            # unified diff
diff -ru dirA dirB             # recursive diff of directories
colordiff, vimdiff, meld       # visual diff tools
cmp a.bin b.bin                # first differing byte
sha256sum file ; md5sum file   # checksums (reproducible builds)
sha256sum -c sums.txt          # verify
```

### 4.5 Archives and transfer

```bash
tar czf backup.tar.gz dir/     # create gzip tar
tar xzf backup.tar.gz          # extract
tar xzf backup.tar.gz -C /dest # extract in another place
tar tf backup.tar.gz           # list contents
tar cJf out.tar.xz dir/        # xz compression (smaller)
zip -r out.zip dir/ ; unzip out.zip -d dest/
gzip file ; gunzip file.gz
rsync -avh --progress src/ dst/            # copy/sync (trailing slash on src matters)
rsync -avh --delete src/ user@host:/dst/   # mirror, deleting extra files at the destination
scp file user@host:/path/                  # secure copy
```

---

## 5. Searching

### 5.1 Find files: `find`

```bash
find . -name "*.c"                          # by name (quote the pattern)
find . -iname "*.MD"                        # case-insensitive
find . -type f -name "*.elf"
find . -type d -name build
find . -type f -mtime -1                    # modified in the last day
find . -type f -newer Makefile              # newer than a file
find . -type f -size +1M
find . -name "*.o" -delete                  # delete matches (careful)
find . -name "*.c" -exec wc -l {} +         # run a command on the results
find . -name "*.c" -print0 | xargs -0 grep -n "SysTick"   # safe with spaces in names
find . -path ./build -prune -o -name "*.c" -print        # skip a directory
```

`fd` is a friendlier alternative (`sudo apt install fd-find`; the command is `fdfind`): `fdfind '\.c$'`.

`locate name` finds files by name in a prebuilt database (`sudo updatedb` to refresh).

### 5.2 Search inside files: `grep` and `ripgrep`

```bash
grep -n "SysTick" main.c                   # with line numbers
grep -rn "SysTick" src/                    # recursive
grep -rn --include="*.[ch]" "TODO" .       # only C sources and headers
grep -rn --exclude-dir=build --exclude-dir=.git "FPU" .
grep -i "error" log.txt                    # ignore case
grep -w "main" file                        # whole word
grep -v "^#" file                          # invert: lines NOT matching
grep -c "pattern" file                     # count matching lines
grep -l "pattern" *.c                      # only file names
grep -A3 -B3 "pattern" file                # 3 lines of context after/before (-C3 both)
grep -E "foo|bar" file                     # extended regex
grep -F "a.b" file                         # fixed string, no regex
```

**`rg` (ripgrep)** is faster and respects `.gitignore`: `sudo apt install ripgrep`, then `rg -n "SysTick"`, `rg -t c "TODO"`, `rg -g '!build' pattern`.

Quick regex reminders: `.` any char, `*` repeat, `^` start, `$` end, `[a-z]`, `\b` word boundary, `\d` (PCRE with `grep -P`), `()` group, `|` or (with `-E`).

### 5.3 Text processing toolbox

```bash
sed 's/old/new/g' file                     # print with substitution
sed -i 's/old/new/g' file                  # edit in place (use -i.bak to keep a backup)
sed -n '10,20p' file                       # print lines 10-20
sed '/pattern/d' file                      # delete matching lines
awk '{print $1, $3}' file                  # print columns 1 and 3
awk -F: '{print $1}' /etc/passwd           # custom field separator
awk '$3 > 100 {print $0}' file             # condition on a column
cut -d, -f1,3 data.csv                     # columns by delimiter
sort file ; sort -n ; sort -u ; sort -k2 -n ; sort -h    # sorting options
uniq -c                                    # count adjacent duplicates (use after sort)
tr 'a-z' 'A-Z' < file                      # translate characters
tr -d '\r' < dos.txt > unix.txt            # remove carriage returns
paste a b ; join a b                       # combine files
tee out.txt                                # copy stdin to a file and stdout
xargs -n1 cmd                              # run cmd for each input item
```

Examples for embedded work:

```bash
# biggest symbols in the firmware
arm-none-eabi-nm -S --size-sort -C build/blink.elf | tail -20

# replace a name across the project
grep -rl "old_name" src/ | xargs sed -i 's/old_name/new_name/g'

# lines of code per file
find src -name "*.[ch]" | xargs wc -l | sort -n | tail

# functions defined in a map file section
awk '/\.text/ && NF==4 {print $0}' build/blink.map | head

# convert a file with Windows line ends
sed -i 's/\r$//' file.c
```

---

## 6. Pipes, redirection, and the shell language

### 6.1 Redirection

| Syntax | Meaning |
|---|---|
| `cmd > file` | stdout to file (overwrite) |
| `cmd >> file` | stdout appended |
| `cmd < file` | stdin from file |
| `cmd 2> err.txt` | stderr to file |
| `cmd > out.txt 2>&1` or `cmd &> out.txt` | stdout and stderr to the same file |
| `cmd 2>&1 \| less` or `cmd \|& less` | Pipe both streams |
| `cmd > /dev/null 2>&1` | Discard all output |
| `cmd1 \| cmd2` | Output of `cmd1` is the input of `cmd2` |
| `cmd \| tee file` | See the output and save it |
| `cmd \| tee -a file` | Append |
| `cat <<EOF > file` ... `EOF` | Here-document (write several lines) |
| `cmd <<< "text"` | Here-string |
| `diff <(cmd1) <(cmd2)` | Process substitution: compare two outputs |

Writing a file with a here-document (the quoted `'EOF'` stops variable expansion):

```bash
cat > CMakeLists.txt << 'EOF'
cmake_minimum_required(VERSION 3.16...4.2)
project(hola C)
add_executable(hola main.c)
EOF
```

### 6.2 Chaining commands

| Syntax | Meaning |
|---|---|
| `a ; b` | Run `a`, then `b` |
| `a && b` | Run `b` only if `a` succeeded |
| `a \|\| b` | Run `b` only if `a` failed |
| `a & ` | Run `a` in the background |
| `( cmd1; cmd2 )` | Run in a subshell (its `cd` does not affect you) |
| `{ cmd1; cmd2; }` | Group in the current shell |
| `$?` | Exit status of the last command (0 = success) |
| `cmd1 && cmd2 \|\| cmd3` | Rough if/else |

This is why `mkdir cmake && cd cmake` did not enter the directory when `mkdir` failed.

### 6.3 Expansions

```bash
echo *.c                  # glob: all .c files
echo file?.c              # one character
echo file[0-9].c          # a character class
echo **/*.c               # recursive (needs shopt -s globstar)
echo {a,b,c}.txt          # brace expansion: a.txt b.txt c.txt
echo {1..5}               # 1 2 3 4 5
mkdir -p src/{drivers,hal,app} tests build   # create several directories
cp file.c{,.bak}          # cp file.c file.c.bak
echo ~                    # home directory
echo $(date +%F)          # command substitution
echo "$(( 3 * 7 ))"       # arithmetic
echo "${var:-default}"    # default if unset
echo "${path##*/}"        # strip the longest prefix up to the last / (basename)
echo "${file%.c}"         # strip the suffix .c
echo "${file/.c/.o}"      # replace
```

Quoting: `'single'` keeps everything literal; `"double"` allows `$variable` and `$(command)`; backslash escapes one character. **Quote your variables**: `"$file"`.

### 6.4 Variables and environment

```bash
name=value                # no spaces around =
echo "$name"
export PATH="$HOME/bin:$PATH"     # make a variable visible to child processes
env | grep ARM            # list the environment
printenv HOME
unset name
VAR=1 command             # set a variable only for one command
```

`PATH` is searched left to right for commands. Add toolchains permanently in `~/.bashrc`: `export PATH="$HOME/tools/arm-gnu-toolchain/bin:$PATH"`.

### 6.5 Aliases and functions (`~/.bashrc` or `~/.bash_aliases`)

```bash
alias ll='ls -alFh'
alias ..='cd ..'
alias ...='cd ../..'
alias gs='git status'
alias gl='git log --oneline --graph --decorate -20'
alias grep='grep --color=auto'
alias please='sudo $(history -p !!)'

# create a directory and enter it
mkcd() { mkdir -p "$1" && cd "$1"; }

# build with the ARM toolchain
fwbuild() { cmake --build "${1:-build}" -j"$(nproc)"; }
```

`alias` lists them; `unalias name` removes; `\ls` bypasses an alias for one call.

### 6.6 Small script skeleton

```bash
#!/usr/bin/env bash
set -euo pipefail                 # stop on errors, undefined variables and failed pipes

usage() { echo "usage: $0 <elf>"; exit 1; }
[[ $# -eq 1 ]] || usage
ELF="$1"
[[ -f "$ELF" ]] || { echo "not found: $ELF" >&2; exit 2; }

for f in "$ELF" "${ELF%.elf}.bin"; do
    printf '%s  %s bytes\n' "$f" "$(stat -c %s "$f")"
done
```

`chmod +x script.sh && ./script.sh build/blink.elf`. Check scripts with `shellcheck script.sh` (`sudo apt install shellcheck`). Useful: `trap 'kill $PID 2>/dev/null' EXIT` to clean up background processes, `read -r var`, `case ... esac`, arrays `arr=(a b c); echo "${arr[@]}"`.

---

## 7. Processes and jobs

### 7.1 Job control

| Command / keys | Action |
|---|---|
| `cmd &` | Start in the background |
| `Ctrl+Z` | Suspend the foreground job |
| `jobs` | List jobs |
| `bg %1` / `fg %1` | Resume job 1 in the background / foreground |
| `kill %1` | Kill job 1 |
| `disown %1` | Detach the job from the shell (survives closing the terminal) |
| `nohup cmd > out.log 2>&1 &` | Run immune to hangup, with logging |
| `wait` | Wait for background jobs |

For long sessions that survive disconnections use `tmux` (section 9).

### 7.2 Inspect and stop

```bash
ps aux                          # all processes
ps aux | grep openocd           # find one
pgrep -a openocd                # PIDs and command lines by name
pkill openocd                   # kill by name
kill PID                        # SIGTERM (polite)
kill -9 PID                     # SIGKILL (last resort)
killall name
top ; htop                      # live view (htop: sudo apt install htop; F9 kill, F6 sort, q quit)
watch -n 1 'free -h'            # re-run a command every second
nice -n 10 cmd ; renice 5 -p PID
time cmd                        # how long a command takes
timeout 5 cmd                   # stop after 5 seconds
```

### 7.3 Who is using this port, file or device?

```bash
ss -tulpn                       # listening TCP/UDP sockets with processes
ss -tulpn | grep 3333           # who has the OpenOCD gdb port
sudo lsof -i :3333              # same, with lsof
lsof /dev/ttyACM0               # who has the serial port open
sudo fuser -v /dev/ttyACM0      # likewise
```

Typical embedded fixes: `pkill openocd; pkill st-util; pkill picocom` when the ST-LINK or a serial port is busy.

---

## 8. System, packages, and hardware information

### 8.1 System

```bash
uname -a ; cat /etc/os-release ; lsb_release -a
uptime ; free -h ; lscpu ; nproc
whoami ; id ; groups
sudo -i                          # root shell (use sparingly)
date ; timedatectl
journalctl -f                    # follow the system log
journalctl -u servicename -b     # one service, this boot
systemctl status servicename ; sudo systemctl restart servicename
```

### 8.2 Packages (apt)

```bash
sudo apt update                  # refresh package lists
sudo apt upgrade                 # upgrade installed packages
sudo apt install pkg1 pkg2
sudo apt remove pkg ; sudo apt purge pkg ; sudo apt autoremove
apt search keyword ; apt show pkg
apt list --installed | grep arm
dpkg -L pkg                      # files installed by a package
dpkg -S /usr/bin/arm-none-eabi-gcc   # which package owns a file
```

Packages used in these notes:

```bash
sudo apt install build-essential cmake ninja-build git gdb-multiarch openocd stlink-tools \
     gcc-arm-none-eabi binutils-arm-none-eabi libnewlib-arm-none-eabi libstdc++-arm-none-eabi-newlib \
     picocom minicom tmux htop tree ncdu ripgrep fd-find fzf bat shellcheck xxd bear \
     python3-pip python3-venv bash-completion
```

Python tools: prefer a virtual environment (`python3 -m venv .venv && source .venv/bin/activate`) or `pipx`; system-wide `pip` on recent Ubuntu needs `--break-system-packages`.

### 8.3 Hardware and USB

```bash
lsusb                            # USB devices (ST-LINK shows 0483:374b)
lsusb -t                         # USB tree
lsusb -v -d 0483:374b | less     # verbose details
dmesg -w                         # follow kernel messages (plug in a board and watch)
dmesg | tail -20
lsblk                            # block devices
ls /dev/ttyACM* /dev/ttyUSB*     # serial ports
ls -l /dev/serial/by-id/         # stable serial device names
udevadm monitor                  # watch device events
udevadm info -a -n /dev/ttyACM0  # properties, useful to write udev rules
```

### 8.4 Permissions for devices

```bash
groups                           # is dialout in the list?
sudo usermod -aG dialout $USER   # access to /dev/ttyACM0 (log out and in)
sudo cp /usr/share/openocd/contrib/60-openocd.rules /etc/udev/rules.d/
sudo udevadm control --reload-rules && sudo udevadm trigger     # then replug the board
```

---

## 9. tmux: terminal multiplexer

Keeps sessions alive when you close the terminal or lose SSH, and gives you panes and windows. Perfect for **OpenOCD + gdb + serial console** side by side.

Default prefix: **`Ctrl+B`**, then a key (release `Ctrl+B` before the key).

| Command / keys | Action |
|---|---|
| `tmux` or `tmux new -s name` | Start a (named) session |
| `tmux ls` | List sessions |
| `tmux attach -t name` (or `tmux a`) | Attach to a session |
| `tmux kill-session -t name` | Kill a session |
| `Ctrl+B d` | **Detach** (the session keeps running) |
| `Ctrl+B c` | New window |
| `Ctrl+B n` / `p` | Next / previous window |
| `Ctrl+B 0`..`9` | Go to window number |
| `Ctrl+B ,` | Rename the window |
| `Ctrl+B w` | Window/session picker |
| `Ctrl+B &` | Close window |
| `Ctrl+B %` | Split into left and right panes |
| `Ctrl+B "` | Split into top and bottom panes |
| `Ctrl+B` arrows | Move between panes |
| `Ctrl+B o` | Next pane |
| `Ctrl+B z` | Zoom the pane (toggle full screen) |
| `Ctrl+B x` | Close the pane |
| `Ctrl+B Space` | Cycle layouts |
| `Ctrl+B Ctrl+arrows` | Resize pane |
| `Ctrl+B [` | Scroll/copy mode (arrows, `PageUp`, `/` search, `q` quit) |
| `Ctrl+B ]` | Paste |
| `Ctrl+B :` | tmux command prompt |
| `Ctrl+B ?` | Help with all keys |

`~/.tmux.conf`:

```
set -g mouse on                      # click panes, scroll, resize with the mouse
set -g history-limit 50000
set -g base-index 1
setw -g pane-base-index 1
set -g default-terminal "tmux-256color"
bind | split-window -h               # easier split keys
bind - split-window -v
bind r source-file ~/.tmux.conf \; display "reloaded"
```

A debugging layout script for the Nucleo (OpenOCD, gdb and serial in one screen):

```bash
#!/usr/bin/env bash
S=dbg
tmux new-session -d -s $S -n main
tmux send-keys -t $S 'openocd -f interface/stlink.cfg -f target/stm32f7x.cfg' C-m
tmux split-window -h -t $S
tmux send-keys -t $S 'sleep 1; gdb-multiarch -q -x tools/gdb.cmds build/blink.elf' C-m
tmux split-window -v -t $S
tmux send-keys -t $S 'picocom -b 115200 /dev/ttyACM0' C-m
tmux attach -t $S
```

(Inside a tmux window, the `Ctrl+B` prefix and programs that also use `Ctrl+B` can conflict; send the prefix twice, `Ctrl+B Ctrl+B`, to pass it through.)

`screen` is the older equivalent (`Ctrl+A` prefix, `Ctrl+A d` detach, `screen -r` reattach).

---

## 10. Editors in the terminal

### 10.1 nano (easy)

| Keys | Action |
|---|---|
| `Ctrl+O`, `Enter` | Save |
| `Ctrl+X` | Exit (asks to save) |
| `Ctrl+W` | Search (`Alt+W` repeat) |
| `Ctrl+\` | Search and replace |
| `Ctrl+K` / `Ctrl+U` | Cut line / paste |
| `Alt+6` | Copy line |
| `Ctrl+_` | Go to line number |
| `Alt+U` / `Alt+E` | Undo / redo |
| `Ctrl+A` / `Ctrl+E` | Start / end of line |
| `Ctrl+Y` / `Ctrl+V` | Page up / page down |
| `Ctrl+G` | Help |

Tip: tabs in Makefiles: nano may insert spaces if configured; check with `cat -A Makefile`.

### 10.2 vim (powerful, worth learning the minimum)

Modes: **Normal** (default, commands), **Insert** (typing), **Visual** (selection), **Command-line** (`:`). `Esc` always returns to Normal.

| Keys | Action |
|---|---|
| `i` / `a` | Insert before / after the cursor |
| `I` / `A` | Insert at start / end of line |
| `o` / `O` | New line below / above |
| `Esc` | Back to Normal mode |
| `:w` / `:q` / `:wq` / `:x` | Save / quit / save and quit |
| `:q!` | Quit without saving |
| `h j k l` | Left, down, up, right |
| `w` / `b` / `e` | Next word / previous word / end of word |
| `0` / `^` / `$` | Start of line / first non-blank / end of line |
| `gg` / `G` / `42G` | First line / last line / line 42 |
| `%` | Jump to the matching bracket |
| `Ctrl+F` / `Ctrl+B` | Page down / up |
| `x` | Delete a character |
| `dd` / `yy` / `p` / `P` | Delete (cut) line / copy line / paste after / before |
| `dw`, `d$`, `D` | Delete word, to end of line |
| `cw` / `ciw` | Change word |
| `u` / `Ctrl+R` | Undo / redo |
| `.` | Repeat the last change |
| `v` / `V` / `Ctrl+V` | Visual: characters / lines / block |
| `/text` / `?text` | Search forward / backward (`n`, `N` for next/previous) |
| `*` | Search the word under the cursor |
| `:%s/old/new/g` | Replace everywhere (`/gc` asks for confirmation) |
| `:set number` | Show line numbers |
| `:e file` | Open another file |
| `:sp` / `:vsp` / `Ctrl+W w` | Horizontal / vertical split / switch |
| `:!cmd` | Run a shell command |
| `:set paste` | Paste without auto-indent mess (`:set nopaste` to undo) |

`vimtutor` is a 30-minute built-in tutorial. Set `export EDITOR=vim` or `nano` so `Ctrl+X Ctrl+E`, `git commit` and `crontab -e` use your favorite.

---

## 11. Git essentials from the terminal

```bash
git config --global user.name  "Your Name"
git config --global user.email "you@example.com"
git config --global init.defaultBranch main
git config --global core.editor nano
git config --global pull.rebase false
```

| Command | Use |
|---|---|
| `git init` / `git clone URL` | Start / copy a repository |
| `git status -sb` | Short status |
| `git add file` / `git add -p` | Stage a file / stage interactively, hunk by hunk |
| `git commit -m "msg"` / `git commit` | Commit |
| `git commit --amend` | Edit the last commit |
| `git log --oneline --graph --decorate --all` | History picture |
| `git log -p file` | Changes of one file over time |
| `git diff` / `git diff --staged` | Unstaged / staged changes |
| `git restore file` / `git restore --staged file` | Discard working changes / unstage |
| `git switch -c feature` / `git switch main` | New branch / change branch |
| `git branch -a` | List branches |
| `git merge feature` | Merge |
| `git rebase main` | Replay your commits on top of `main` |
| `git stash` / `git stash pop` | Shelve and restore work in progress |
| `git tag -a v1.0 -m "release"` | Annotated tag |
| `git describe --tags --always --dirty` | Version string (used to stamp firmware) |
| `git remote -v` / `git fetch` / `git pull` / `git push` | Remotes |
| `git blame file` | Who changed each line |
| `git bisect start/good/bad` | Find the commit that introduced a bug |
| `git submodule add URL path` / `git submodule update --init --recursive` | Third-party code (CMSIS, ETL) |
| `git reset --soft HEAD~1` | Undo a commit, keep changes staged |
| `git reset --hard HEAD` | **Throw away** all uncommitted changes (careful) |
| `git clean -fdx` | **Delete** untracked and ignored files, including `build/` (careful) |
| `git revert <commit>` | Create a commit that undoes another |

`.gitignore` for these projects:

```
build/
build-*/
*.o
*.elf
*.bin
*.map
.vscode/*
!.vscode/tasks.json
!.vscode/launch.json
__pycache__/
```

Aliases: `git config --global alias.st "status -sb"`, `alias.lg "log --oneline --graph --decorate --all"`.

---

## 12. Serial ports and the embedded toolchain from the terminal

### 12.1 Serial terminals

```bash
ls /dev/ttyACM*                           # Nucleo's virtual COM port is usually /dev/ttyACM0
picocom -b 115200 /dev/ttyACM0            # exit: Ctrl+A then Ctrl+X
picocom -b 115200 --imap lfcrlf /dev/ttyACM0     # map LF to CRLF on received data
picocom -b 115200 --omap crcrlf /dev/ttyACM0     # map CR to CRLF on sent data
minicom -D /dev/ttyACM0 -b 115200         # Ctrl+A Z help, Ctrl+A X exit
screen /dev/ttyACM0 115200                # Ctrl+A K kill, Ctrl+A \ quit; Ctrl+A D detach
tio -b 115200 /dev/ttyACM0                # Ctrl+T Q quit (sudo apt install tio)
```

| `picocom` keys | Action |
|---|---|
| `Ctrl+A Ctrl+X` | Exit |
| `Ctrl+A Ctrl+Q` | Quit without resetting the port |
| `Ctrl+A Ctrl+H` | Help (lists all keys) |
| `Ctrl+A Ctrl+C` | Toggle local echo |
| `Ctrl+A Ctrl+B` | Change baud rate |
| `Ctrl+A Ctrl+L` | Send a file |

Quick checks without a terminal program:

```bash
stty -F /dev/ttyACM0 115200 raw -echo      # configure the port
cat /dev/ttyACM0                           # read incoming data (Ctrl+C to stop)
echo "ping" > /dev/ttyACM0                 # send text
cat /dev/ttyACM0 | tee uart.log            # read and save
cat /dev/ttyACM0 | ts '[%H:%M:%.S]'        # add timestamps (sudo apt install moreutils)
```

Close terminal programs before flashing or debugging: they keep the port open (and sometimes confuse the ST-LINK).

### 12.2 Toolchain commands

```bash
arm-none-eabi-gcc --version
arm-none-eabi-size build/blink.elf
arm-none-eabi-nm -S --size-sort -C build/blink.elf | tail -20
arm-none-eabi-objdump -d -S build/blink.elf | less
arm-none-eabi-objdump -h build/blink.elf               # sections with VMA/LMA
arm-none-eabi-readelf -S build/blink.elf | grep debug_line
arm-none-eabi-addr2line -e build/blink.elf -f -p 0x08001ba0
arm-none-eabi-objcopy -O binary build/blink.elf build/blink.bin
arm-none-eabi-gdb --version          # or gdb-multiarch
```

### 12.3 Build, flash, debug

```bash
cmake -S . -B build -DCMAKE_BUILD_TYPE=Debug -DCMAKE_TOOLCHAIN_FILE=cmake/toolchains/arm-toolchain.cmake
cmake --build build -j$(nproc)
cmake --build build --target flash
cmake --build build --verbose
rm -rf build                              # clean start

st-info --probe                           # detect the board and chip
st-flash --reset write build/blink.bin 0x08000000
st-flash read dump.bin 0x08000000 0x2000  # read back 8 KB
st-flash erase

openocd -f interface/stlink.cfg -f target/stm32f7x.cfg
openocd -f interface/stlink.cfg -f target/stm32f7x.cfg -c "program build/blink.elf verify reset exit"
telnet localhost 4444                     # OpenOCD console
gdb-multiarch -q -x tools/gdb.cmds build/blink.elf
```

### 12.4 Inspect binaries

```bash
xxd build/blink.bin | head                # raw bytes
xxd -g4 -l 32 build/blink.bin             # first 32 bytes in 32-bit groups: SP and reset vector
od -An -tx4 -N 8 build/blink.bin          # SP and reset vector as words
sha256sum build/blink.bin                 # reproducibility check
ls -l build/blink.*                       # sizes
watch -n1 arm-none-eabi-size build/blink.elf
```

---

## 13. Network and remote work

```bash
ip a ; ip r                       # addresses and routes
ping -c 3 8.8.8.8
curl -I https://example.com       # headers only
curl -O https://host/file         # download keeping the name
wget https://host/file
ssh user@host                     # remote shell
ssh -L 8080:localhost:80 user@host      # port forwarding
ssh-keygen -t ed25519             # create a key pair
ssh-copy-id user@host             # install your public key
scp -r dir user@host:/path/
rsync -avz dir/ user@host:/path/
nc -zv host 22                    # test a TCP port
dig example.com
```

For SSH: `Enter ~ .` (Enter, tilde, dot) kills a hung session. Use `~/.ssh/config` to store host aliases:

```
Host lab
    HostName 192.168.1.50
    User jaigar
    IdentityFile ~/.ssh/id_ed25519
```

then `ssh lab`.

---

## 14. Handy tools worth installing

| Tool | What it adds |
|---|---|
| **fzf** | Fuzzy finder. After install, `Ctrl+R` fuzzy-searches history, `Ctrl+T` inserts a file path, `Alt+C` cd's into a directory. `sudo apt install fzf` |
| **ripgrep** (`rg`) | Fast grep that respects `.gitignore` |
| **fd** (`fdfind`) | Friendlier `find` |
| **bat** (`batcat`) | `cat` with syntax highlighting and line numbers |
| **tree** | Directory tree |
| **htop** | Process viewer |
| **ncdu** | Disk usage explorer |
| **tmux** | Sessions, windows, panes |
| **jq** | JSON on the command line (`curl ... \| jq .`) |
| **shellcheck** | Finds bugs in shell scripts |
| **entr** | Re-run a command when files change: `ls src/*.c \| entr -c cmake --build build` |
| **moreutils** | `ts` (timestamps), `sponge`, `vidir` |
| **zoxide** (`z`) | Smart `cd`: jump to frequently used directories |
| **direnv** | Per-directory environment variables (set `PATH` for a project) |
| **bear** | Generates `compile_commands.json` from a Makefile build (`bear -- make`) |
| **clangd / clang-format / clang-tidy** | Code intelligence, formatting, static analysis |
| **meld** | Visual diff and merge |
| **sigrok-cli / PulseView** | Logic analyzer capture and protocol decoding |

---

## 15. VS Code shortcuts (Linux)

| Keys | Action |
|---|---|
| `Ctrl+P` | Quick open file by name |
| **`Ctrl+Shift+P`** | Command Palette (run any command, `Tasks: Run Task`, `Developer: Reload Window`) |
| ``Ctrl+` `` | Toggle the integrated terminal |
| ``Ctrl+Shift+` `` | New terminal |
| `Ctrl+B` | Toggle the side bar |
| `Ctrl+J` | Toggle the bottom panel |
| `Ctrl+Shift+E` / `F` / `G` / `D` / `X` | Explorer / Search in files / Source control / Run and Debug / Extensions |
| `Ctrl+Shift+F` | Search across the project |
| `Ctrl+F` / `Ctrl+H` | Find / replace in the file |
| `Ctrl+G` | Go to line |
| `Ctrl+Shift+O` | Go to symbol in the file |
| `Ctrl+T` | Go to symbol in the workspace |
| **`F12`** / `Alt+F12` / `Shift+F12` | Go to definition / peek definition / find references |
| `F2` | Rename symbol |
| `Alt+Left` / `Alt+Right` | Navigate back / forward |
| `Ctrl+Tab` | Switch editors |
| `Ctrl+W` | Close the editor |
| `Ctrl+\` | Split the editor |
| `Ctrl+/` | Toggle line comment |
| `Alt+Up` / `Alt+Down` | Move the line |
| `Shift+Alt+Up` / `Down` | Copy the line |
| `Ctrl+Shift+K` | Delete the line |
| `Ctrl+Enter` / `Ctrl+Shift+Enter` | Insert line below / above |
| **`Ctrl+D`** | Select the next occurrence (repeat to add more cursors) |
| `Ctrl+Shift+L` | Select all occurrences |
| `Alt+Click` | Add a cursor |
| `Ctrl+Alt+Up` / `Down` | Add a cursor above / below |
| `Ctrl+Shift+\` | Jump to the matching bracket |
| `Shift+Alt+F` | Format the document |
| `Ctrl+Space` | Trigger suggestions |
| `Ctrl+K Ctrl+C` / `Ctrl+K Ctrl+U` | Comment / uncomment selection |
| `Ctrl+K Z` | Zen mode |
| `Alt+Z` | Toggle word wrap |
| `Ctrl+Shift+V` / `Ctrl+K V` | Markdown preview / side preview |
| `Ctrl+Shift+B` | Run the default build task |
| `F5` / `Shift+F5` | Start / stop debugging |
| `F9` | Toggle breakpoint |
| `F10` / `F11` / `Shift+F11` | Step over / into / out |
| `Ctrl+Shift+M` | Problems panel |
| `Ctrl+K Ctrl+S` | Keyboard shortcuts editor |

In the **integrated terminal**, `Ctrl+Left/Right` move by word, and `Ctrl+Shift+C/V` copy/paste (like GNOME Terminal).

---

## 16. Common problems and quick fixes

| Problem | Fix |
|---|---|
| Terminal looks frozen | You may have pressed `Ctrl+S`: press `Ctrl+Q`. Add `stty -ixon` to `~/.bashrc` |
| Garbled screen after `cat` of a binary | Type `reset` (even if you cannot see it) |
| Running program will not stop | `Ctrl+C`; then `Ctrl+\`; then from another terminal `pkill name` or `kill -9 PID` |
| `Permission denied` running a script | `chmod +x script.sh`, or `bash script.sh` |
| `command not found` for something installed | Check `PATH` (`echo $PATH`), `hash -r`, open a new terminal |
| `Permission denied` on `/dev/ttyACM0` | `sudo usermod -aG dialout $USER`, log out and in |
| `Device or resource busy` on a serial port | Another program holds it: `lsof /dev/ttyACM0`, close `picocom` |
| `open failed` from OpenOCD / `LIBUSB_ERROR_ACCESS` | Another OpenOCD or `st-flash` running, or missing udev rules; replug the board |
| `missing separator` in a Makefile | Spaces instead of TABs. Check with `cat -A Makefile` (tabs show as `^I`) |
| `No such file or directory` for a script that exists | Windows line endings (`\r`): `sed -i 's/\r$//' script.sh`; or wrong shebang path |
| Disk full | `df -h`, `du -ah . \| sort -h \| tail`, clean `build*/` and `apt clean` |
| `sudo` asks for a password every time | Normal timeout is 15 minutes; `sudo -v` refreshes it |
| Typed wrong command with a typo | `^wrong^right` or `Ctrl+A`, fix, `Enter` |
| Pasted a multi-line command and it ran partially | Use `Ctrl+X Ctrl+E` to edit first, or a here-document |
| Lost a long command from history | `Ctrl+R` and part of it; `history \| grep word` |
| Wrong keyboard layout characters | `setxkbmap es` (or change in Settings) |
| Copy with `Ctrl+C` in the terminal killed my program | Use `Ctrl+Shift+C` for copy |
| `Ctrl+Z` left a suspended job | `jobs`, then `fg` or `kill %1` |
| `ls` colors/alias confusion | `type ls` shows the alias; `\ls` bypasses it |

---

## 17. One-page cheat sheet

### Cursor and editing

```
Ctrl+A / Ctrl+E      start / end of line
Alt+B / Alt+F        word back / forward   (also Ctrl+Left / Ctrl+Right)
Ctrl+U / Ctrl+K      cut to start / to end
Ctrl+W / Alt+D       cut word before / after
Ctrl+Y               paste what you cut
Ctrl+T / Alt+T       swap chars / words
Ctrl+_               undo
Ctrl+X Ctrl+E        edit the line in $EDITOR
Alt+.                last argument of the previous command (repeat to go back)
Ctrl+R               search history     Ctrl+G cancel
!!   sudo !!   !$    previous command / with sudo / its last argument
^old^new             repeat with a fix
Ctrl+L               clear the screen
```

### Control

```
Ctrl+C  interrupt        Ctrl+Z  suspend (bg / fg)      Ctrl+D  EOF / exit
Ctrl+\  force quit       Ctrl+S / Ctrl+Q  freeze / resume
Ctrl+Shift+C / V         copy / paste in the terminal
```

### Daily commands

```
ls -lah    cd -    pwd    mkdir -p    cp -r    mv    rm -r    ln -s
cat  less  head  tail -f  wc -l  grep -rn  find . -name  sed -i  awk  sort | uniq -c
chmod +x   chown   tar czf / xzf   rsync -avh   diff -u
ps aux | grep   pgrep -a   pkill   kill -9   jobs   bg   fg   top / htop
ss -tulpn   lsof -i :3333   lsof /dev/ttyACM0
sudo apt update && sudo apt install
lsusb   dmesg -w   ls /dev/ttyACM*   picocom -b 115200 /dev/ttyACM0
```

### Chaining and redirecting

```
a && b      b if a succeeded          a || b     b if a failed
a | b       pipe                      a > f      a >> f      a 2>&1 | less
cmd | tee log.txt                     diff <(a) <(b)
```

### tmux

```
tmux new -s dbg    Ctrl+B d  detach    tmux a -t dbg  attach
Ctrl+B %  "  split    arrows  move    z  zoom    c  new window    n/p  switch    [  scroll
```

### Embedded loop

```
cmake -S . -B build ... && cmake --build build -j$(nproc)
cmake --build build --target flash
picocom -b 115200 /dev/ttyACM0         (Ctrl+A Ctrl+X to exit)
openocd -f interface/stlink.cfg -f target/stm32f7x.cfg   |   gdb-multiarch -q build/blink.elf
```

---

## 18. How to practice

1. **Two weeks of deliberate use**: every time you reach for the mouse or the arrow keys on the command line, use `Ctrl+A/E`, `Alt+B/F`, `Ctrl+W/U/K` instead. Add `Ctrl+R` and `Alt+.` to the habit.
2. **Make a personal `~/.bash_aliases`** with the commands you type most (build, flash, serial, git log), and a few functions (`mkcd`, a function that opens the serial port).
3. **Keep a "commands I look up repeatedly" file** (this one is a start) and move items to aliases once they repeat.
4. **Learn one text tool well each month**: `grep`/`rg`, then `sed`, then `awk`, then `find`/`xargs`.
5. **Use `tmux`** for every debugging session and write your layout script.
6. **Read `man` pages**: `man grep`, `man find`, `man bash` (search with `/`), `tldr` (short examples: `sudo apt install tldr`), and `command --help`.
7. **Use `explainshell.com`** (paste a command to see what each part means) for commands you copy from the internet, before running them.

### Reading documentation

```bash
man command            # manual (q to quit, /text to search)
man -k keyword         # search manuals
command --help | less
info coreutils
type -a command        # how the shell resolves a name
apropos copy
```

## References

- `man bash` (sections "READLINE", "HISTORY EXPANSION", "EXPANSION")
- GNU Coreutils manual: <https://www.gnu.org/software/coreutils/manual/>
- *The Linux Command Line*, William Shotts (free: <https://linuxcommand.org/tlcl.php>)
- *Bash Pocket Reference*, Arnold Robbins
- The tmux manual: `man tmux`; <https://github.com/tmux/tmux/wiki>
- `vimtutor`, <https://vim.rtorr.com> (cheat sheet)
- explainshell: <https://explainshell.com>