import QtQuick
import Quickshell
import Quickshell.Io
import "Exec.js" as Exec

// One GraphQL request. The only place in the plugin that builds a curl
// invocation — ConnectionTest and every polled resource go through this.
//
// The API key is fetched from the keyring per request and handed to curl
// through a header file, so it never appears in argv
// (`ps`/`/proc/<pid>/cmdline`), never lands in a QML property where a
// binding or log could pick it up, and — since the marketplace review —
// is no longer in the child's environment either.
//
// curl is started directly by absolute path. There is no shell: an earlier
// version wrapped the call in `bash -c` to mktemp the config and trap-clean
// it, which meant four ambient executables (`bash`, `mktemp`, `rm`, `curl`)
// resolved through an inherited $PATH while the credential sat in the
// environment beside them. `curl -H @file` reads headers from a file
// directly, so the shell bought nothing that could not be done without it.
//
// The environment is cleared outright rather than filtered. curl needs
// nothing from it here, and `-q` keeps it from reading ~/.curlrc, so what
// the request does is fully determined by this file.
//
// A StdioCollector's `text` is a property, not a method, and is only
// reliable inside that collector's own onStreamFinished — hence the
// three-flag coordination instead of reading it from onExited.
Item {
  id: root

  property string endpoint: ""
  property var secretStore: null

  // Data queries get a generous window; connectivity probes want the
  // spec's 1.5-2s (section 32) so a dead endpoint is ruled out quickly
  // instead of stalling failover for twelve seconds.
  property int timeoutSeconds: 12

  readonly property bool busy: _busy
  property bool _busy: false

  // `data` can be non-null while `errors` is also populated — that is
  // normal, not a failure (a real server reports NaN fields that way while
  // returning everything else intact). Callers decide whether the branch
  // they care about arrived.
  signal succeeded(var data, var errors)
  // reason: "unreachable" | "rejected" | "malformed"
  signal failed(string reason, string message)

  // `keyOverride` lets onboarding test a key the user just typed, before
  // it has been stored in the keyring. It's passed as an argument rather
  // than held in a property so there's no place for a binding or a debug
  // dump to pick the key up from.
  function send(queryString, keyOverride) {
    if (_busy) return false
    if (!endpoint) {
      root.failed("unreachable", "No server endpoint configured.")
      return false
    }
    _busy = true
    root._pendingQuery = queryString

    watchdog.restart()

    if (keyOverride) {
      root._start(keyOverride)
      return true
    }

    if (!secretStore) {
      _busy = false
      root.failed("rejected", "No API key stored for this server.")
      return false
    }
    secretStore.fetchForUse(function(key) {
      if (!key) {
        root._busy = false
        root.failed("rejected", "No API key stored for this server.")
        return
      }
      root._start(key)
    })
    return true
  }

  property string _pendingQuery: ""

  // An API key never legitimately contains whitespace, and a pasted one
  // often carries a trailing newline — inside curl's config file that ends
  // the header line early and leaves the closing quote stranded on the
  // next line, which curl rejects outright. Scrub, then escape the two
  // characters curl's quoted-value syntax treats specially.
  // A key never legitimately contains these, and a pasted one often carries
  // a trailing newline — which inside a header file would split the header
  // or terminate it early.
  function headerValue(key) {
    return String(key).replace(/[\r\n\t]/g, "").trim()
  }

  // The header file lives in XDG_RUNTIME_DIR: a tmpfs the kernel never
  // writes to disk, mode 0700 and owned by this user, cleared at logout.
  // One file per request object, blanked the moment the request finishes,
  // so the key is resident only while curl is actually reading it.
  //
  // On the file's own mode: FileView exposes no permission control, so 0600
  // cannot be asked for directly and the file lands at the process umask
  // (0644 here). The confinement comes from the directory instead —
  // /run/user/<uid> is 0700 and user-owned, so no other unprivileged user
  // can traverse into it whatever the file says. Blanking after use is what
  // closes the remaining window.
  readonly property string _headerPath:
    Quickshell.env("XDG_RUNTIME_DIR") + "/omarchy-unraid-headers-" + root._instanceId
  readonly property string _instanceId:
    Math.random().toString(36).slice(2) + "-" + Date.now().toString(36)

  // Unraid's HTTPS listener normally presents a self-signed certificate, so
  // curl rejects it and the panel reported a flat "could not reach the
  // server" — which is exactly the wrong diagnosis. Opting in adds curl's
  // `insecure`, and only ever for an https endpoint: setting it on a plain
  // http request would be meaningless, and leaving it permanently on would
  // silently weaken a properly-certificated server too.
  property bool allowSelfSigned: false
  // The biggest reply the plugin legitimately receives is the parity log at
  // ~8.5 KB; 4 MB is far past anything real and far below hurting.
  property int maxResponseBytes: 4194304
  readonly property bool _isHttps: /^https:/i.test(root.endpoint)

  function _start(key) {
    // Written before the process starts, and blockWrites makes that
    // ordering real rather than hopeful.
    headerFile.setText(
      "x-api-key: " + root.headerValue(key) + "\n"
      + "Content-Type: application/json\n")

    proc.clearEnvironment = true
    proc.environment = ({})
    proc.command = [
      Exec.CURL,
      // -q: ignore ~/.curlrc, so nothing outside this file can add a flag.
      "-q", "-sS",
      "--max-time", String(Math.max(1, root.timeoutSeconds)),
      // A reply is a GraphQL document, never a payload. Without a ceiling a
      // wrong URL pointing at something large — or a hostile answer — gets
      // read into memory in full before anything looks at it.
      "--max-filesize", String(root.maxResponseBytes),
      // @file: curl reads the headers from the file rather than from argv,
      // which is what keeps the key out of `ps`.
      "-H", "@" + root._headerPath,
      // No `-f`: it suppresses the response body on an HTTP error, and for
      // GraphQL the body IS the diagnosis ("Cannot query field ...", or an
      // auth rejection). Errors are read out of the JSON instead, and a
      // genuine connection failure still shows up as a curl exit code.
      "-X", "POST",
      "--data", JSON.stringify({ query: root._pendingQuery }),
      root.endpoint
    ]
    if (root.allowSelfSigned && root._isHttps) proc.command.splice(1, 0, "--insecure")
    proc.running = true
  }

  FileView {
    id: headerFile
    path: root._headerPath
    // The file has to exist before curl is told to read it; without this
    // the write would race the process start.
    blockWrites: true
    atomicWrites: false
    printErrors: false
  }

  // A request that never completes would leave `busy` stuck and stop this
  // resource from ever polling again — which is exactly how a dropped
  // keyring callback managed to leave five of six views permanently empty.
  // Turn any such hang into an ordinary retryable failure.
  Timer {
    id: watchdog
    // Comfortably past curl's own timeout, so this only ever fires for a
    // reply that got lost rather than one that's merely slow. Derived from
    // the timeout so a 2s probe isn't held hostage for 25s.
    interval: Math.max(8000, (root.timeoutSeconds + 6) * 1000)
    repeat: false
    onTriggered: {
      if (!root._busy) return
      root._busy = false
      proc.running = false
      headerFile.setText("")
      root.failed("unreachable", "The request timed out with no reply.")
    }
  }

  Process {
    id: proc

    property int lastExitCode: -1
    property string lastStdout: ""
    property string lastStderr: ""
    property bool _exited: false
    property bool _stdoutDone: false
    property bool _stderrDone: false

    function _finish() {
      if (!_exited || !_stdoutDone || !_stderrDone) return
      _exited = false
      _stdoutDone = false
      _stderrDone = false
      proc.environment = {}
      // The key has served its purpose the moment curl exits; leaving it
      // in tmpfs until logout would be a plaintext credential sitting
      // around for no reason.
      headerFile.setText("")
      root._busy = false
      watchdog.stop()

      var exitCode = proc.lastExitCode
      if (exitCode !== 0 && exitCode !== 22) {
        var stderrText = proc.lastStderr.trim()
        // curl's TLS family: 35 connect, 51/60 verification, 58/83 client
        // cert, 77 CA store. The message is specific because this is the one
        // failure the user can fix from Settings — but the *reason* stays
        // "unreachable" on purpose. That string is the connection layer's
        // vocabulary: ConnectionManager only counts "unreachable" toward
        // failover, and UnraidService judges offline on it, so inventing a
        // "tls" reason would quietly stop a certificate-broken endpoint from
        // ever failing over to a working one.
        if (root._isHttps && [35, 51, 58, 60, 77, 83].indexOf(exitCode) >= 0) {
          root.failed("unreachable", "The server's HTTPS certificate was rejected. "
            + "Unraid usually presents a self-signed one — allow it under "
            + "Settings > Server, or use an http:// address."
            + (stderrText !== "" ? " (" + stderrText + ")" : ""))
          return
        }
        root.failed("unreachable", "Could not reach the server at that address."
          + (stderrText !== "" ? " (" + stderrText + ")" : " (curl exit " + exitCode + ")"))
        return
      }

      var parsed = null
      try { parsed = JSON.parse(proc.lastStdout) } catch (e) { parsed = null }
      if (!parsed) {
        root.failed("malformed", "The server's reply could not be read as JSON.")
        return
      }

      if (parsed.data) {
        root.succeeded(parsed.data, parsed.errors || [])
        return
      }

      // No data at all: report the server's own message, and call out an
      // auth rejection specifically. Unraid answers HTTP 200 even for
      // those, with the real status buried in the error extensions.
      var first = parsed.errors && parsed.errors.length > 0 ? parsed.errors[0] : null
      var status = first && first.extensions && first.extensions.originalError
        ? first.extensions.originalError.statusCode : null
      if (status === 401 || status === 403) {
        root.failed("rejected", "The server rejected the API key (" + first.message + ").")
      } else if (first) {
        root.failed("rejected", "The server responded with an error: " + first.message)
      } else {
        root.failed("malformed", "The server returned no data.")
      }
    }

    onExited: function(exitCode) {
      proc.lastExitCode = exitCode
      proc._exited = true
      proc._finish()
    }

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        proc.lastStdout = text
        proc._stdoutDone = true
        proc._finish()
      }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        proc.lastStderr = text
        proc._stderrDone = true
        proc._finish()
      }
    }
  }
}
