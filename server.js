
const WebSocket = require("ws");

const server = new WebSocket.Server({
  port: process.env.PORT || 8080
});

const rooms = new Map();

server.on("connection", (socket) => {
  let room = null;

  socket.on("message", (raw) => {
    try {
      const message = JSON.parse(raw.toString());

      if (message.type === "join") {
        room = message.room;

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

      const clients = rooms.get(room);

      for (const client of clients) {
        if (client !== socket &&
            client.readyState === WebSocket.OPEN) {
          client.send(raw.toString());
        }
      }
    } catch (error) {
      console.error(error);
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

console.log("F3X relay running");
