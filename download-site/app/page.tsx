"use client";

import type { CSSProperties, PointerEvent } from "react";

const features = [
  { label: "End-to-end encrypted", detail: "Secrets stay on your device" },
  { label: "CLI native", detail: "Use it in your existing workflow" },
  { label: "Private by design", detail: "No telemetry. Ever." },
];

const secrets = [
  ["DATABASE_URL", "Production"],
  ["STRIPE_SECRET_KEY", "Production"],
  ["JWT_PRIVATE_KEY", "Production"],
  ["SENTRY_DSN", "Staging"],
  ["REDIS_URL", "Staging"],
  ["OPENAI_API_KEY", "Development"],
  ["API_BASE_URL", "Development"],
];

export default function Home() {
  const defaultLight = {
    "--title-x": "34%",
    "--title-y": "42%",
  } as CSSProperties;

  function moveTextLight(event: PointerEvent<HTMLElement>) {
    const bounds = event.currentTarget.getBoundingClientRect();
    event.currentTarget.style.setProperty(
      "--title-x",
      `${event.clientX - bounds.left}px`,
    );
    event.currentTarget.style.setProperty(
      "--title-y",
      `${event.clientY - bounds.top}px`,
    );
  }

  function resetTextLight(event: PointerEvent<HTMLElement>) {
    event.currentTarget.style.setProperty("--title-x", "34%");
    event.currentTarget.style.setProperty("--title-y", "42%");
  }

  return (
    <main className="shell">
      <nav className="topbar" aria-label="Primary">
        <a className="brand" href="/">
          <span className="appIcon" aria-hidden="true">
            <span />
          </span>
          Personal Env
        </a>
        <div className="navLinks">
          <a href="#features">Features</a>
          <a href="https://github.com/tylerxiao/personal-env">Docs</a>
          <a className="navDownload" href="/downloads/Personal-Env.dmg">
            Download
          </a>
        </div>
      </nav>

      <section className="hero" aria-label="Personal Env download">
        <div className="copy">
          <h1
            className="glassTitle"
            onPointerMove={moveTextLight}
            onPointerLeave={resetTextLight}
            style={defaultLight}
          >
            Personal Env
          </h1>
          <p
            className="lede"
            onPointerMove={moveTextLight}
            onPointerLeave={resetTextLight}
            style={defaultLight}
          >
            A secure env variable vault that lives on your Mac.
          </p>
          <p
            className="support"
            onPointerMove={moveTextLight}
            onPointerLeave={resetTextLight}
            style={defaultLight}
          >
            Store project files and text blobs behind device authentication,
            then import, edit, and export clean .env files.
          </p>
          <div className="actions">
            <a
              className="primary"
              href="/downloads/Personal-Env.dmg"
              onPointerMove={moveTextLight}
              onPointerLeave={resetTextLight}
              style={defaultLight}
            >
              <span className="appleMark" aria-hidden="true" />
              Download for macOS
            </a>
            <a
              className="secondary"
              href="https://github.com/tylerxiao/personal-env"
              onPointerMove={moveTextLight}
              onPointerLeave={resetTextLight}
              style={defaultLight}
            >
              View source
            </a>
          </div>
        </div>

        <div className="liquidPane" aria-hidden="true">
          <div className="productWindow glass">
            <div className="windowTop">
              <div className="traffic">
                <span />
                <span />
                <span />
              </div>
              <div className="scope">All Environments</div>
              <div className="search">Search</div>
            </div>
            <div className="windowBody">
              <div className="tableHeader">
                <span>Key</span>
                <span>Value</span>
                <span>Environment</span>
              </div>
              {secrets.map(([key, environment]) => (
                <div className="keyRow" key={key}>
                  <strong>{key}</strong>
                  <span className="dots">••••••••••••••••</span>
                  <span className={`badge ${environment.toLowerCase()}`}>
                    {environment}
                  </span>
                </div>
              ))}
            </div>
            <div className="windowFoot">
              <span>+ New Variable</span>
              <span>7 variables · Locked</span>
            </div>
          </div>
        </div>
      </section>

      <section className="featureSection" id="features" aria-label="Features">
        <div className="featureGrid">
          {features.map((feature) => (
            <div className="feature" key={feature.label}>
              <strong
                onPointerMove={moveTextLight}
                onPointerLeave={resetTextLight}
                style={defaultLight}
              >
                {feature.label}
              </strong>
              <small
                onPointerMove={moveTextLight}
                onPointerLeave={resetTextLight}
                style={defaultLight}
              >
                {feature.detail}
              </small>
            </div>
          ))}
        </div>
      </section>
    </main>
  );
}
