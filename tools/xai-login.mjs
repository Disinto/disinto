// tools/xai-login.mjs — device-code xAI login using dsh's own pi-ai module.
//
// Run inside the disinto/agents image (see tools/xai-login.sh):
//   node /login.mjs <out-grant-path> [label]
//
// Prints only the verification URL and code (plus a completion line); the
// grant itself is written to <out-grant-path> with mode 0600 and never
// reaches stdout.
import { writeFileSync } from "node:fs";
const { xaiOAuth } = await import("/usr/local/lib/node_modules/@deepseek-ai/dsh/node_modules/@earendil-works/pi-ai/dist/auth/oauth/xai.js");
const out = process.argv[2];
const label = process.argv[3] || "disinto";
const grant = await xaiOAuth.login({
  signal: AbortSignal.timeout(30 * 60 * 1000),
  notify: (ev) => {
    if (ev.type === "device_code") {
      console.log(`[${label}] open ${ev.verificationUri}  code ${ev.userCode}  (expires in ${ev.expiresInSeconds}s)`);
    }
  },
});
writeFileSync(out, JSON.stringify(grant), { mode: 0o600 });
console.log(`[${label}] signed in; grant saved`);
