const http = require("http");
const WebSocket = require("ws");

const server = http.createServer((req, res) => {
  res.writeHead(200, { "Content-Type": "text/plain" });
  res.end("F3X Sync relay is running!");
});

const wss = new WebSocket.Server({ server, maxPayload: 1024 * 1024 });
const rooms = new Map();
const MAX_BUILDS_PER_ROOM = 300;

wss.on("connection", (socket) => {
  let room = null;

  socket.on("message", (raw) => {
    let message;
    try {
      message = JSON.parse(raw.toString());
    } catch {
      return;
    }

    if (message.type === "join") {
      if (typeof message.room !== "string" || !message.room.trim()) return;
      room = message.room.trim().slice(0, 160);

      if (!rooms.has(room)) {
        rooms.set(room, { clients: new Set(), builds: new Map() });
      }
      const state = rooms.get(room);
      state.clients.add(socket);
      socket.send(JSON.stringify({
        type: "snapshot",
        builds: Array.from(state.builds.values())
      }));
      return;
    }

    if (!room || !rooms.has(room)) return;
    const state = rooms.get(room);

    if ((message.type === "create" || message.type === "update") &&
        message.build && typeof message.build.id === "string") {
      const id = message.build.id.slice(0, 100);
      if (state.builds.has(id) || state.builds.size < MAX_BUILDS_PER_ROOM) {
        state.builds.set(id, message.build);
      }
    } else if (message.type === "delete" && typeof message.id === "string") {
      state.builds.delete(message.id.slice(0, 100));
    } else {
      return;
    }

    const outgoing = raw.toString();
    for (const client of state.clients) {
      if (client !== socket && client.readyState === WebSocket.OPEN) {
        client.send(outgoing);
      }
    }
  });

  socket.on("close", () => {
    if (!room || !rooms.has(room)) return;
    const state = rooms.get(room);
    state.clients.delete(socket);
    if (state.clients.size === 0 && state.builds.size === 0) {
      rooms.delete(room);
    }
  });
});

const PORT = process.env.PORT || 8080;
server.listen(PORT, "0.0.0.0", () => {
  console.log(`F3X relay running on port ${PORT}`);
});
