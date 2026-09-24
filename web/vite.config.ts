import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// `npm run mock` in another terminal, then `npm run dev`
export default defineConfig({
  plugins: [react()],
  base: "./",
  build: { outDir: "../www", emptyOutDir: true },
  server: {
    proxy: {
      "/events": "http://localhost:8740",
      "/api": "http://localhost:8740",
    },
  },
});
