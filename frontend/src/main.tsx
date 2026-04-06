import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import "./index.css";
import "./theme"; // Apply saved theme on load
import App from "./App";

if ("serviceWorker" in navigator) {
  window.addEventListener("load", () => {
    navigator.serviceWorker.register("/sw.js").catch(() => {});
  });
}

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <App />
  </StrictMode>
);
