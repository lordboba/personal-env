"use client";

import type { CSSProperties, PointerEvent } from "react";

const trust = [
  { label: "Keychain-backed", detail: "Apple's secure enclave" },
  { label: "Device auth", detail: "Touch ID on every read" },
  { label: "No network", detail: "No account. No telemetry." },
  { label: "CLI included", detail: "penv ships in the DMG" },
];

const vaults = [
  "Acme Web App",
  "Acme Mobile",
  "Infrastructure",
  "Data Pipeline",
];

const secrets: Array<[string, string]> = [
  ["DATABASE_URL", "Production"],
  ["STRIPE_SECRET_KEY", "Production"],
  ["JWT_PRIVATE_KEY", "Production"],
  ["SENTRY_DSN", "Staging"],
  ["REDIS_URL", "Staging"],
  ["OPENAI_API_KEY", "Development"],
  ["API_BASE_URL", "Development"],
];

const downloadUrl = "/downloads/Personal-Env-macOS.dmg";
const sourceUrl = "https://github.com/lordboba/personal-env";

export default function Home() {
  const lightDefault = {
    "--light-x": "30%",
    "--light-y": "40%",
  } as CSSProperties;

  function moveLight(event: PointerEvent<HTMLElement>) {
    if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) return;
    const bounds = event.currentTarget.getBoundingClientRect();
    event.currentTarget.style.setProperty(
      "--light-x",
      `${event.clientX - bounds.left}px`,
    );
    event.currentTarget.style.setProperty(
      "--light-y",
      `${event.clientY - bounds.top}px`,
    );
  }

  function resetLight(event: PointerEvent<HTMLElement>) {
    event.currentTarget.style.setProperty("--light-x", "30%");
    event.currentTarget.style.setProperty("--light-y", "40%");
  }

  return (
    <main className="shell">
      <nav className="topbar" aria-label="Primary">
        <a className="brand" href="/">
          <span className="brandMark" aria-hidden="true" />
          Personal Env
        </a>
        <div className="navLinks">
          <a href="/cli">CLI</a>
          <a href="#trust">Security</a>
          <a href={sourceUrl}>GitHub</a>
          <a className="navDownload" href={downloadUrl}>
            Download
          </a>
        </div>
      </nav>

      <section className="hero" aria-label="Personal Env download">
        <div className="copy">
          <p className="eyebrow">macOS · App + CLI</p>
          <h1
            className="title"
            onPointerMove={moveLight}
            onPointerLeave={resetLight}
            style={lightDefault}
          >
            Your .env files,
            <br />
            locked in the Keychain.
          </h1>
          <p className="lede">
            A device-authenticated vault for project secrets. Import, edit, and
            export clean <code>.env</code> files. Nothing leaves your Mac.
          </p>
          <div className="actions">
            <a
              className="primary"
              href={downloadUrl}
              onPointerMove={moveLight}
              onPointerLeave={resetLight}
              style={lightDefault}
            >
              <span className="appleMark" aria-hidden="true" />
              Download for macOS
            </a>
            <a className="secondary" href={sourceUrl}>
              View source
            </a>
          </div>
          <p className="meta">
            Apple-notarized · macOS 13+ · penv CLI included
          </p>
        </div>

        <div className="productWindow" aria-hidden="true">
          <div className="windowTop">
            <div className="traffic">
              <span />
              <span />
              <span />
            </div>
            <span className="windowTitle">Acme Web App</span>
          </div>
          <div className="windowBody">
            <aside className="vaultList">
              <p className="vaultLabel">Vaults</p>
              {vaults.map((vault, index) => (
                <span
                  className={index === 0 ? "vault selected" : "vault"}
                  key={vault}
                >
                  {vault}
                </span>
              ))}
            </aside>
            <div className="secretTable">
              <div className="tableHeader">
                <span>Key</span>
                <span>Value</span>
                <span>Scope</span>
              </div>
              {secrets.map(([key, scope]) => (
                <div className="keyRow" key={key}>
                  <strong>{key}</strong>
                  <span className="dots">••••••••</span>
                  <span className={`badge ${scope.toLowerCase()}`}>
                    {scope}
                  </span>
                </div>
              ))}
              <div className="tableFoot">
                <span>+ New Variable</span>
                <span>7 variables · Unlocked</span>
              </div>
            </div>
          </div>
        </div>
      </section>

      <section className="trustStrip" id="trust" aria-label="Security">
        {trust.map((item) => (
          <div className="trustItem" key={item.label}>
            <strong>{item.label}</strong>
            <small>{item.detail}</small>
          </div>
        ))}
      </section>

      <section className="cliSection" id="cli" aria-label="The penv CLI">
        <p className="eyebrow">The penv CLI</p>
        <h2 className="sectionTitle">Same vault, from your terminal.</h2>
        <div className="terminal">
          <p>
            <span className="prompt">$</span> penv import .env
          </p>
          <p className="out">✓ 7 secrets encrypted into Acme Web App</p>
          <p>
            <span className="prompt">$</span> penv export --scope production
          </p>
          <p className="out">
            ✓ wrote .env <span className="hint">(Touch ID confirmed)</span>
          </p>
        </div>
        <a className="textLink" href="/cli">
          Read the CLI docs
        </a>
      </section>

      <footer className="siteFoot">
        <span>Personal Env v1.0</span>
        <span>
          <a href={sourceUrl}>GitHub</a> · MIT · Made for macOS
        </span>
      </footer>
    </main>
  );
}
