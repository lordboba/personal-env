import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "Personal Env",
  description: "A native macOS vault for project environment variables."
};

export default function RootLayout({
  children
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
