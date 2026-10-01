import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

export default defineConfig({
  plugins: [
    react(),
    {
      name: "easy-shop-admin-orders-premium-ui",
      transform(code, id) {
        if (id.replaceAll("\\", "/").endsWith("/src/admin.jsx")) {
          return {
            code: `import "./admin-orders-premium.css";\n${code}`,
            map: null,
          };
        }
      },
    },
  ],
});
