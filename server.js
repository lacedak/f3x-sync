
const http = require("http");
const WebSocket = require("ws");

const server = http.createServer((req, res) => {
  res.writeHead(200, { "Content-Type": "text/plain" });
  res.end("F3X Sync relay is running!");
});

const wss = new WebSocket.Server({ server });
const rooms = new Map();

wss.on("connection", (socket) => {
  let room = null;

  socket.on("message", (raw) => {
    try {
      const message = JSON.parse(raw.toString());

      if (message.type === "join") {
        if (typeof message.room !== "string" ||
            !message.room.trim()) return;

        room = message.room.trim();

        if (!rooms.has(room)) {
          rooms.set(room, new Set());
        }

        const clients = rooms.get(room);

        socket.send(JSON.stringify({
          type: "snapshot",
          builds: []
        }));

        clients.add(socket);
        return;
      }

      if (!room || !rooms.has(room)) return;

      for (const client of rooms.get(room)) {
        if (client !== socket &&
            client.readyState === WebSocket.OPEN) {
          client.send(raw.toString());
        }
      }
    } catch (error) {
      console.error("Message error:", error);
    }
  });

  socket.on("close", () => {
    if (!room || !rooms.has(room)) return;

    const clients = rooms.get(room);
    clients.delete(socket);

    if (clients.size === 0) {
      rooms.delete(room);
    }
  });
});

const PORT = process.env.PORT || 8080;

server.listen(PORT, "0.0.0.0", () => {
  console.log(`F3X relay running on port ${PORT}`);
});
