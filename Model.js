.pragma library

// Milestone 1 mock data. Shapes mirror the state UnraidService.qml will
// eventually populate from the real GraphQL API (see spec section 35) —
// views bind to this shape now so Milestone 4 only has to swap the source,
// not the bindings.

function mockState() {
  return {
    connection: {
      state: "CONNECTED_LAN",
      type: "LAN",
      name: "LAN",
      endpoint: "tower.local",
      latencyMs: 4,
      lastSuccess: Date.now() - 5000
    },

    system: {
      hostname: "Tower",
      unraidVersion: "7.2.1",
      apiVersion: "4.11.0"
    },

    metrics: {
      cpuPercent: 27,
      ramPercent: 38,
      ramUsedGb: 142,
      ramTotalGb: 384
    },

    array: {
      state: "STARTED",
      disks: 12,
      disabled: 0,
      missing: 0,
      cacheDevices: 2,
      capacity: {
        usedTb: 7.2,
        totalTb: 11.4,
        freeTb: 4.2
      },
      parityCheckStatus: {
        running: true,
        paused: false,
        progress: 73,
        speed: "91 MB/s",
        errors: 0,
        correcting: false
      }
    },

    docker: {
      available: true,
      containers: mockContainers()
    },

    vms: {
      available: true,
      domains: mockVms()
    },

    notifications: mockNotifications()
  }
}

function mockContainers() {
  return [
    { id: "c1", name: "Jellyfin", state: "RUNNING", status: "Up 3 days", autoStart: true, updateAvailable: false, webUiUrl: "http://tower.local:8096" },
    { id: "c2", name: "Home Assistant", state: "RUNNING", status: "Up 12 days", autoStart: true, updateAvailable: true, webUiUrl: "http://tower.local:8123" },
    { id: "c3", name: "Syncthing", state: "RUNNING", status: "Up 3 days", autoStart: true, updateAvailable: false, webUiUrl: "http://tower.local:8384" },
    { id: "c4", name: "Immich", state: "EXITED", status: "Exited (1) 2 hours ago", autoStart: false, updateAvailable: false, webUiUrl: "" },
    { id: "c5", name: "UrBackup", state: "RUNNING", status: "Up 3 days", autoStart: true, updateAvailable: false, webUiUrl: "http://tower.local:55414" },
    { id: "c6", name: "Nextcloud", state: "RUNNING", status: "Up 3 days", autoStart: true, updateAvailable: false, webUiUrl: "http://tower.local:8443" },
    { id: "c7", name: "Pi-hole", state: "RUNNING", status: "Up 3 days", autoStart: true, updateAvailable: false, webUiUrl: "http://tower.local:8081" },
    { id: "c8", name: "qBittorrent", state: "RUNNING", status: "Up 3 days", autoStart: true, updateAvailable: false, webUiUrl: "http://tower.local:8090" },
    { id: "c9", name: "Sonarr", state: "RUNNING", status: "Up 3 days", autoStart: true, updateAvailable: false, webUiUrl: "http://tower.local:8989" },
    { id: "c10", name: "Radarr", state: "RUNNING", status: "Up 3 days", autoStart: true, updateAvailable: false, webUiUrl: "http://tower.local:7878" },
    { id: "c11", name: "Prowlarr", state: "RUNNING", status: "Up 3 days", autoStart: true, updateAvailable: false, webUiUrl: "http://tower.local:9696" },
    { id: "c12", name: "Grafana", state: "RUNNING", status: "Up 3 days", autoStart: true, updateAvailable: false, webUiUrl: "http://tower.local:3000" },
    { id: "c13", name: "Portainer", state: "RUNNING", status: "Up 3 days", autoStart: true, updateAvailable: false, webUiUrl: "http://tower.local:9000" },
    { id: "c14", name: "Vaultwarden", state: "RUNNING", status: "Up 3 days", autoStart: true, updateAvailable: false, webUiUrl: "http://tower.local:8082" },
    { id: "c15", name: "Duplicati", state: "RUNNING", status: "Up 3 days", autoStart: true, updateAvailable: false, webUiUrl: "http://tower.local:8200" }
  ]
}

function mockVms() {
  return [
    { id: "v1", name: "HAOS", state: "RUNNING" },
    { id: "v2", name: "Windows 11", state: "RUNNING" },
    { id: "v3", name: "Test VM", state: "SHUTOFF" }
  ]
}

function mockNotifications() {
  return [
    { id: "n1", title: "Disk 3 SMART warning", subject: "Storage", description: "Disk 3 reported a reallocated sector count above threshold.", importance: "WARNING", timestamp: Date.now() - 18 * 60 * 1000, link: "" },
    { id: "n2", title: "Docker image usage high", subject: "Docker", description: "The docker.img file is above 80% capacity.", importance: "WARNING", timestamp: Date.now() - 2 * 60 * 60 * 1000, link: "" },
    { id: "n3", title: "Parity check completed", subject: "Array", description: "Parity check finished with 0 errors.", importance: "INFO", timestamp: Date.now() - 26 * 60 * 60 * 1000, link: "" }
  ]
}

// Docker sort order per spec section 15: problems, exited, paused, running,
// then alphabetical within a state.
function dockerStateRank(state) {
  switch (state) {
    case "RESTARTING": return 0
    case "DEAD": return 0
    case "EXITED": return 1
    case "PAUSED": return 2
    case "RUNNING": return 3
    default: return 4
  }
}

function sortContainers(containers) {
  return containers.slice().sort(function(a, b) {
    var ra = dockerStateRank(a.state)
    var rb = dockerStateRank(b.state)
    if (ra !== rb) return ra - rb
    return a.name.localeCompare(b.name)
  })
}

function unreadCount(notifications) {
  return notifications.filter(function(n) { return n.importance === "WARNING" || n.importance === "ALERT" }).length
}

// Coarse "N minutes/hours/days ago" label for notification and connection
// timestamps (spec sections 8, 27, 34). Only needs minute/hour/day
// granularity — nothing in this plugin needs second-level precision.
function relativeTime(timestampMs) {
  var diffMs = Date.now() - timestampMs
  var minutes = Math.floor(diffMs / 60000)
  if (minutes < 1) return "just now"
  if (minutes < 60) return minutes + " min ago"
  var hours = Math.floor(minutes / 60)
  if (hours < 24) return hours + (hours === 1 ? " hour ago" : " hours ago")
  var days = Math.floor(hours / 24)
  return days + (days === 1 ? " day ago" : " days ago")
}
