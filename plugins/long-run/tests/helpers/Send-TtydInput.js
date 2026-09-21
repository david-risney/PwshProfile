"use strict";

const crypto = require("node:crypto");
const net = require("node:net");

const [urlText, input, timeoutText] = process.argv.slice(2);
const timeoutMs = Number(timeoutText || 10000);

if (!urlText || input === undefined) {
  console.error("Usage: node Send-TtydInput.js <websocket-url> <input> [timeout-ms]");
  process.exit(2);
}

const url = new URL(urlText);
const socket = net.createConnection({
  host: url.hostname,
  port: Number(url.port),
});
const key = crypto.randomBytes(16).toString("base64");
let response = Buffer.alloc(0);
let upgraded = false;

function frame(payload, opcode = 0x1) {
  const content = Buffer.from(payload);
  if (content.length >= 126) {
    throw new Error("The test helper supports only short WebSocket frames.");
  }
  const mask = crypto.randomBytes(4);
  const framed = Buffer.alloc(2 + mask.length + content.length);
  framed[0] = 0x80 | opcode;
  framed[1] = 0x80 | content.length;
  mask.copy(framed, 2);
  for (let index = 0; index < content.length; index += 1) {
    framed[6 + index] = content[index] ^ mask[index % mask.length];
  }
  return framed;
}

const timeout = setTimeout(() => {
  console.error("Timed out waiting for the ttyd WebSocket.");
  socket.destroy();
  process.exitCode = 1;
}, timeoutMs);

socket.once("connect", () => {
  socket.write([
    `GET ${url.pathname}${url.search} HTTP/1.1`,
    `Host: ${url.host}`,
    "Connection: Upgrade",
    "Upgrade: websocket",
    `Sec-WebSocket-Key: ${key}`,
    "Sec-WebSocket-Version: 13",
    "Sec-WebSocket-Protocol: tty",
    "",
    "",
  ].join("\r\n"));
});

socket.on("data", (chunk) => {
  if (upgraded) {
    return;
  }
  response = Buffer.concat([response, chunk]);
  const headerEnd = response.indexOf("\r\n\r\n");
  if (headerEnd < 0) {
    return;
  }
  const headers = response.subarray(0, headerEnd).toString("latin1");
  if (!headers.startsWith("HTTP/1.1 101")) {
    clearTimeout(timeout);
    console.error(`WebSocket upgrade failed: ${headers.split("\r\n")[0]}`);
    socket.destroy();
    process.exitCode = 1;
    return;
  }
  upgraded = true;
  socket.write(frame(JSON.stringify({
    AuthToken: "",
    columns: 100,
    rows: 30,
  }), 0x2));
  setTimeout(() => {
    socket.write(frame(`0${input}\r`, 0x2));
    setTimeout(() => {
      socket.write(frame("", 0x8));
      socket.end();
    }, 1000);
  }, 2000);
});

socket.once("close", () => clearTimeout(timeout));
socket.once("error", (error) => {
  clearTimeout(timeout);
  console.error(`The ttyd WebSocket failed: ${error.message}`);
  process.exitCode = 1;
});
