# Windows, PowerShell and the surrounding tooling

None of this is about agents. All of it stopped the demo from running.

## `nat validate` fails on a stock Windows console

`nat` prints a `✓` (U+2713) on success. On a non-UTF-8 code page that raises inside click, and the
error handler then dies trying to print `✗` (U+2717):

```
UnicodeEncodeError: 'charmap' codec can't encode character '✓'
  ...during handling of the above exception, another exception occurred...
click.echo(click.style("✗ Validation failed!\n\nError:", fg="red"))
```

Exit code is **1**, so scripts conclude the config is invalid when it is perfectly fine. The success
message is what kills it.

It bites when stdout is not a UTF-8 console — including when redirected, which is what any setup
script does. `locale.getpreferredencoding()` is `cp1252` on a default Windows install.

**Fix:** force UTF-8 for child Python processes.

```powershell
$env:PYTHONIOENCODING = "utf-8"
$env:PYTHONUTF8 = "1"
```

```bash
export PYTHONIOENCODING=utf-8   # also worth having under LANG=C, e.g. minimal containers
```

**Measured.** It is easy to miss because a developer machine often already has `PYTHONIOENCODING`
set, which masks it entirely.

---

## Native stderr aborts PowerShell scripts

Under `$ErrorActionPreference = "Stop"`, PowerShell 5.1 wraps a native command's stderr in a
terminating `NativeCommandError`. Several perfectly normal things write to stderr:

- `docker info` when the daemon is down
- `docker compose` progress output
- `pip` warnings
- **`nat validate`**, which emits the `0.0.0.0` bind-without-auth warning

So a script dies at the exact moment it was written to produce a friendly warning. The `nat validate`
case fires on every Windows machine, regardless of encoding.

**Fix:** run native commands with `$ErrorActionPreference` relaxed and judge them by exit code.

```powershell
function Invoke-Native {
    param([Parameter(Mandatory = $true)][scriptblock] $Command)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try   { & $Command *>$null; return $LASTEXITCODE }
    catch { return 1 }
    finally { $ErrorActionPreference = $prev }
}
```

**Measured.**

---

## `$parts[1..($parts.Length-1)]` is not an empty slice

A common idiom for "everything after the first element" misbehaves on a one-element array:

```powershell
$parts = "python".Split(" ")          # @("python")
$parts[1..($parts.Length-1)]          # @("python")  <- not empty
```

`1..0` is a *descending* range, so you get the element back. The result was
`python python -c "..."`, Python tried to run a file called `python`, the try/catch swallowed it,
and the script reported "Python 3.11+ not found" on a machine with Python 3.12 installed.

**Fix:** use arrays of arrays and splatting.

```powershell
foreach ($candidate in @(@("py","-3.12"), @("py","-3.11"), @("python"))) {
    $exe  = $candidate[0]
    $rest = @($candidate | Select-Object -Skip 1)
    $ver  = & $exe @rest -c "import sys; print('%d.%d' % sys.version_info[:2])"
}
```

Note that `@(@("a","b"), @("c"))` keeps `@("c")` as a one-element array, but `@(@("c"))` collapses to
a scalar. That caught us while writing the test for the fix.

**Measured.**

---

## The A2A agent card advertises whatever `host` you bind

Setting `host: 0.0.0.0` is not a cosmetic choice. The agent card publishes that address:

```json
{"url": "http://0.0.0.0:9002/", ...}
```

and the A2A client dials it. `0.0.0.0` is not a connectable destination on Windows, so the caller
fails with:

```
HTTP Error 503: Network communication error: All connection attempts failed
```

**Fix:** bind to `127.0.0.1` for local work. It also removes nat's bind-without-auth warning.

**Measured.**

---

## Wikipedia now requires a User-Agent

Not a nat problem, but it makes `wiki_search` fail 100% of the time.

nat's `wiki_search` goes through langchain's `WikipediaLoader`, which uses the `wikipedia` package
(1.4.0, last released 2014). That package sends no descriptive User-Agent. Wikimedia now enforces
its UA policy and answers with **HTTP 403 and a plain-text body**, which the library tries to parse
as JSON:

```
json.decoder.JSONDecodeError: Expecting value: line 1 column 1 (char 0)
```

See https://phabricator.wikimedia.org/T400119.

**Fix:** set it once at import.

```python
import wikipedia
wikipedia.set_user_agent("your-app/0.1 (https://example.com/contact)")
```

Wikimedia asks for a descriptive agent with a contact address. See
[`plugin/nat_demo_shims/wikipedia_ua.py`](../plugin/nat_demo_shims/wikipedia_ua.py).

**Measured** — 403 before, working searches after.

---

## Docker Desktop and stale sockets

Twice in one day, Docker Desktop 4.55.0 refused to start with:

```
starting services: initializing Inference manager: listening on
unix://<HOME>\AppData\Local\Docker\run\dockerInference:
remove ...\dockerInference: The file cannot be accessed by the system.
```

Two orphaned AF_UNIX socket files that Windows cannot even stat. Docker recreates them on boot.

```powershell
Get-Process *docker* | Stop-Process -Force
Start-Sleep 3
Remove-Item "$env:LOCALAPPDATA\Docker\run\dockerInference","$env:LOCALAPPDATA\Docker\run\userAnalyticsOtlpHttp.sock" -Force
```

Worth knowing before a demo, because the failure is a modal dialog and an immediate quit.

---

## Bash heredocs mangle line continuations

Writing shell or markdown from a Python heredoc, a trailing `\` before a newline can arrive doubled,
producing a literal `\n` in the output file and a broken script. It happened twice here.

If you are generating files with continuations, build the lines as a list and `"\n".join(...)` them,
or use `chr(92)` for the backslash, and **check the result** with `cat -A` or `bash -n`.
