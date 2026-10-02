/**
 * BM guard: asks the BEAM before every mutating pi tool call and blocks the call when refused.
 * Load only in the mutating-worker profile.
 *
 * Covers pi's edit, write and bash tools, including calls made inside Fabric's fabric_exec
 * (Fabric replays pi's tool lifecycle for nested calls; qualified in stage A6). Anything that
 * goes wrong while asking fails closed: the call is blocked.
 *
 * Every allowed bash command is also prefixed so BM can track its process group (see below).
 *
 * This is a policy check, not a sandbox: a permitted bash command can still change any file.
 * BM attributes changes with workspace snapshots, not with this hook.
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { bmRequest, report } from "./bm_common.ts";

const GUARDED_TOOLS = new Set(["edit", "write", "bash"]);

const shellQuote = (value: string) => `'${value.replaceAll("'", `'\\''`)}'`;

/**
 * pi runs every bash command in a session of its own, outside pi's process group. The prefix
 * appends that session's group id (`$$`, the shell is the group leader) and the time to the file
 * BM named in BM_PGID_FILE, so BM can find and end whatever the command leaves running (decision
 * D18), and can tell a group id that another program took over later (plan 36.10).
 */
function recordProcessGroup(input: { command: string }, pgidFile: string): void {
	input.command = `printf '%s %s\\n' "$$" "$(date +%s)" >> ${shellQuote(pgidFile)}\n${input.command}`;
}

/**
 * What the BEAM needs to decide (and records): the path for edit/write, the command for bash.
 * File contents are left out; they can be large and BM attributes changes from snapshots anyway.
 */
function policyInput(tool: string, input: Record<string, unknown>): Record<string, unknown> {
	if (tool === "bash") return { command: input.command, timeout: input.timeout };
	return { path: input.path };
}

export default function (pi: ExtensionAPI) {
	pi.on("tool_call", async (event, ctx) => {
		if (!GUARDED_TOOLS.has(event.toolName)) return undefined;

		const pgidFile = process.env.BM_PGID_FILE;
		if (event.toolName === "bash" && !pgidFile) {
			return { block: true, reason: "Blocked: BM_PGID_FILE is not set, so BM can't track this command." };
		}

		try {
			const reply = await bmRequest(ctx, "authorize", { tool: event.toolName, input: policyInput(event.toolName, event.input as Record<string, unknown>) });
			if (reply.allow !== true) return { block: true, reason: String(reply.reason ?? "Blocked by BM policy.") };
			// Mutated in place, after the BEAM saw the original command (pi's documented way).
			if (event.toolName === "bash" && pgidFile) recordProcessGroup(event.input as { command: string }, pgidFile);
			return undefined;
		} catch (error) {
			return { block: true, reason: `Blocked: ${error instanceof Error ? error.message : String(error)}` };
		}
	});

	pi.on("session_start", (_event, ctx) => report(ctx, "guard", { tools: [...GUARDED_TOOLS] }));
}
