// Gives the PostgreSQL files to the "postgresql-conf" language, whose
// comment prefix and language server the bundle manifest declares.
//
// A manifest can only claim files by extension, and ".conf" belongs to many
// programs, so the file names are added to the language here instead. The
// writes are in-memory settings scoped to this plugin: config.json is not
// touched, and names a user lists under languages.postgresql-conf.filenames
// are kept.
//
// The grammar is registered here rather than in the manifest because a file
// named on the command line is open before any plugin runs, detected by its
// extension. Registering a grammar and reloading rebuilds the grammar
// registry, and the rebuild indexes the names set here and re-detects every
// open buffer. Fresh then starts the server for the buffers that changed
// language and announces them to it.

const editor = getEditor();

const LANGUAGE = "postgresql-conf";
const PACKAGE = "postern";
const GRAMMAR = ["grammars", "postgresql-conf.sublime-syntax"];
const GRAMMAR_NAME = "PostgreSQL Config";
const FILENAMES = [
  "postgresql.conf",
  "postgresql.auto.conf",
  "postgresql.base.conf",
  "pg_hba.conf",
  "pg_ident.conf",
];
// An include_dir under a postgresql directory, as Debian lays it out:
// /etc/postgresql/16/main/conf.d/*.conf. A glob that names directories is
// matched against the whole path.
const PATTERNS = ["**/postgresql/**/conf.d/*.conf"];

type ServerConfig = {
  command?: string;
  args?: string[] | null;
  auto_start?: boolean;
  initialization_options?: Record<string, unknown> | null;
};

type Config = {
  languages?: Record<string, { filenames?: unknown; grammar?: unknown }>;
  lsp?: Record<string, ServerConfig | ServerConfig[]>;
};

// Bundles install under bundles/packages; getPluginDir() assumes plugins/packages.
function grammarPath(): string {
  const bundled = editor.pathJoin(
    editor.getConfigDir(),
    "bundles",
    "packages",
    PACKAGE,
    ...GRAMMAR,
  );
  return editor.fileExists(bundled) ? bundled : editor.pathJoin(editor.getPluginDir(), ...GRAMMAR);
}

function postgresFileOpen(): boolean {
  return editor
    .listBuffers()
    .some((buffer) => !buffer.is_virtual && FILENAMES.includes(editor.pathBasename(buffer.path)));
}

function currentServer(): ServerConfig {
  const entry = (editor.getConfig() as Config).lsp?.[LANGUAGE];
  return (Array.isArray(entry) ? entry[0] : entry) ?? { command: "postern" };
}

// The hint on trust or password authentication for non-local pg_hba.conf
// rules is a toggle in Fresh Settings. As in the VS Code extension the
// choice reaches the server as an initialization option, so changing it
// restarts the server. At load nothing is running yet, so no restart.
let trustHintsOff = false;

function applyReportTrust(on: boolean, restart: boolean): void {
  if (on === !trustHintsOff) return;
  const server = currentServer();
  const options: Record<string, unknown> = { ...(server.initialization_options ?? {}) };
  if (on) delete options.reportTrust;
  else options.reportTrust = false;
  editor.registerLspServer(LANGUAGE, {
    command: server.command ?? "postern",
    args: server.args ?? [],
    autoStart: server.auto_start ?? true,
    initializationOptions: options,
    processLimits: null,
  });
  trustHintsOff = !on;
  if (restart && postgresFileOpen()) editor.restartLspForLanguage(LANGUAGE);
}

const reportTrust = editor.defineConfigBoolean("reportTrust", {
  default: true,
  description:
    "Show a hint on pg_hba.conf rules that use trust or password on a non-local address. Loopback and samehost rules are never reported.",
});
applyReportTrust(reportTrust, false);
editor.on("config_changed", () => {
  const settings = editor.getPluginConfig<{ reportTrust?: boolean }>();
  applyReportTrust(settings?.reportTrust !== false, true);
});

const language = (editor.getConfig() as Config).languages?.[LANGUAGE];

const filenames = Array.isArray(language?.filenames)
  ? language.filenames.filter((name): name is string => typeof name === "string")
  : [];
for (const name of [...FILENAMES, ...PATTERNS]) {
  if (!filenames.includes(name)) filenames.push(name);
}
editor.setSetting(`languages.${LANGUAGE}.filenames`, filenames);

// A language finds its grammar by this name, the way Fresh's own entries do
// (key "gitconfig", grammar "Git Config"). A bundle leaves it empty.
if (!language?.grammar) {
  editor.setSetting(`languages.${LANGUAGE}.grammar`, GRAMMAR_NAME);
}

// The private extension lets Fresh see the grammar is already loaded when the
// plugin is reloaded, instead of adding a second copy.
editor.registerGrammar(LANGUAGE, grammarPath(), [LANGUAGE]);
void editor.reloadGrammars();
