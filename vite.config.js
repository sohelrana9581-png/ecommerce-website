import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

export default defineConfig({
  plugins: [
    react(),
    {
      name: "easy-shop-premium-ui-loader",
      transform(code, id) {
        const normalized = id.replaceAll("\\", "/");
        if (normalized.endsWith("/src/admin.jsx")) {
          return { code: `import "./admin-orders-premium.css";\nimport "./premium-ui.css";\n${code}`, map: null };
        }
        if (normalized.endsWith("/src/main.jsx")) {
          return { code: `${code}\nimport "./premium-ui.css";`, map: null };
        }
      },
    },
  ],
});
