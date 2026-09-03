// dsh-headless-resume.mjs — patch the dsh headless runner for session
// resume (#1224), applied at image build time (docker/agents/Dockerfile).
//
// Stock @deepseek-ai/dsh-headless always creates a fresh session via
// agents.create(); the tui profile resumes through the core
// agents.resume() API (dsh-agent -> dsh-agent-loop -> session
// persistence), which the headless runner simply never calls. This
// patch makes the runner honour the DSH_RESUME_SESSION env var: set to
// a persisted session id (session-<uuid>) it resumes that session;
// unset/empty keeps the stock fresh-session behaviour.
//
// Usage: node dsh-headless-resume.mjs <path to dsh-headless/lib/index.js>
// Idempotent; exits 1 (failing the image build) if the target block is
// not found — e.g. after a dsh upgrade changes the runner source.
import { readFileSync, writeFileSync } from "node:fs";

const file = process.argv[2];
if (file === undefined) {
	console.error("usage: node dsh-headless-resume.mjs <dsh-headless/lib/index.js>");
	process.exit(2);
}
const src = readFileSync(file, "utf8");

if (src.includes("DSH_RESUME_SESSION")) {
	console.log("dsh-headless-resume: already patched");
	process.exit(0);
}

const oldBlock = `	const { agent } = await agents.create({
		sessionId: SessionId(\`session-\${randomUUID()}\`),
		meta: { cwd: process.cwd() },
		agentOptions: {
			provider: selection.provider,
			model: selection.model
		},
		setup: (agentCtx) => {
			installModelSelection(agentCtx, {
				current: selection,
				assembled: void 0
			});
		}
	});`;

const newBlock = `	const resumeId = process.env.DSH_RESUME_SESSION;
	const agentOptions = {
		provider: selection.provider,
		model: selection.model
	};
	const setup = (agentCtx) => {
		installModelSelection(agentCtx, {
			current: selection,
			assembled: void 0
		});
	};
	const { agent } = resumeId === void 0 || resumeId === "" ? await agents.create({
		sessionId: SessionId(\`session-\${randomUUID()}\`),
		meta: { cwd: process.cwd() },
		agentOptions,
		setup
	}) : await agents.resume({
		resumeSessionId: SessionId(resumeId),
		agentOptions,
		setup
	});`;

if (!src.includes(oldBlock)) {
	console.error("dsh-headless-resume: PATCH TARGET NOT FOUND — dsh-headless source changed?");
	process.exit(1);
}
writeFileSync(file, src.replace(oldBlock, newBlock));
console.log("dsh-headless-resume: patched OK");
