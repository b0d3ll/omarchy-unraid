import QtQuick
import Quickshell
import Quickshell.Io

// One GraphQL request. The only place in the plugin that builds a curl
// invocation — ConnectionTest and every polled resource go through this.
//
// The API key is fetched from the keyring per request and handed to curl
// via a header config file written by the spawned shell, so it never
// appears in argv (`ps`/`/proc/<pid>/cmdline`) and never lands in a QML
// property where a binding or log could pick it up.
//
// Two hard-won details from getting this working against a real server:
//   * `Process.environment` REPLACES the environment, so session vars have
//     to be carried over explicitly or curl/bash lose PATH and secret-tool
//     loses its D-Bus session.
//   * A StdioCollector's `text` is a property, not a method, and is only
//     reliable inside that collector's own onStreamFinished — hence the
//     three-flag coordination instead of reading it from onExited.
Item {
  id: root

  property string endpoint: ""
  property var secretStore: null

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
  function curlConfigValue(key) {
    var cleaned = String(key).replace(/[\r\n\t]/g, "").trim()
    return cleaned.replace(/\\/g, "\\\\").replace(/"/g, "\\\"")
  }

  function sessionEnv(extra) {
    var base = {
      PATH: Quickshell.env("PATH"),
      HOME: Quickshell.env("HOME"),
      USER: Quickshell.env("USER"),
      DBUS_SESSION_BUS_ADDRESS: Quickshell.env("DBUS_SESSION_BUS_ADDRESS"),
      XDG_RUNTIME_DIR: Quickshell.env("XDG_RUNTIME_DIR"),
      DISPLAY: Quickshell.env("DISPLAY"),
      WAYLAND_DISPLAY: Quickshell.env("WAYLAND_DISPLAY")
    }
    for (var k in extra) base[k] = extra[k]
    return base
  }

  function _start(key) {
    proc.environment = root.sessionEnv({
      "OMARCHY_UNRAID_CURL_CONFIG":
        'header = "x-api-key: ' + root.curlConfigValue(key) + '"\n'
        + 'header = "Content-Type: application/json"\n',
      "OMARCHY_UNRAID_QUERY": JSON.stringify({ query: root._pendingQuery }),
      "OMARCHY_UNRAID_URL": root.endpoint
    })
    // A real mktemp'd file rather than `-K <(...)`: process substitution
    // intermittently made curl misparse the config against a real server.
    proc.command = ["bash", "-c",
      'CFGFILE=$(mktemp) && trap \'rm -f "$CFGFILE"\' EXIT'
      + ' && printf \'%s\' "$OMARCHY_UNRAID_CURL_CONFIG" > "$CFGFILE"'
      // No `-f`: it suppresses the response body on an HTTP error, and for
      // GraphQL the body IS the diagnosis ("Cannot query field ...", or an
      // auth rejection). Errors are read out of the JSON instead, and a
      // genuine connection failure still shows up as a curl exit code.
      + ' && curl -sS --max-time 12 -K "$CFGFILE" -X POST'
      + ' --data "$OMARCHY_UNRAID_QUERY" "$OMARCHY_UNRAID_URL"']
    proc.running = true
  }

  // A request that never completes would leave `busy` stuck and stop this
  // resource from ever polling again — which is exactly how a dropped
  // keyring callback managed to leave five of six views permanently empty.
  // Turn any such hang into an ordinary retryable failure.
  Timer {
    id: watchdog
    interval: 25000
    repeat: false
    onTriggered: {
      if (!root._busy) return
      root._busy = false
      proc.running = false
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
      root._busy = false
      watchdog.stop()

      var exitCode = proc.lastExitCode
      if (exitCode !== 0 && exitCode !== 22) {
        var stderrText = proc.lastStderr.trim()
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
