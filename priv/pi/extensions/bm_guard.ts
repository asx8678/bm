/**
 * BM guard: asks the BEAM before every mutating pi tool call and blocks the call when refused.
 * Load only in the mutating-worker profile.
 *
 * Covers pi's edit, write and bash tools, including calls made inside Fabric's fabric_exec
 * (Fabric replays pi's tool lifecycle for nested calls; qualified in stage A6). Anything that
 * goes wrong while asking fails closed: the call is blocked.
 *
 * This is a policy check, not a sandbox: a permitted bash command can still change any file.
 * BM attributes changes with workspace snapshots, not with this hook.
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { bmRequest, report } from "./bm_common.ts";

const GUARDED_TOOLS = new Set(["edit", "write", "bash"]);

export default function (pi: ExtensionAPI) {
	pi.on("tool_call", async (event, ctx) => {
		if (!GUARDED_TOOLS.has(event.toolName)) return undefined;

		try {
			const reply = await bmRequest(ctx, "authorize", { tool: event.toolName, input: event.input });
			if (reply.allow === true) return undefined;
			return { block: true, reason: String(reply.reason ?? "Blocked by BM policy.") };
		} catch (error) {
			return { block: true, reason: `Blocked: ${error instanceof Error ? error.message : String(error)}` };
		}
	});

	pi.on("session_start", (_event, ctx) => report(ctx, "guard", { tools: [...GUARDED_TOOLS] }));
}
