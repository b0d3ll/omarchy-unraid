.pragma library

// Absolute paths for every external program this plugin starts.
//
// Nothing here is ever looked up through $PATH. A shell plugin is a
// long-lived process that holds an Unraid API key, so a single writable
// PATH entry ahead of /usr/bin would be enough to substitute `curl` or
// `secret-tool` and walk off with the credential — or to rewrite the
// requests and responses the panel trusts.
//
// /usr/bin is the trusted directory on Omarchy: it is root-owned, and
// /bin, /sbin and /usr/sbin are all symlinks into it on Arch, so there is
// no second location to consider. Resolution is deliberately not
// configurable — an override would reintroduce exactly the vector this
// exists to close.
//
// There is no pre-flight existence probe, and none is needed to fail
// closed: an absolute path that does not exist makes the Process fail to
// start, which surfaces as an ordinary error. What must never happen is a
// fallback to ambient lookup, and there is no code path that can.
var BIN = "/usr/bin/"

var CURL = BIN + "curl"
var SECRET_TOOL = BIN + "secret-tool"
var MKDIR = BIN + "mkdir"
var TAILSCALE = BIN + "tailscale"
