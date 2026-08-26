import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "Teremoq · Edge Supervisor",
  description: "Supervisión de vídeo de ultra-baja latencia para Teremoq",
};

export default function RootLayout({ children }: LayoutProps<"/">) {
  return (
    <html lang="es">
      <body>{children}</body>
    </html>
  );
}
