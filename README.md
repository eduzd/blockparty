# Block Party

Friends-only multiplayer prototype built with Godot 4.7.

- `game/` is the Godot project. The same project is the Android app and the server.
- The server runs headless with `godot --headless --path game -- --server` and listens on `$PORT` for WebSocket connections.
- `Dockerfile` and `render.yaml` deploy the server to Render's free tier.
