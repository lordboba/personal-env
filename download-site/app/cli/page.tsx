const downloadUrl = "/downloads/Personal-Env-macOS.dmg";
const sourceUrl = "https://github.com/lordboba/personal-env";

const commands = [
  {
    name: "Create a vault",
    command: 'penv vault "Personal Coding" /Users/you/Code/project',
    detail: "Creates or updates a vault for one project path and prints its vault id.",
  },
  {
    name: "Store one secret",
    command:
      "printf '%s' \"$OPENAI_API_KEY\" | penv set <vault-id> OPENAI_API_KEY --stdin --scope ai",
    detail: "Reads the value from stdin so it is not passed as a shell argument.",
  },
  {
    name: "Import dotenv",
    command: "penv import <vault-id> .env",
    detail: "Imports standard KEY=value lines into an existing vault.",
  },
  {
    name: "Export safely",
    command: "penv export <vault-id> --to-file .env OPENAI_API_KEY",
    detail: "Writes directly to a file and prints a redacted receipt, not secret values.",
  },
];

export default function CliDocs() {
  return (
    <main className="shell">
      <nav className="topbar" aria-label="Primary">
        <a className="brand" href="/">
          <span className="brandMark" aria-hidden="true" />
          Personal Env
        </a>
        <div className="navLinks">
          <a href="/cli" aria-current="page">
            CLI
          </a>
          <a href="/#trust">Security</a>
          <a href={sourceUrl}>GitHub</a>
          <a className="navDownload" href={downloadUrl}>
            Download
          </a>
        </div>
      </nav>

      <section className="docsHero" aria-labelledby="cli-title">
        <p className="eyebrow">penv CLI</p>
        <h1 id="cli-title" className="docsTitle">
          Broker project secrets without printing them.
        </h1>
        <p className="docsLede">
          The CLI creates vaults, imports dotenv files, exports approved keys,
          and grants scoped access for automation. Secret reads still go through
          device-owner approval.
        </p>
        <div className="actions">
          <a className="primary" href={downloadUrl}>
            <span className="appleMark" aria-hidden="true" />
            Download app + CLI
          </a>
          <a className="secondary" href="#quickstart">
            Quickstart
          </a>
        </div>
      </section>

      <section className="docsGrid" aria-label="CLI documentation">
        <aside className="docsIndex" aria-label="CLI sections">
          <a href="#quickstart">Quickstart</a>
          <a href="#commands">Commands</a>
          <a href="#approvals">Approvals</a>
          <a href="#safety">Safety model</a>
        </aside>

        <div className="docsContent">
          <section className="docSection" id="quickstart">
            <p className="eyebrow">Quickstart</p>
            <h2>Install once, then list vaults.</h2>
            <div className="commandBlock" aria-label="Install commands">
              <p>bash scripts/install-cli.sh</p>
              <p>penv list</p>
            </div>
            <p>
              The installer builds <code>penv</code> and copies it to{" "}
              <code>~/.local/bin/penv</code> by default. If that directory is
              not on <code>PATH</code>, the installer prints the exact shell
              export to add.
            </p>
          </section>

          <section className="docSection" id="commands">
            <p className="eyebrow">Core commands</p>
            <h2>Common vault workflows.</h2>
            <div className="commandList">
              {commands.map((item) => (
                <div className="commandRow" key={item.name}>
                  <div>
                    <strong>{item.name}</strong>
                    <small>{item.detail}</small>
                  </div>
                  <code>{item.command}</code>
                </div>
              ))}
            </div>
          </section>

          <section className="docSection" id="approvals">
            <p className="eyebrow">Scoped approvals</p>
            <h2>Give automation narrow, temporary access.</h2>
            <div className="commandBlock" aria-label="Approval commands">
              <p>
                penv approve read --ttl 10m --vault &lt;vault-id&gt; --keys
                OPENAI_API_KEY --to-file .env --requester agent:codex --command
                export
              </p>
              <p>
                penv export &lt;vault-id&gt; --to-file .env --requester
                agent:codex OPENAI_API_KEY
              </p>
            </div>
            <p>
              Approval grants can be scoped by vault, key set, destination,
              requester, command, and TTL. Use <code>penv approvals</code> to
              inspect active grants and <code>penv revoke</code> to clear them.
            </p>
          </section>

          <section className="docSection" id="safety">
            <p className="eyebrow">Safety model</p>
            <h2>File export is the safe automation path.</h2>
            <p>
              <code>penv export</code> refuses implicit stdout output. For
              agents and scripts, prefer <code>--to-file &lt;path&gt;</code> so
              Personal Env writes the target dotenv file directly and prints
              only a redacted receipt.
            </p>
            <div className="commandBlock compact" aria-label="Stdout escape hatch">
              <p>
                penv export &lt;vault-id&gt; --stdout --allow-secret-stdout
                OPENAI_API_KEY
              </p>
            </div>
            <p>
              Stdout is available only as an explicit human escape hatch because
              it exposes secret material to the receiving process.
            </p>
          </section>
        </div>
      </section>

      <footer className="siteFoot">
        <span>Personal Env v1.0</span>
        <span>
          <a href="/">Download site</a> · <a href={sourceUrl}>GitHub</a>
        </span>
      </footer>
    </main>
  );
}
