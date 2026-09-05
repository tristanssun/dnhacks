# Nearby Interaction with Custom Server

This is a sample app demonstrating the use of the Nearby Interaction framework to measure the distance between two iPhones. A small local HTTP server exchanges discovery tokens.

## System Requirements

- iOS 15.0 or later
- iPhone 11 or later (excluding iPhone SE)
- Two physical iPhones for distance measurement. The iOS Simulator can exercise token exchange, but it cannot run UWB ranging.

## Run the token server

From the `Server` directory:

```
npm start
```

The server listens on port 8787. Simulators use `http://127.0.0.1:8787`. Physical iPhones should use the on-device URL printed by the server, for example `http://192.168.1.250:8787`.

To publish the same API on Cloudflare Workers instead, see `Server/README.md`.

## How to Use

Prepare two iPhones on the same network as the server and follow these steps:

1. Confirm the Server URL field matches the running token server.
2. Launch the app on one iPhone and tap **Get my code**. If you see a message like "Your code: 1234," the process has succeeded.
3. Launch the app on the other iPhone and tap **Get my code**.
4. On each iPhone, enter the four-digit code displayed on the other device into the **Peer Code** field.
5. Tap **Start** on both iPhones.
6. Move the iPhones closer together or farther apart. The **Distance** displayed at the bottom of the screen will update in real time. The distance is measured in meters.
